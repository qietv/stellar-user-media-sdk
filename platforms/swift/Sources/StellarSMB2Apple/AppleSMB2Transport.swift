import Darwin
import Foundation
import SMB2.Raw
import StellarCore
import StellarRemoteMedia
import StellarSMB2Core

/// Apple SMB2/3 transport using the libsmb2 bundled with TracyPlayer/AMSMB2.
public struct AppleSMB2Transport: SMB2Transport {
  private let runtime: SDKRuntimeDependencies

  public init(runtime: SDKRuntimeDependencies = .live) { self.runtime = runtime }

  public func connect(_ request: SMB2ConnectionRequest) async throws -> any SMB2Session {
    try runtime.cancellationChecker.checkCancellation()
    guard request.versionPolicy == .anySupported, request.signingPolicy == .enabled else {
      throw SDKError(code: .invalidConfiguration, message: "SMB transport policy is unsupported")
    }
    let client = NativeSMBClient(request: request, runtime: runtime)
    let info = try await client.connect()
    return NativeSMBSession(client: client, connectionInfo: info)
  }
}

private actor NativeSMBSession: SMB2DirectoryPagingSession {
  nonisolated let connectionInfo: SMB2ConnectionInfo
  private let client: NativeSMBClient

  init(client: NativeSMBClient, connectionInfo: SMB2ConnectionInfo) {
    self.client = client
    self.connectionInfo = connectionInfo
  }

  func listDirectoryPage(at path: SMB2Path, cursor: String?, limit: Int) async throws
    -> SMB2DirectoryPage
  {
    try await client.perform { cancellation in
      try self.client.listPage(path: path, cursor: cursor, limit: limit, cancellation: cancellation)
    }
  }

  // Preserve the original public transport contract for direct callers. The scanner uses paging.
  func listDirectory(at path: SMB2Path) async throws -> [SMB2Entry] {
    var entries: [SMB2Entry] = []
    var cursor: String?
    repeat {
      let page = try await listDirectoryPage(at: path, cursor: cursor, limit: 256)
      entries.append(contentsOf: page.items)
      cursor = page.nextCursor
    } while cursor != nil
    return entries
  }

  func stat(_ path: SMB2Path) async throws -> SMB2Entry {
    try await client.perform { try self.client.stat(path, cancellation: $0) }
  }

  func read(at path: SMB2Path, range: SMB2ByteRange) async throws -> Data {
    try await client.perform { try self.client.read(path, range: range, cancellation: $0) }
  }

  func disconnect() async { await client.disconnect() }
}

/// All native pointers and callbacks are confined to this serial queue, including cancellation cleanup.
/// Raw QUERY_DIRECTORY is essential: libsmb2's opendir eagerly collects the entire directory itself.
private final class NativeSMBClient: @unchecked Sendable {
  private let queue = DispatchQueue(label: "StellarSMB.directory", qos: .utility)
  private let request: SMB2ConnectionRequest
  private let runtime: SDKRuntimeDependencies
  private var context: UnsafeMutablePointer<smb2_context>?
  private var directories: [String: Directory] = [:]

  init(request: SMB2ConnectionRequest, runtime: SDKRuntimeDependencies) {
    self.request = request
    self.runtime = runtime
  }

  deinit { if let context { smb2_destroy_context(context) } }

  func perform<Value: Sendable>(
    _ body: @escaping @Sendable (NativeSMBCancellation) throws -> Value
  ) async throws -> Value {
    let cancellation = NativeSMBCancellation()
    let result = NativeSMBResult<Value>()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard result.install(continuation) else { return }
        queue.async {
          do {
            try cancellation.check()
            try self.runtime.cancellationChecker.checkCancellation()
            result.resolve(.success(try body(cancellation)))
          } catch is CancellationError {
            result.resolve(.failure(SDKError(code: .cancelled, message: "SMB operation cancelled")))
          } catch { result.resolve(.failure(error)) }
        }
      }
    } onCancel: {
      cancellation.cancel()
      // Queued work and synchronous DNS resolution must not delay the caller's cancellation.
      // Context teardown still runs on its owning queue while callback storage remains alive.
      result.resolve(.failure(SDKError(code: .cancelled, message: "SMB operation cancelled")))
    }
  }

  func connect() async throws -> SMB2ConnectionInfo {
    try await perform { cancellation in
      guard let context = smb2_init_context() else {
        throw SDKError(code: .remoteUnavailable, message: "SMB context could not be created")
      }
      self.context = context
      smb2_set_authentication(context, Int32(SMB2_SEC_NTLMSSP.rawValue))
      smb2_set_user(context, self.request.credential.username)
      smb2_set_password(context, self.request.credential.password)
      if let domain = self.request.credential.domain { smb2_set_domain(context, domain) }
      smb2_set_security_mode(context, UInt16(SMB2_NEGOTIATE_SIGNING_ENABLED))
      smb2_set_seal(context, self.request.encryptionPolicy == .required ? 1 : 0)
      let endpoint = self.request.endpoint
      let server = endpoint.server + (endpoint.port.map { ":\($0)" } ?? "")
      do {
        try self.command(operation: .connect, cancellation: cancellation) { context, opaque in
          smb2_connect_share_async(
            context, server, endpoint.share, self.request.credential.username, Self.callback, opaque
          )
        }
        return SMB2ConnectionInfo(
          dialect: SMB2Dialect(wireValue: smb2_get_dialect(context)),
          signingPolicy: self.request.signingPolicy,
          encryptionPolicy: self.request.encryptionPolicy,
          implementationVersion: "AMSMB2-4.0.3@1726aaaf7adf/libsmb2"
        )
      } catch {
        self.shutdown()
        throw error
      }
    }
  }

  func shutdown() {
    directories.removeAll()
    if let context { smb2_destroy_context(context) }
    context = nil
  }

  func disconnect() async {
    // Cleanup must run even when the scanner's parent task is already cancelled.
    await withCheckedContinuation { continuation in
      queue.async {
        self.shutdown()
        continuation.resume()
      }
    }
  }

  func listPage(path: SMB2Path, cursor: String?, limit: Int, cancellation: NativeSMBCancellation)
    throws -> SMB2DirectoryPage
  {
    guard (1...10_000).contains(limit) else {
      throw SDKError(code: .invalidConfiguration, message: "SMB page limit is invalid")
    }
    let directory: Directory
    if let cursor {
      guard let existing = directories[cursor], existing.path == path else {
        // Never re-enumerate and guess an offset in a changed remote directory.
        throw SDKError(code: .conflict, message: "SMB directory cursor expired; restart discovery")
      }
      directories.removeValue(forKey: cursor)
      directory = existing
    } else {
      var opened: Directory?
      try command(
        operation: .listDirectory, cancellation: cancellation, raw: true,
        decode: { data in
          guard let data else { throw Self.invalidReply() }
          opened = Directory(
            path: path,
            fileID: data.assumingMemoryBound(to: smb2_create_reply.self).pointee.file_id)
        },
        start: { context, opaque in
          var create = smb2_create_request()
          create.requested_oplock_level = UInt8(SMB2_OPLOCK_LEVEL_NONE)
          create.impersonation_level = UInt32(SMB2_IMPERSONATION_IMPERSONATION)
          create.desired_access = UInt32(SMB2_FILE_LIST_DIRECTORY | SMB2_FILE_READ_ATTRIBUTES)
          create.file_attributes = UInt32(SMB2_FILE_ATTRIBUTE_DIRECTORY)
          create.share_access = UInt32(
            SMB2_FILE_SHARE_READ | SMB2_FILE_SHARE_WRITE | SMB2_FILE_SHARE_DELETE)
          create.create_disposition = UInt32(SMB2_FILE_OPEN)
          create.create_options = UInt32(SMB2_FILE_DIRECTORY_FILE)
          return self.remotePath(path).withCString { name in
            create.name = name
            return Self.enqueue(
              context, smb2_cmd_create_async(context, &create, Self.callback, opaque))
          }
        })
      guard let opened else { throw Self.invalidReply() }
      directory = opened
    }
    do {
      var items: [SMB2Entry] = []
      while items.count < limit {
        if directory.offset < directory.buffer.count {
          let end = min(directory.buffer.count, directory.offset + limit - items.count)
          items.append(contentsOf: directory.buffer[directory.offset..<end])
          directory.offset = end
          continue
        }
        directory.buffer.removeAll(keepingCapacity: false)
        directory.offset = 0
        let status = try command(
          operation: .listDirectory, cancellation: cancellation, raw: true,
          allowsEndOfDirectory: true,
          decode: { data in
            guard let data, let context = self.context else { throw Self.invalidReply() }
            let reply = data.assumingMemoryBound(to: smb2_query_directory_reply.self).pointee
            directory.buffer = try self.decodeDirectory(reply, context: context, path: path)
          },
          start: { context, opaque in
            var query = smb2_query_directory_request()
            query.file_information_class = UInt8(SMB2_FILE_ID_FULL_DIRECTORY_INFORMATION)
            query.file_id = directory.fileID
            query.output_buffer_length = 65_536
            return "*".withCString { pattern in
              query.name = pattern
              return Self.enqueue(
                context, smb2_cmd_query_directory_async(context, &query, Self.callback, opaque))
            }
          })
        if UInt32(bitPattern: status) == SMB2_STATUS_NO_MORE_FILES {
          try close(directory, cancellation: cancellation)
          return SMB2DirectoryPage(items: items, nextCursor: nil)
        }
        // A successful empty response cannot prove EOF. Fail rather than loop or mark files missing.
        if directory.buffer.isEmpty {
          directory.emptyResponses += 1
          guard directory.emptyResponses <= 2 else { throw Self.invalidReply() }
        } else {
          directory.emptyResponses = 0
        }
      }
      directory.cursor = RemoteDirectorySessionCursor.make()
      directories[directory.cursor] = directory
      return SMB2DirectoryPage(items: items, nextCursor: directory.cursor)
    } catch {
      try? close(directory, cancellation: cancellation)
      throw error
    }
  }

  private func decodeDirectory(
    _ reply: smb2_query_directory_reply, context: UnsafeMutablePointer<smb2_context>, path: SMB2Path
  ) throws -> [SMB2Entry] {
    guard reply.output_buffer_length <= 65_536,
      reply.output_buffer_length == 0 || reply.output_buffer != nil
    else { throw Self.invalidReply() }
    var offset = 0
    var entries: [SMB2Entry] = []
    while offset < Int(reply.output_buffer_length) {
      let remaining = Int(reply.output_buffer_length) - offset
      guard remaining >= 80, let buffer = reply.output_buffer else { throw Self.invalidReply() }
      let recordBuffer = buffer.advanced(by: offset)
      let nameLength = (0..<4).reduce(0) { $0 | (Int(recordBuffer[60 + $1]) << (8 * $1)) }
      guard nameLength > 0, nameLength % 2 == 0, nameLength <= remaining - 80 else {
        throw Self.invalidReply()
      }
      var vector = smb2_iovec()
      vector.buf = recordBuffer
      vector.len = remaining
      var record = smb2_fileidfulldirectoryinformation()
      guard smb2_decode_fileidfulldirectoryinformation(context, &record, &vector) == 0,
        let namePointer = record.name
      else { throw Self.invalidReply() }
      defer { free(UnsafeMutableRawPointer(mutating: namePointer)) }
      guard let name = String(validatingCString: namePointer),
        (0..<1_000_000).contains(record.last_write_time.tv_usec)
      else { throw Self.invalidReply() }
      if name != ".", name != ".." {
        let kind: SMB2EntryKind =
          record.file_attributes & UInt32(SMB2_FILE_ATTRIBUTE_REPARSE_POINT) != 0
          ? .symbolicLink
          : record.file_attributes & UInt32(SMB2_FILE_ATTRIBUTE_DIRECTORY) != 0 ? .directory : .file
        entries.append(
          try SMB2Entry(
            path: path.appending(component: name), kind: kind,
            size: kind == .file ? Int64(exactly: record.end_of_file) : nil,
            modifiedAtMilliseconds: Self.milliseconds(
              seconds: Int64(record.last_write_time.tv_sec),
              nanoseconds: UInt64(record.last_write_time.tv_usec) * 1_000),
            stableID: Self.stableID(record.file_id)
          ))
      }
      if record.next_entry_offset == 0 { break }
      let next = Int(record.next_entry_offset)
      guard next >= 80 + nameLength, next % 8 == 0, next < remaining else {
        throw Self.invalidReply()
      }
      offset += next
    }
    return entries
  }

  private func close(_ directory: Directory, cancellation: NativeSMBCancellation) throws {
    try command(operation: .listDirectory, cancellation: cancellation, raw: true) {
      context, opaque in
      var close = smb2_close_request()
      close.file_id = directory.fileID
      return Self.enqueue(context, smb2_cmd_close_async(context, &close, Self.callback, opaque))
    }
  }

  func stat(_ path: SMB2Path, cancellation: NativeSMBCancellation) throws -> SMB2Entry {
    var stat = smb2_stat_64()
    _ = try withUnsafeMutablePointer(to: &stat) { pointer in
      try command(operation: .stat, cancellation: cancellation) { context, opaque in
        smb2_stat_async(context, self.remotePath(path), pointer, Self.callback, opaque)
      }
    }
    let kind: SMB2EntryKind =
      switch stat.smb2_type {
      case UInt32(SMB2_TYPE_FILE): .file
      case UInt32(SMB2_TYPE_DIRECTORY): .directory
      case UInt32(SMB2_TYPE_LINK): .symbolicLink
      default: .unknown(stat.smb2_type)
      }
    return try SMB2Entry(
      path: path, kind: kind, size: kind == .file ? Int64(exactly: stat.smb2_size) : nil,
      modifiedAtMilliseconds: Self.milliseconds(
        seconds: Int64(clamping: stat.smb2_mtime), nanoseconds: stat.smb2_mtime_nsec),
      stableID: Self.stableID(stat.smb2_ino)
    )
  }

  func read(_ path: SMB2Path, range: SMB2ByteRange, cancellation: NativeSMBCancellation) throws
    -> Data
  {
    var file: OpaquePointer?
    try command(
      operation: .read, cancellation: cancellation,
      decode: { data in
        guard let data else { throw Self.invalidReply() }
        file = OpaquePointer(data)
      },
      start: { context, opaque in
        smb2_open_async(context, self.remotePath(path), O_RDONLY, Self.callback, opaque)
      })
    defer {
      if let file {
        _ = try? command(operation: .read, cancellation: cancellation) { context, opaque in
          smb2_close_async(context, file, Self.callback, opaque)
        }
      }
    }
    var result = Data()
    while result.count < range.length, let context {
      let count = min(range.length - result.count, Int(smb2_get_max_read_size(context)), 1_048_576)
      guard count > 0 else { throw Self.invalidReply() }
      var buffer = [UInt8](repeating: 0, count: count)
      let read = try buffer.withUnsafeMutableBufferPointer { buffer in
        try command(operation: .read, cancellation: cancellation) { context, opaque in
          smb2_pread_async(
            context, file, buffer.baseAddress, UInt32(count),
            UInt64(range.offset) + UInt64(result.count), Self.callback, opaque)
        }
      }
      if read == 0 { break }
      guard read > 0, read <= count else { throw Self.invalidReply() }
      result.append(contentsOf: buffer.prefix(Int(read)))
    }
    return result
  }

  /// Pump at most one command; callback-owned reply buffers are consumed before the C callback returns.
  @discardableResult
  private func command(
    operation: SMB2Operation, cancellation: NativeSMBCancellation, raw: Bool = false,
    allowsEndOfDirectory: Bool = false,
    decode: @escaping (UnsafeMutableRawPointer?) throws -> Void = { _ in },
    start: (UnsafeMutablePointer<smb2_context>, UnsafeMutableRawPointer) -> Int32
  ) throws -> Int32 {
    try cancellation.check()
    try runtime.cancellationChecker.checkCancellation()
    guard let context else {
      throw SDKError(code: .remoteUnavailable, message: "SMB session is disconnected")
    }
    let reply = Reply(decode: decode, raw: raw)
    let opaque = Unmanaged.passUnretained(reply).toOpaque()
    let queued = start(context, opaque)
    guard queued >= 0 else { throw SMB2POSIXErrorMapper.map(status: queued, operation: operation) }
    let deadline = ContinuousClock.now + .milliseconds(request.timeoutMilliseconds)
    do {
      while reply.status == nil {
        try cancellation.check()
        try runtime.cancellationChecker.checkCancellation()
        guard ContinuousClock.now < deadline else {
          throw SMB2POSIXErrorMapper.map(status: -ETIMEDOUT, operation: operation)
        }
        var descriptor = pollfd(
          fd: smb2_get_fd(context), events: Int16(smb2_which_events(context)), revents: 0)
        guard descriptor.fd >= 0 else {
          throw SMB2POSIXErrorMapper.map(status: -ENOTCONN, operation: operation)
        }
        let polled = poll(&descriptor, 1, 50)
        if polled < 0 {
          if errno == EINTR || errno == EAGAIN { continue }
          throw SMB2POSIXErrorMapper.map(status: -errno, operation: operation)
        }
        if polled > 0, smb2_service(context, Int32(descriptor.revents)) < 0 {
          throw SDKError(code: .remoteUnavailable, message: "SMB connection failed")
        }
      }
    } catch {
      // Destroy pending PDUs while their callback box is still alive. All session cursors expire.
      withExtendedLifetime(reply) { shutdown() }
      throw error
    }
    let status = reply.status!
    if raw {
      if status != 0,
        !(allowsEndOfDirectory && UInt32(bitPattern: status) == SMB2_STATUS_NO_MORE_FILES)
      {
        throw SMB2POSIXErrorMapper.map(
          status: -Int32(nterror_to_errno(UInt32(bitPattern: status))), operation: operation)
      }
    } else if status < 0 {
      throw SMB2POSIXErrorMapper.map(status: status, operation: operation)
    }
    if let error = reply.error { throw error }
    try cancellation.check()
    return status
  }

  private static let callback: smb2_command_cb = { _, status, data, opaque in
    guard let opaque else { return }
    let reply = Unmanaged<Reply>.fromOpaque(opaque).takeUnretainedValue()
    reply.status = status
    if reply.raw ? status == 0 : status >= 0 {
      do { try reply.decode(data) } catch { reply.error = error }
    }
  }

  private static func enqueue(
    _ context: UnsafeMutablePointer<smb2_context>, _ pdu: UnsafeMutablePointer<smb2_pdu>?
  ) -> Int32 {
    guard let pdu else { return -EIO }
    smb2_queue_pdu(context, pdu)
    return 0
  }

  private func remotePath(_ path: SMB2Path) -> String {
    let root = request.endpoint.rootPath
    return root.isRoot
      ? path.relativePath
      : path.isRoot ? root.relativePath : "\(root.relativePath)/\(path.relativePath)"
  }

  private static func stableID(_ value: UInt64) -> String? {
    value == 0 ? nil : "ino-\(String(value, radix: 16))"
  }
  private static func milliseconds(seconds: Int64, nanoseconds: UInt64) -> Int64? {
    let (base, overflow) = seconds.multipliedReportingOverflow(by: 1_000)
    let (value, additionOverflow) = base.addingReportingOverflow(
      Int64(clamping: nanoseconds / 1_000_000))
    return overflow || additionOverflow ? nil : value
  }
  private static func invalidReply() -> SDKError {
    SDKError(code: .parseFailure, message: "SMB directory response is invalid")
  }

  private final class Reply {
    var status: Int32?
    var error: Error?
    let decode: (UnsafeMutableRawPointer?) throws -> Void
    let raw: Bool
    init(decode: @escaping (UnsafeMutableRawPointer?) throws -> Void, raw: Bool) {
      self.decode = decode
      self.raw = raw
    }
  }

  private final class Directory {
    let path: SMB2Path
    let fileID: smb2_file_id
    var cursor = ""
    var buffer: [SMB2Entry] = []
    var offset = 0
    var emptyResponses = 0
    init(path: SMB2Path, fileID: smb2_file_id) {
      self.path = path
      self.fileID = fileID
    }
  }
}

private final class NativeSMBCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  func cancel() { lock.withLock { cancelled = true } }
  func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
}

private final class NativeSMBResult<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Error>?
  private var finished = false

  func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
    lock.lock()
    guard !finished else {
      lock.unlock()
      continuation.resume(throwing: SDKError(code: .cancelled, message: "SMB operation cancelled"))
      return false
    }
    self.continuation = continuation
    lock.unlock()
    return true
  }

  func resolve(_ result: sending Result<Value, Error>) {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    finished = true
    let continuation = continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(with: result)
  }
}

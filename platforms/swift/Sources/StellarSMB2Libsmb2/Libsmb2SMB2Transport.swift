import CStellarSMB2Wrapper
import Foundation
import StellarCore
import StellarSMB2Core

/// Cross-platform transport backed by the project-private, statically linked libsmb2 build.
public struct Libsmb2SMB2Transport: SMB2Transport {
  private let runtime: SDKRuntimeDependencies
  private let executor: SMB2BlockingExecutor

  /// Creates a transport that runs blocking libsmb2 calls on a bounded worker pool.
  public init(runtime: SDKRuntimeDependencies = .live) {
    self.runtime = runtime
    executor = .shared
  }

  public func connect(_ request: SMB2ConnectionRequest) async throws -> any SMB2Session {
    try runtime.cancellationChecker.checkCancellation()
    let state = try Libsmb2SMB2SessionState.create(request)
    do {
      try await withTaskCancellationHandler {
        try await executor.run {
          try state.connect()
        }
      } onCancel: {
        state.cancel()
      }
      try runtime.cancellationChecker.checkCancellation()
    } catch {
      state.disconnect(graceful: false)
      try runtime.cancellationChecker.checkCancellation()
      throw error
    }

    let connectionInfo = state.connectionInfo(
      signingPolicy: request.signingPolicy,
      encryptionPolicy: request.encryptionPolicy
    )
    return Libsmb2SMB2Session(
      state: state,
      executor: executor,
      runtime: runtime,
      connectionInfo: connectionInfo
    )
  }
}

private actor Libsmb2SMB2Session: SMB2Session {
  nonisolated let connectionInfo: SMB2ConnectionInfo

  private let state: Libsmb2SMB2SessionState
  private let executor: SMB2BlockingExecutor
  private let runtime: SDKRuntimeDependencies
  private var disconnected = false

  init(
    state: Libsmb2SMB2SessionState,
    executor: SMB2BlockingExecutor,
    runtime: SDKRuntimeDependencies,
    connectionInfo: SMB2ConnectionInfo
  ) {
    self.state = state
    self.executor = executor
    self.runtime = runtime
    self.connectionInfo = connectionInfo
  }

  func listDirectory(at path: SMB2Path) async throws -> [SMB2Entry] {
    try ensureConnected()
    return try await perform {
      try self.state.listDirectory(at: path)
    }
  }

  func stat(_ path: SMB2Path) async throws -> SMB2Entry {
    try ensureConnected()
    return try await perform {
      try self.state.stat(path)
    }
  }

  func read(at path: SMB2Path, range: SMB2ByteRange) async throws -> Data {
    try ensureConnected()
    return try await perform {
      try self.state.read(at: path, range: range)
    }
  }

  func disconnect() async {
    guard !disconnected else {
      return
    }
    disconnected = true
    state.cancelActiveOperation()
    await executor.runIgnoringFailure {
      self.state.disconnect(graceful: true)
    }
  }

  private func ensureConnected() throws {
    guard !disconnected else {
      throw SDKError(code: .remoteUnavailable, message: "SMB session is disconnected")
    }
  }

  private func perform<Value: Sendable>(
    _ operation: @escaping @Sendable () throws -> Value
  ) async throws -> Value {
    try runtime.cancellationChecker.checkCancellation()
    do {
      let value = try await withTaskCancellationHandler {
        try await executor.run(operation)
      } onCancel: {
        state.cancel()
      }
      try runtime.cancellationChecker.checkCancellation()
      return value
    } catch {
      try runtime.cancellationChecker.checkCancellation()
      throw error
    }
  }
}

private final class Libsmb2SMB2SessionState: @unchecked Sendable {
  private let condition = NSCondition()
  private let rootPath: String
  private var client: OpaquePointer?
  private var activeOperations = 0
  private var negotiatedDialect: UInt16 = 0

  private init(client: OpaquePointer, rootPath: String) {
    self.client = client
    self.rootPath = rootPath
  }

  deinit {
    disconnect(graceful: false)
  }

  static func create(_ request: SMB2ConnectionRequest) throws -> Libsmb2SMB2SessionState {
    let server = serverAddress(for: request.endpoint)
    let timeoutSeconds = Int32((request.timeoutMilliseconds + 999) / 1_000)
    let version = versionValue(for: request.versionPolicy)
    let securityMode: UInt16 =
      request.signingPolicy == .required ? 0x0003 : 0x0001
    var createdClient: OpaquePointer?

    let result = withOptionalCString(request.credential.domain) { domain in
      server.withCString { serverPointer in
        request.endpoint.share.withCString { sharePointer in
          request.credential.username.withCString { usernamePointer in
            request.credential.password.withCString { passwordPointer in
              var config = stellar_smb2_connection_config(
                server: serverPointer,
                share: sharePointer,
                domain: domain,
                username: usernamePointer,
                password: passwordPointer,
                version: version,
                security_mode: securityMode,
                require_signing: request.signingPolicy == .required ? 1 : 0,
                require_encryption: request.encryptionPolicy == .required ? 1 : 0,
                timeout_seconds: timeoutSeconds
              )
              return stellar_smb2_client_create(&config, &createdClient)
            }
          }
        }
      }
    }

    guard result == 0, let createdClient else {
      throw SMB2POSIXErrorMapper.map(status: result, operation: .connect)
    }
    return Libsmb2SMB2SessionState(
      client: createdClient,
      rootPath: request.endpoint.rootPath.relativePath
    )
  }

  func connect() throws {
    let dialect = try withClient { client -> UInt16 in
      let result = stellar_smb2_client_connect(client)
      guard result == 0 else {
        throw SMB2POSIXErrorMapper.map(status: result, operation: .connect)
      }
      return stellar_smb2_client_dialect(client)
    }
    condition.lock()
    negotiatedDialect = dialect
    condition.unlock()
  }

  func connectionInfo(
    signingPolicy: SMB2SigningPolicy,
    encryptionPolicy: SMB2EncryptionPolicy
  ) -> SMB2ConnectionInfo {
    condition.lock()
    let dialect = negotiatedDialect
    condition.unlock()
    return SMB2ConnectionInfo(
      dialect: SMB2Dialect(wireValue: dialect),
      signingPolicy: signingPolicy,
      encryptionPolicy: encryptionPolicy,
      implementationVersion: "libsmb2-6.1.0@aedafb2c8742"
    )
  }

  func listDirectory(at path: SMB2Path) throws -> [SMB2Entry] {
    try withClient { client in
      var rawList = stellar_smb2_entry_list(entries: nil, count: 0)
      let result = remotePath(for: path).withCString { pathPointer in
        stellar_smb2_client_list_directory(client, pathPointer, &rawList)
      }
      defer { stellar_smb2_entry_list_destroy(&rawList) }
      guard result == 0 else {
        throw SMB2POSIXErrorMapper.map(status: result, operation: .listDirectory)
      }
      guard rawList.count == 0 || rawList.entries != nil else {
        throw SDKError(code: .unknown, message: "SMB directory result is invalid")
      }

      var entries: [SMB2Entry] = []
      entries.reserveCapacity(rawList.count)
      for index in 0..<rawList.count {
        let record = rawList.entries!.advanced(by: index).pointee
        guard let namePointer = record.name,
          let name = String(validatingCString: namePointer)
        else {
          throw SDKError(code: .parseFailure, message: "SMB entry name is not valid UTF-8")
        }
        let childPath: SMB2Path
        do {
          childPath = try path.appending(component: name)
        } catch {
          throw SDKError(code: .parseFailure, message: "SMB directory entry is invalid")
        }
        entries.append(try makeEntry(path: childPath, record: record))
      }
      return entries
    }
  }

  func stat(_ path: SMB2Path) throws -> SMB2Entry {
    try withClient { client in
      var record = stellar_smb2_entry_record(
        name: nil,
        type: 0,
        size: 0,
        modified_seconds: 0,
        modified_nanoseconds: 0,
        inode: 0
      )
      let result = remotePath(for: path).withCString { pathPointer in
        stellar_smb2_client_stat(client, pathPointer, &record)
      }
      guard result == 0 else {
        throw SMB2POSIXErrorMapper.map(status: result, operation: .stat)
      }
      return try makeEntry(path: path, record: record)
    }
  }

  func read(at path: SMB2Path, range: SMB2ByteRange) throws -> Data {
    try withClient { client in
      var data = Data(count: range.length)
      var bytesRead = 0
      let result = data.withUnsafeMutableBytes { bytes in
        remotePath(for: path).withCString { pathPointer in
          stellar_smb2_client_read(
            client,
            pathPointer,
            UInt64(range.offset),
            bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
            bytes.count,
            &bytesRead
          )
        }
      }
      guard result == 0 else {
        throw SMB2POSIXErrorMapper.map(status: result, operation: .read)
      }
      guard bytesRead <= data.count else {
        throw SDKError(code: .unknown, message: "SMB read returned an invalid byte count")
      }
      data.removeSubrange(bytesRead..<data.count)
      return data
    }
  }

  func disconnect(graceful: Bool) {
    condition.lock()
    guard let ownedClient = client else {
      condition.unlock()
      return
    }
    client = nil
    if activeOperations > 0 {
      stellar_smb2_client_cancel(ownedClient)
    }
    while activeOperations > 0 {
      condition.wait()
    }
    condition.unlock()
    stellar_smb2_client_destroy(ownedClient, graceful ? 1 : 0)
  }

  func cancel() {
    condition.lock()
    if let client {
      stellar_smb2_client_cancel(client)
    }
    condition.unlock()
  }

  func cancelActiveOperation() {
    condition.lock()
    if activeOperations > 0, let client {
      stellar_smb2_client_cancel(client)
    }
    condition.unlock()
  }

  private func withClient<Value>(_ operation: (OpaquePointer) throws -> Value) throws -> Value {
    condition.lock()
    // A libsmb2 context permits only one active operation. Swift actors are reentrant at
    // the executor await in `perform`, so scanner page requests can still arrive here
    // concurrently and the C wrapper would otherwise reject the second one with EBUSY.
    while activeOperations > 0, client != nil {
      condition.wait()
    }
    guard let client else {
      condition.unlock()
      throw SDKError(code: .remoteUnavailable, message: "SMB session is disconnected")
    }
    activeOperations += 1
    condition.unlock()
    defer {
      condition.lock()
      activeOperations -= 1
      if activeOperations == 0 {
        condition.broadcast()
      }
      condition.unlock()
    }
    return try operation(client)
  }

  private func remotePath(for path: SMB2Path) -> String {
    if rootPath.isEmpty {
      return path.relativePath
    }
    if path.isRoot {
      return rootPath
    }
    return "\(rootPath)/\(path.relativePath)"
  }

  private static func serverAddress(for endpoint: SMB2Endpoint) -> String {
    guard let port = endpoint.port else {
      return endpoint.server
    }
    return "\(endpoint.server):\(port)"
  }

  private static func versionValue(for policy: SMB2VersionPolicy) -> UInt32 {
    switch policy {
    case .anySupported: 0
    case .smb2Only: 2
    case .smb3Only: 3
    case .exact(let dialect): UInt32(dialect.wireValue)
    }
  }

  private func makeEntry(
    path: SMB2Path,
    record: stellar_smb2_entry_record
  ) throws -> SMB2Entry {
    let kind: SMB2EntryKind =
      switch record.type {
      case 0: .file
      case 1: .directory
      case 2: .symbolicLink
      default: .unknown(record.type)
      }
    let size = record.size <= UInt64(Int64.max) ? Int64(record.size) : nil
    let modifiedAtMilliseconds: Int64?
    if record.modified_seconds <= UInt64(Int64.max / 1_000) {
      let seconds = Int64(record.modified_seconds) * 1_000
      let subsecond = Int64(min(record.modified_nanoseconds / 1_000_000, 999))
      modifiedAtMilliseconds = seconds + subsecond
    } else {
      modifiedAtMilliseconds = nil
    }
    return try SMB2Entry(
      path: path,
      kind: kind,
      size: kind == .file ? size : nil,
      modifiedAtMilliseconds: modifiedAtMilliseconds,
      stableID: record.inode == 0 ? nil : "ino-\(String(record.inode, radix: 16))"
    )
  }
}

private final class SMB2BlockingExecutor: @unchecked Sendable {
  static let shared = SMB2BlockingExecutor()

  private let queue: OperationQueue

  private init() {
    queue = OperationQueue()
    queue.name = "com.stellar.user-media.smb2-blocking"
    queue.maxConcurrentOperationCount = 4
    queue.qualityOfService = .utility
  }

  func run<Value: Sendable>(
    _ operation: @escaping @Sendable () throws -> Value
  ) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      queue.addOperation {
        do {
          continuation.resume(returning: try operation())
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  func runIgnoringFailure(_ operation: @escaping @Sendable () -> Void) async {
    await withCheckedContinuation { continuation in
      queue.addOperation {
        operation()
        continuation.resume()
      }
    }
  }
}

private func withOptionalCString<Result>(
  _ value: String?,
  _ body: (UnsafePointer<CChar>?) throws -> Result
) rethrows -> Result {
  guard let value else {
    return try body(nil)
  }
  return try value.withCString(body)
}

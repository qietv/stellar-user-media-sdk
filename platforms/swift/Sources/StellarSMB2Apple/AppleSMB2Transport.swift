@preconcurrency import AMSMB2
import Foundation
import StellarCore
import StellarSMB2Core

/// Apple SMB2/3 transport backed by TracyPlayer/AMSMB2.
public struct AppleSMB2Transport: SMB2Transport {
  private let runtime: SDKRuntimeDependencies

  public init(runtime: SDKRuntimeDependencies = .live) {
    self.runtime = runtime
  }

  public func connect(_ request: SMB2ConnectionRequest) async throws -> any SMB2Session {
    try runtime.cancellationChecker.checkCancellation()
    try validateSupportedPolicies(request)

    let manager = try makeManager(request)
    do {
      try await cancellableAMSMB2Operation(manager: manager) {
        try await manager.connectShare(
          name: request.endpoint.share,
          encrypted: request.encryptionPolicy == .required
        )
      }
      try runtime.cancellationChecker.checkCancellation()
    } catch {
      try runtime.cancellationChecker.checkCancellation()
      throw map(error, operation: .connect)
    }

    return AMSMB2Session(
      manager: manager,
      rootPath: request.endpoint.rootPath,
      runtime: runtime,
      connectionInfo: SMB2ConnectionInfo(
        dialect: .unknown(0),
        signingPolicy: request.signingPolicy,
        encryptionPolicy: request.encryptionPolicy,
        implementationVersion: "AMSMB2-4.0.3@1726aaaf7adf"
      )
    )
  }

  private func validateSupportedPolicies(_ request: SMB2ConnectionRequest) throws {
    guard request.versionPolicy == .anySupported else {
      throw SDKError(
        code: .invalidConfiguration,
        message: "AMSMB2 does not expose an SMB dialect constraint"
      )
    }
    guard request.signingPolicy == .enabled else {
      throw SDKError(
        code: .invalidConfiguration,
        message: "AMSMB2 does not expose required-signing configuration"
      )
    }
  }

  private func makeManager(_ request: SMB2ConnectionRequest) throws -> SMB2Manager {
    var components = URLComponents()
    components.scheme = "smb"
    let server = request.endpoint.server
    components.host =
      server.hasPrefix("[") && server.hasSuffix("]")
      ? String(server.dropFirst().dropLast()) : server
    components.port = request.endpoint.port.map(Int.init)
    guard let url = components.url else {
      throw SDKError(code: .invalidConfiguration, message: "SMB endpoint URL is invalid")
    }
    let credential = URLCredential(
      user: request.credential.username,
      password: request.credential.password,
      persistence: .forSession
    )
    guard
      let manager = SMB2Manager(
        url: url,
        domain: request.credential.domain ?? "",
        credential: credential
      )
    else {
      throw SDKError(code: .invalidConfiguration, message: "SMB client could not be created")
    }
    manager.timeout = TimeInterval(request.timeoutMilliseconds) / 1_000
    return manager
  }
}

private actor AMSMB2Session: SMB2Session {
  nonisolated let connectionInfo: SMB2ConnectionInfo

  private let manager: SMB2Manager
  private let rootPath: SMB2Path
  private let runtime: SDKRuntimeDependencies
  private var disconnected = false

  init(
    manager: SMB2Manager,
    rootPath: SMB2Path,
    runtime: SDKRuntimeDependencies,
    connectionInfo: SMB2ConnectionInfo
  ) {
    self.manager = manager
    self.rootPath = rootPath
    self.runtime = runtime
    self.connectionInfo = connectionInfo
  }

  func listDirectory(at path: SMB2Path) async throws -> [SMB2Entry] {
    try requireConnected()
    do {
      let records = try await cancellable {
        try await self.manager.contentsOfDirectory(atPath: self.remotePath(for: path))
      }
      return try records.map { record in
        guard let name = record[.nameKey] as? String else {
          throw SDKError(code: .parseFailure, message: "SMB directory entry has no name")
        }
        let childPath: SMB2Path
        do {
          childPath = try path.appending(component: name)
        } catch {
          throw SDKError(code: .parseFailure, message: "SMB directory entry name is invalid")
        }
        return try makeEntry(record, path: childPath)
      }
    } catch {
      throw map(error, operation: .listDirectory)
    }
  }

  func stat(_ path: SMB2Path) async throws -> SMB2Entry {
    try requireConnected()
    do {
      let record = try await cancellable {
        try await self.manager.attributesOfItem(atPath: self.remotePath(for: path))
      }
      return try makeEntry(record, path: path)
    } catch {
      throw map(error, operation: .stat)
    }
  }

  func read(at path: SMB2Path, range: SMB2ByteRange) async throws -> Data {
    try requireConnected()
    let lowerBound = UInt64(range.offset)
    let upperBound = lowerBound + UInt64(range.length)
    do {
      return try await cancellable {
        try await self.manager.contents(
          atPath: self.remotePath(for: path),
          range: lowerBound..<upperBound,
          progress: nil
        )
      }
    } catch {
      throw map(error, operation: .read)
    }
  }

  func disconnect() async {
    guard !disconnected else { return }
    disconnected = true
    try? await manager.disconnectShare(gracefully: true)
  }

  private func cancellable<Value>(
    _ operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    try runtime.cancellationChecker.checkCancellation()
    do {
      let value = try await cancellableAMSMB2Operation(manager: manager, operation)
      try runtime.cancellationChecker.checkCancellation()
      return value
    } catch {
      try runtime.cancellationChecker.checkCancellation()
      throw error
    }
  }

  private func requireConnected() throws {
    guard !disconnected else {
      throw SDKError(code: .remoteUnavailable, message: "SMB session is disconnected")
    }
  }

  private func remotePath(for path: SMB2Path) -> String {
    if rootPath.isRoot { return path.relativePath }
    if path.isRoot { return rootPath.relativePath }
    return "\(rootPath.relativePath)/\(path.relativePath)"
  }

  private func makeEntry(
    _ record: [URLResourceKey: Any],
    path: SMB2Path
  ) throws -> SMB2Entry {
    let resourceType = record[.fileResourceTypeKey] as? URLFileResourceType
    let kind: SMB2EntryKind =
      switch resourceType {
      case .regular: .file
      case .directory: .directory
      case .symbolicLink: .symbolicLink
      default: .unknown(0)
      }
    let rawSize = (record[.fileSizeKey] as? NSNumber)?.int64Value
    let size = kind == .file && rawSize.map({ $0 >= 0 }) == true ? rawSize : nil
    let modifiedAtMilliseconds = (record[.contentModificationDateKey] as? Date).flatMap {
      date -> Int64? in
      let milliseconds = date.timeIntervalSince1970 * 1_000
      guard milliseconds.isFinite,
        milliseconds >= Double(Int64.min),
        milliseconds <= Double(Int64.max)
      else { return nil }
      return Int64(milliseconds.rounded(.towardZero))
    }
    let stableID = (record[.documentIdentifierKey] as? NSNumber).flatMap {
      $0.uint64Value == 0 ? nil : "ino-\(String($0.uint64Value, radix: 16))"
    }
    return try SMB2Entry(
      path: path,
      kind: kind,
      size: size,
      modifiedAtMilliseconds: modifiedAtMilliseconds,
      stableID: stableID
    )
  }
}

/// AMSMB2's async methods wrap a one-second synchronous `poll` loop and do not
/// observe Swift task cancellation. Resolve the SDK operation immediately, then
/// let AMSMB2 unwind its private context on its own queue after its shortened timeout.
private func cancellableAMSMB2Operation<Value>(
  manager: SMB2Manager,
  _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
  let gate = AMSMB2CancellationGate<Value>()
  return try await withTaskCancellationHandler {
    try await withCheckedThrowingContinuation { continuation in
      guard gate.install(continuation) else { return }
      Task {
        do {
          gate.resolve(.success(try await operation()))
        } catch {
          gate.resolve(.failure(error))
        }
      }
    }
  } onCancel: {
    manager.timeout = 0.001
    gate.cancel()
  }
}

private final class AMSMB2CancellationGate<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, any Error>?
  private var resolved = false

  func install(_ continuation: CheckedContinuation<Value, any Error>) -> Bool {
    lock.lock()
    if resolved {
      lock.unlock()
      continuation.resume(throwing: CancellationError())
      return false
    }
    self.continuation = continuation
    lock.unlock()
    return true
  }

  func cancel() {
    resolve(.failure(CancellationError()))
  }

  func resolve(_ result: sending Result<Value, any Error>) {
    lock.lock()
    guard !resolved else {
      lock.unlock()
      return
    }
    resolved = true
    let continuation = continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(with: result)
  }
}

private func map(_ error: any Error, operation: SMB2Operation) -> SDKError {
  if let error = error as? SDKError { return error }
  let cocoaError = error as NSError
  if cocoaError.domain == NSPOSIXErrorDomain,
    cocoaError.code > 0,
    cocoaError.code <= Int(Int32.max)
  {
    return SMB2POSIXErrorMapper.map(status: -Int32(cocoaError.code), operation: operation)
  }
  return SDKError(
    code: operation == .connect ? .remoteUnavailable : .unknown,
    message: "SMB operation failed"
  )
}

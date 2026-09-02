import Foundation
import StellarCore
import StellarRemoteMedia

/// Source-independent scanner configuration layered over one SMB connection request.
public struct SMB2MediaSourceConfiguration: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let sourceUID: String
  public let connectionRequest: SMB2ConnectionRequest
  public let stableIDScope: RemoteStableIDScope
  public let pathSemantics: RemotePathSemantics

  public init(
    sourceUID: String,
    connectionRequest: SMB2ConnectionRequest,
    stableIDScope: RemoteStableIDScope = .none,
    pathSemantics: RemotePathSemantics = RemotePathSemantics(
      caseSensitivity: .insensitive,
      unicodeNormalization: .preserve
    )
  ) throws {
    guard !sourceUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !sourceUID.contains("\0"),
      stableIDScope != .unknown
    else {
      throw SDKError(
        code: .invalidConfiguration,
        message: "SMB media source configuration is invalid"
      )
    }
    self.sourceUID = sourceUID
    self.connectionRequest = connectionRequest
    self.stableIDScope = stableIDScope
    self.pathSemantics = pathSemantics
  }

  /// A representation that hides the source, endpoint, and credential values.
  public var description: String { "<SMB2MediaSourceConfiguration redacted>" }

  /// A representation that hides the source, endpoint, and credential values.
  public var debugDescription: String { description }
}

/// Adapts any SMB2 transport, including the Linux and fake transports, to the shared scanner.
public struct SMB2MediaSourceConnector: MediaSourceConnector {
  public let configuration: SMB2MediaSourceConfiguration
  private let transport: any SMB2Transport

  public init(
    transport: any SMB2Transport,
    configuration: SMB2MediaSourceConfiguration
  ) {
    self.transport = transport
    self.configuration = configuration
  }

  public func connect() async throws -> any MediaSourceSession {
    let session = try await transport.connect(configuration.connectionRequest)
    let capabilities = try MediaSourceCapabilities(
      stableIDScope: configuration.stableIDScope,
      pathSemantics: configuration.pathSemantics,
      supportsRangeReads: true,
      supportsChangeCursor: false,
      deltaDeletionsComplete: false,
      preferredDirectoryRequestConcurrency: 1
    )
    return SMB2MediaSourceSession(
      sourceUID: configuration.sourceUID,
      capabilities: capabilities,
      session: session
    )
  }
}

/// A connected SMB session expressed through source-independent locator and entry values.
public actor SMB2MediaSourceSession: MediaSourceSession {
  public nonisolated let sourceUID: String
  public nonisolated let capabilities: MediaSourceCapabilities

  private let session: any SMB2Session
  private var directoryPaginator: RemoteDirectorySnapshotPaginator
  private var disconnected = false

  fileprivate init(
    sourceUID: String,
    capabilities: MediaSourceCapabilities,
    session: any SMB2Session
  ) {
    self.sourceUID = sourceUID
    self.capabilities = capabilities
    self.session = session
    directoryPaginator = RemoteDirectorySnapshotPaginator(
      cursorNamespace: "smb-v1",
      pathSemantics: capabilities.pathSemantics
    )
  }

  public func listDirectory(_ request: RemoteDirectoryPageRequest) async throws
    -> CursorPage<RemoteEntry>
  {
    try requireConnected()
    if let cachedPage = try directoryPaginator.cachedPage(for: request) {
      return cachedPage
    }
    let directoryPath = try smbPath(for: request.directory)
    let entries = try await session.listDirectory(at: directoryPath).map(convert)
    return try directoryPaginator.storeAndPage(entries, for: request)
  }

  public func stat(_ locator: RemoteLocator) async throws -> RemoteEntry {
    try requireConnected()
    return try convert(await session.stat(smbPath(for: locator)))
  }

  public func read(at locator: RemoteLocator, range: RemoteByteRange) async throws -> Data {
    try requireConnected()
    return try await session.read(
      at: smbPath(for: locator),
      range: SMB2ByteRange(offset: range.offset, length: range.length)
    )
  }

  public func disconnect() async {
    guard !disconnected else { return }
    disconnected = true
    directoryPaginator.removeAll()
    await session.disconnect()
  }

  private func requireConnected() throws {
    guard !disconnected else {
      throw SDKError(code: .remoteUnavailable, message: "SMB media session is disconnected")
    }
  }

  private func smbPath(for locator: RemoteLocator) throws -> SMB2Path {
    guard locator.sourceUID == sourceUID else {
      throw SDKError(code: .invalidConfiguration, message: "SMB source UID does not match")
    }
    return try SMB2Path(locator.path.relativePath)
  }

  private func convert(_ entry: SMB2Entry) throws -> RemoteEntry {
    let path = RemotePath(validatedRelativePath: entry.path.relativePath)
    let locator = RemoteLocator(validatedSourceUID: sourceUID, path: path)
    let kind: RemoteEntryKind
    switch entry.kind {
    case .file:
      kind = .file
    case .directory:
      kind = .directory
    case .symbolicLink:
      kind = .symbolicLink
    case .unknown:
      kind = .unknown
    }
    return try RemoteEntry(
      locator: locator,
      kind: kind,
      stableID: entry.stableID,
      size: entry.size,
      modifiedAtMilliseconds: entry.modifiedAtMilliseconds
    )
  }

}

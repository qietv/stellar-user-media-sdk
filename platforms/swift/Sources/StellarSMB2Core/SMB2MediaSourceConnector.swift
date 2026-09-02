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
  /// Number of independent SMB sessions available for directory enumeration.
  ///
  /// A libsmb2 context serializes operations, so directory concurrency requires distinct
  /// sessions. The default remains one to avoid increasing load on low-end servers.
  public let directoryConnectionCount: Int

  public init(
    sourceUID: String,
    connectionRequest: SMB2ConnectionRequest,
    stableIDScope: RemoteStableIDScope = .none,
    pathSemantics: RemotePathSemantics = RemotePathSemantics(
      caseSensitivity: .insensitive,
      unicodeNormalization: .preserve
    )
  ) throws {
    try self.init(
      sourceUID: sourceUID,
      connectionRequest: connectionRequest,
      stableIDScope: stableIDScope,
      pathSemantics: pathSemantics,
      directoryConnectionCount: 1
    )
  }

  /// Creates a source that can distribute directory requests over independent SMB sessions.
  public init(
    sourceUID: String,
    connectionRequest: SMB2ConnectionRequest,
    stableIDScope: RemoteStableIDScope = .none,
    pathSemantics: RemotePathSemantics = RemotePathSemantics(
      caseSensitivity: .insensitive,
      unicodeNormalization: .preserve
    ),
    directoryConnectionCount: Int
  ) throws {
    guard !sourceUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !sourceUID.contains("\0"),
      stableIDScope != .unknown,
      (1...4).contains(directoryConnectionCount)
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
    self.directoryConnectionCount = directoryConnectionCount
  }

  /// A representation that hides the source, endpoint, and credential values.
  public var description: String { "<SMB2MediaSourceConfiguration redacted>" }

  /// A representation that hides the source, endpoint, and credential values.
  public var debugDescription: String { description }
}

/// Adapts an Apple SMB2 transport or test double to the shared scanner.
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
    var sessions: [any SMB2Session] = []
    sessions.reserveCapacity(configuration.directoryConnectionCount)
    do {
      for _ in 0..<configuration.directoryConnectionCount {
        sessions.append(try await transport.connect(configuration.connectionRequest))
      }
    } catch {
      for session in sessions {
        await session.disconnect()
      }
      throw error
    }
    let capabilities = try MediaSourceCapabilities(
      stableIDScope: configuration.stableIDScope,
      pathSemantics: configuration.pathSemantics,
      supportsRangeReads: true,
      supportsChangeCursor: false,
      deltaDeletionsComplete: false,
      preferredDirectoryRequestConcurrency: configuration.directoryConnectionCount
    )
    return SMB2MediaSourceSession(
      sourceUID: configuration.sourceUID,
      capabilities: capabilities,
      sessions: sessions
    )
  }
}

/// A connected SMB session expressed through source-independent locator and entry values.
public actor SMB2MediaSourceSession: MediaSourceSession {
  public nonisolated let sourceUID: String
  public nonisolated let capabilities: MediaSourceCapabilities

  private let sessions: [any SMB2Session]
  private var directoryPaginator: RemoteDirectorySnapshotPaginator
  private var directorySessionIndices: [SMB2Path: Int] = [:]
  private var directorySessionLoads: [Int]
  private var nextDirectorySessionIndex = 0
  private var disconnected = false

  fileprivate init(
    sourceUID: String,
    capabilities: MediaSourceCapabilities,
    sessions: [any SMB2Session]
  ) {
    self.sourceUID = sourceUID
    self.capabilities = capabilities
    self.sessions = sessions
    directorySessionLoads = Array(repeating: 0, count: sessions.count)
    directoryPaginator = RemoteDirectorySnapshotPaginator(
      cursorNamespace: "smb-v1",
      pathSemantics: capabilities.pathSemantics
    )
  }

  public func listDirectory(_ request: RemoteDirectoryPageRequest) async throws
    -> CursorPage<RemoteEntry>
  {
    try requireConnected()
    let directoryPath = try smbPath(for: request.directory)
    // A persisted cursor from the snapshot implementation must finish through the
    // compatibility path after an SDK upgrade. New enumerations use transport paging.
    let hasLegacySnapshotCursor = request.cursor?.hasPrefix("smb-v1:") == true
    if hasLegacySnapshotCursor,
      let cachedPage = try directoryPaginator.cachedPage(for: request)
    {
      return cachedPage
    }
    let sessionIndex = directorySessionIndex(for: directoryPath)
    let session = sessions[sessionIndex]
    directorySessionLoads[sessionIndex] += 1
    defer { directorySessionLoads[sessionIndex] -= 1 }
    do {
      if !hasLegacySnapshotCursor,
        let pagingSession = session as? any SMB2DirectoryPagingSession
      {
        let page = try await pagingSession.listDirectoryPage(
          at: directoryPath,
          cursor: request.cursor,
          limit: request.limit
        )
        if page.nextCursor == nil {
          directorySessionIndices.removeValue(forKey: directoryPath)
        }
        return try CursorPage(
          items: page.items.map(convert),
          nextCursor: page.nextCursor
        )
      }
      let entries = try await session.listDirectory(at: directoryPath).map(convert)
      directorySessionIndices.removeValue(forKey: directoryPath)
      return try directoryPaginator.storeAndPage(entries, for: request)
    } catch {
      directorySessionIndices.removeValue(forKey: directoryPath)
      throw error
    }
  }

  public func stat(_ locator: RemoteLocator) async throws -> RemoteEntry {
    try requireConnected()
    return try convert(await sessions[0].stat(smbPath(for: locator)))
  }

  public func read(at locator: RemoteLocator, range: RemoteByteRange) async throws -> Data {
    try requireConnected()
    return try await sessions[0].read(
      at: smbPath(for: locator),
      range: SMB2ByteRange(offset: range.offset, length: range.length)
    )
  }

  public func disconnect() async {
    guard !disconnected else { return }
    disconnected = true
    directoryPaginator.removeAll()
    directorySessionIndices.removeAll(keepingCapacity: false)
    await withTaskGroup(of: Void.self) { group in
      for session in sessions {
        group.addTask {
          await session.disconnect()
        }
      }
    }
  }

  private func requireConnected() throws {
    guard !disconnected else {
      throw SDKError(code: .remoteUnavailable, message: "SMB media session is disconnected")
    }
  }

  private func directorySessionIndex(for path: SMB2Path) -> Int {
    if let existing = directorySessionIndices[path] {
      return existing
    }
    let minimumLoad = directorySessionLoads.min() ?? 0
    var selected = nextDirectorySessionIndex
    for offset in 0..<sessions.count {
      let candidate = (nextDirectorySessionIndex + offset) % sessions.count
      if directorySessionLoads[candidate] == minimumLoad {
        selected = candidate
        break
      }
    }
    nextDirectorySessionIndex = (selected + 1) % sessions.count
    directorySessionIndices[path] = selected
    return selected
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

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
      deltaDeletionsComplete: false
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
  private var disconnected = false

  fileprivate init(
    sourceUID: String,
    capabilities: MediaSourceCapabilities,
    session: any SMB2Session
  ) {
    self.sourceUID = sourceUID
    self.capabilities = capabilities
    self.session = session
  }

  public func listDirectory(_ request: RemoteDirectoryPageRequest) async throws
    -> CursorPage<RemoteEntry>
  {
    try requireConnected()
    let directoryPath = try smbPath(for: request.directory)
    let entries = try await session.listDirectory(at: directoryPath)
      .map(convert)
      .sorted { left, right in
        let leftKey = left.locator.pathComparisonKey(using: capabilities.pathSemantics)
        let rightKey = right.locator.pathComparisonKey(using: capabilities.pathSemantics)
        if leftKey == rightKey {
          return left.locator.path.relativePath < right.locator.path.relativePath
        }
        return leftKey < rightKey
      }
    let fingerprint = Self.fingerprint(entries, semantics: capabilities.pathSemantics)
    let offset: Int
    if let cursor = request.cursor {
      let parsed = try SMBDirectoryCursor(cursor)
      guard parsed.fingerprint == fingerprint, parsed.offset <= entries.count else {
        throw SDKError(code: .conflict, message: "SMB directory changed during pagination")
      }
      offset = parsed.offset
    } else {
      offset = 0
    }

    let count = min(request.limit, entries.count - offset)
    let upperBound = offset + count
    let pageEntries = Array(entries[offset..<upperBound])
    let nextCursor: String?
    if upperBound < entries.count {
      nextCursor =
        SMBDirectoryCursor(
          offset: upperBound,
          fingerprint: fingerprint
        ).rawValue
    } else {
      nextCursor = nil
    }
    return try CursorPage(items: pageEntries, nextCursor: nextCursor)
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
    let path = try RemotePath(entry.path.relativePath)
    let locator = try RemoteLocator(sourceUID: sourceUID, path: path)
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

  private static func fingerprint(
    _ entries: [RemoteEntry],
    semantics: RemotePathSemantics
  ) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for entry in entries {
      let fields = [
        entry.locator.pathComparisonKey(using: semantics),
        entry.kind.rawValue,
        entry.stableID ?? "",
        entry.size.map(String.init) ?? "",
        entry.modifiedAtMilliseconds.map(String.init) ?? "",
      ]
      for byte in fields.joined(separator: "\u{1f}").utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
      }
      hash ^= 0xff
      hash &*= 1_099_511_628_211
    }
    return String(format: "%016llx", hash)
  }

  private struct SMBDirectoryCursor {
    let offset: Int
    let fingerprint: String

    var rawValue: String { "smb-v1:\(offset):\(fingerprint)" }

    init(offset: Int, fingerprint: String) {
      self.offset = offset
      self.fingerprint = fingerprint
    }

    init(_ rawValue: String) throws {
      let components = rawValue.split(separator: ":", omittingEmptySubsequences: false)
      guard components.count == 3,
        components[0] == "smb-v1",
        let offset = Int(components[1]),
        offset > 0,
        components[2].count == 16,
        components[2].allSatisfy({ $0.isHexDigit })
      else {
        throw SDKError(code: .invalidConfiguration, message: "SMB page cursor is invalid")
      }
      self.offset = offset
      fingerprint = String(components[2])
    }
  }
}

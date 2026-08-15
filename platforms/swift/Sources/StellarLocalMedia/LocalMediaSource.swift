import Foundation
import StellarCore
import StellarRemoteMedia

/// Read-only configuration for a local directory media source.
public struct LocalMediaSourceConfiguration: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let sourceUID: String
  public let rootURL: URL
  public let pathSemantics: RemotePathSemantics?

  public init(
    sourceUID: String,
    rootURL: URL,
    pathSemantics: RemotePathSemantics? = nil
  ) throws {
    let normalizedRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    guard !sourceUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !sourceUID.contains("\0"),
      rootURL.isFileURL,
      normalizedRoot.path.hasPrefix("/"),
      !normalizedRoot.path.contains("\0")
    else {
      throw SDKError(
        code: .invalidConfiguration,
        message: "local media source configuration is invalid"
      )
    }
    self.sourceUID = sourceUID
    self.rootURL = normalizedRoot
    self.pathSemantics = pathSemantics
  }

  /// A representation that hides the source identifier and local path.
  public var description: String { "<LocalMediaSourceConfiguration redacted>" }

  /// A representation that hides the source identifier and local path.
  public var debugDescription: String { description }
}

/// Connects the shared scanner contract to a macOS or Linux local directory.
public struct LocalMediaSourceConnector: MediaSourceConnector {
  public let configuration: LocalMediaSourceConfiguration

  public init(configuration: LocalMediaSourceConfiguration) {
    self.configuration = configuration
  }

  public func connect() async throws -> any MediaSourceSession {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard
      fileManager.fileExists(
        atPath: configuration.rootURL.path,
        isDirectory: &isDirectory
      ), isDirectory.boolValue
    else {
      throw SDKError(code: .remoteUnavailable, message: "local media source is unavailable")
    }
    guard fileManager.isReadableFile(atPath: configuration.rootURL.path) else {
      throw SDKError(code: .forbidden, message: "local media source is not readable")
    }

    let rootStableID = Self.stableID(for: configuration.rootURL, fileManager: fileManager)
    let pathSemantics =
      configuration.pathSemantics
      ?? Self.detectPathSemantics(at: configuration.rootURL)
    let capabilities = try MediaSourceCapabilities(
      stableIDScope: rootStableID == nil ? .none : .scan,
      pathSemantics: pathSemantics,
      supportsRangeReads: true,
      supportsChangeCursor: false,
      deltaDeletionsComplete: false
    )
    return LocalMediaSourceSession(
      configuration: configuration,
      capabilities: capabilities,
      fileManager: fileManager
    )
  }

  private static func stableID(for url: URL, fileManager: FileManager) -> String? {
    guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
      let fileSystem = attributes[.systemNumber] as? NSNumber,
      let file = attributes[.systemFileNumber] as? NSNumber
    else {
      return nil
    }
    return "\(fileSystem.uint64Value):\(file.uint64Value)"
  }

  private static func detectPathSemantics(at rootURL: URL) -> RemotePathSemantics {
    #if os(Linux)
      let caseSensitivity = RemotePathCaseSensitivity.sensitive
    #else
      let values = try? rootURL.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
      let caseSensitivity: RemotePathCaseSensitivity
      switch values?.volumeSupportsCaseSensitiveNames {
      case true:
        caseSensitivity = .sensitive
      case false:
        caseSensitivity = .insensitive
      case nil:
        caseSensitivity = .unknown
      }
    #endif
    return RemotePathSemantics(
      caseSensitivity: caseSensitivity,
      unicodeNormalization: .preserve
    )
  }
}

/// A connected, read-only local directory session.
public actor LocalMediaSourceSession: MediaSourceSession {
  public nonisolated let sourceUID: String
  public nonisolated let capabilities: MediaSourceCapabilities

  private let rootURL: URL
  private let fileManager: FileManager
  private var disconnected = false

  fileprivate init(
    configuration: LocalMediaSourceConfiguration,
    capabilities: MediaSourceCapabilities,
    fileManager: FileManager
  ) {
    sourceUID = configuration.sourceUID
    rootURL = configuration.rootURL
    self.capabilities = capabilities
    self.fileManager = fileManager
  }

  public func listDirectory(_ request: RemoteDirectoryPageRequest) async throws
    -> CursorPage<RemoteEntry>
  {
    try requireConnected()
    guard request.directory.sourceUID == sourceUID else {
      throw SDKError(code: .invalidConfiguration, message: "local source UID does not match")
    }

    let directoryURL = try confinedURL(for: request.directory)
    let directory = try makeEntry(at: directoryURL, locator: request.directory)
    guard directory.kind == .directory else {
      throw SDKError(
        code: .invalidConfiguration, message: "local enumeration target is not a directory")
    }

    let snapshot = try directorySnapshot(at: directoryURL, locator: request.directory)
    let offset: Int
    if let cursor = request.cursor {
      let parsed = try LocalDirectoryCursor(cursor)
      guard parsed.fingerprint == snapshot.fingerprint,
        parsed.offset <= snapshot.entries.count
      else {
        throw SDKError(
          code: .conflict,
          message: "local directory changed during pagination"
        )
      }
      offset = parsed.offset
    } else {
      offset = 0
    }

    let count = min(request.limit, snapshot.entries.count - offset)
    let upperBound = offset + count
    let entries = Array(snapshot.entries[offset..<upperBound])
    let nextCursor: String?
    if upperBound < snapshot.entries.count {
      nextCursor =
        LocalDirectoryCursor(
          offset: upperBound,
          fingerprint: snapshot.fingerprint
        ).rawValue
    } else {
      nextCursor = nil
    }
    return try CursorPage(items: entries, nextCursor: nextCursor)
  }

  public func stat(_ locator: RemoteLocator) async throws -> RemoteEntry {
    try requireConnected()
    guard locator.sourceUID == sourceUID else {
      throw SDKError(code: .invalidConfiguration, message: "local source UID does not match")
    }
    return try makeEntry(at: confinedURL(for: locator), locator: locator)
  }

  public func read(at locator: RemoteLocator, range: RemoteByteRange) async throws -> Data {
    try requireConnected()
    guard locator.sourceUID == sourceUID else {
      throw SDKError(code: .invalidConfiguration, message: "local source UID does not match")
    }
    let url = try confinedURL(for: locator)
    let entry = try makeEntry(at: url, locator: locator)
    guard entry.kind == .file else {
      throw SDKError(code: .invalidConfiguration, message: "local range read requires a file")
    }

    do {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      try handle.seek(toOffset: UInt64(range.offset))
      return try handle.read(upToCount: range.length) ?? Data()
    } catch {
      throw Self.mapFileError(error, fallback: .storageFailure, operation: "read")
    }
  }

  public func disconnect() async {
    disconnected = true
  }

  private func requireConnected() throws {
    guard !disconnected else {
      throw SDKError(code: .remoteUnavailable, message: "local media session is disconnected")
    }
  }

  private func confinedURL(for locator: RemoteLocator) throws -> URL {
    var candidate = rootURL
    for component in locator.path.components {
      candidate.appendPathComponent(component, isDirectory: false)
    }
    candidate = candidate.standardizedFileURL
    let resolved = candidate.resolvingSymlinksInPath()
    let rootComponents = rootURL.pathComponents
    let candidateComponents = resolved.pathComponents
    guard candidateComponents.count >= rootComponents.count,
      candidateComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
    else {
      throw SDKError(
        code: .forbidden,
        message: "local path resolves outside the configured source"
      )
    }
    return candidate
  }

  private func directorySnapshot(
    at directoryURL: URL,
    locator: RemoteLocator
  ) throws -> DirectorySnapshot {
    do {
      let urls = try fileManager.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: Self.resourceKeys,
        options: []
      )
      var entries: [RemoteEntry] = []
      entries.reserveCapacity(urls.count)
      for url in urls {
        let child = try locator.path.appending(component: url.lastPathComponent)
        let childLocator = try RemoteLocator(sourceUID: sourceUID, path: child)
        entries.append(try makeEntry(at: url, locator: childLocator))
      }
      entries.sort { left, right in
        let leftKey = left.locator.pathComparisonKey(using: capabilities.pathSemantics)
        let rightKey = right.locator.pathComparisonKey(using: capabilities.pathSemantics)
        if leftKey == rightKey {
          return left.locator.path.relativePath < right.locator.path.relativePath
        }
        return leftKey < rightKey
      }
      return DirectorySnapshot(
        entries: entries,
        fingerprint: Self.fingerprint(entries, semantics: capabilities.pathSemantics)
      )
    } catch let error as SDKError {
      throw error
    } catch {
      throw Self.mapFileError(error, fallback: .remoteUnavailable, operation: "enumerate")
    }
  }

  private func makeEntry(at url: URL, locator: RemoteLocator) throws -> RemoteEntry {
    do {
      let values = try url.resourceValues(forKeys: Set(Self.resourceKeys))
      let kind: RemoteEntryKind
      if values.isSymbolicLink == true {
        kind = .symbolicLink
      } else if values.isDirectory == true {
        kind = .directory
      } else if values.isRegularFile == true {
        kind = .file
      } else {
        kind = .unknown
      }
      let size = kind == .file ? values.fileSize.map(Int64.init) : nil
      let modifiedAt = values.contentModificationDate.map {
        Int64(($0.timeIntervalSince1970 * 1_000).rounded(.towardZero))
      }
      let stableID: String?
      if kind == .symbolicLink {
        stableID = nil
      } else {
        stableID = Self.stableID(at: url, fileManager: fileManager)
      }
      return try RemoteEntry(
        locator: locator,
        kind: kind,
        stableID: stableID,
        size: size,
        modifiedAtMilliseconds: modifiedAt
      )
    } catch let error as SDKError {
      throw error
    } catch {
      throw Self.mapFileError(error, fallback: .remoteUnavailable, operation: "stat")
    }
  }

  private static let resourceKeys: [URLResourceKey] = [
    .isSymbolicLinkKey,
    .isDirectoryKey,
    .isRegularFileKey,
    .fileSizeKey,
    .contentModificationDateKey,
  ]

  private static func stableID(at url: URL, fileManager: FileManager) -> String? {
    guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
      let fileSystem = attributes[.systemNumber] as? NSNumber,
      let file = attributes[.systemFileNumber] as? NSNumber
    else {
      return nil
    }
    return "\(fileSystem.uint64Value):\(file.uint64Value)"
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
        entry.entityTag ?? "",
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

  private static func mapFileError(
    _ error: any Error,
    fallback: SDKErrorCode,
    operation: String
  ) -> SDKError {
    let code: SDKErrorCode
    let nsError = error as NSError
    if nsError.domain == NSPOSIXErrorDomain {
      switch POSIXErrorCode(rawValue: Int32(nsError.code)) {
      case .EACCES, .EPERM:
        code = .forbidden
      case .ENOENT, .ENOTDIR:
        code = .metadataNotFound
      default:
        code = fallback
      }
    } else {
      switch nsError.code {
      case NSFileReadNoPermissionError:
        code = .forbidden
      case NSFileNoSuchFileError:
        code = .metadataNotFound
      default:
        code = fallback
      }
    }
    return SDKError(code: code, message: "local media \(operation) failed")
  }

  private struct DirectorySnapshot {
    let entries: [RemoteEntry]
    let fingerprint: String
  }

  private struct LocalDirectoryCursor {
    let offset: Int
    let fingerprint: String

    var rawValue: String { "local-v1:\(offset):\(fingerprint)" }

    init(offset: Int, fingerprint: String) {
      self.offset = offset
      self.fingerprint = fingerprint
    }

    init(_ rawValue: String) throws {
      let components = rawValue.split(separator: ":", omittingEmptySubsequences: false)
      guard components.count == 3,
        components[0] == "local-v1",
        let offset = Int(components[1]),
        offset > 0,
        components[2].count == 16,
        components[2].allSatisfy({ $0.isHexDigit })
      else {
        throw SDKError(code: .invalidConfiguration, message: "local page cursor is invalid")
      }
      self.offset = offset
      fingerprint = String(components[2])
    }
  }
}

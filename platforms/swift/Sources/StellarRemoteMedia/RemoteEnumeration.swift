import Foundation
import StellarCore

/// Whether a source distinguishes path-component letter case.
public enum RemotePathCaseSensitivity: String, Sendable {
  case sensitive
  case insensitive
  case unknown
}

extension RemotePathCaseSensitivity: Codable {
  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = RemotePathCaseSensitivity(rawValue: value) ?? .unknown
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// The Unicode normalization rule declared by a media source.
public enum RemoteUnicodeNormalization: String, Sendable {
  case preserve
  case nfc
  case nfd
  case unknown
}

extension RemoteUnicodeNormalization: Codable {
  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = RemoteUnicodeNormalization(rawValue: value) ?? .unknown
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// Comparison rules for paths within one media source.
public struct RemotePathSemantics: Codable, Equatable, Sendable {
  public let caseSensitivity: RemotePathCaseSensitivity
  public let unicodeNormalization: RemoteUnicodeNormalization

  public init(
    caseSensitivity: RemotePathCaseSensitivity,
    unicodeNormalization: RemoteUnicodeNormalization
  ) {
    self.caseSensitivity = caseSensitivity
    self.unicodeNormalization = unicodeNormalization
  }

  private enum CodingKeys: String, CodingKey {
    case caseSensitivity = "case_sensitivity"
    case unicodeNormalization = "unicode_normalization"
  }
}

/// A normalized path relative to a configured media-source root.
public struct RemotePath: Codable, Equatable, Hashable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  /// The normalized slash-separated path, or an empty string for the source root.
  public let relativePath: String

  /// Creates a root-relative path, removing redundant separators and `.` components.
  public init(_ path: String = "") throws {
    guard !path.hasPrefix("/"), !path.contains("\0") else {
      throw SDKError(code: .invalidConfiguration, message: "remote path must be root-relative")
    }

    var components: [Substring] = []
    for component in path.split(separator: "/", omittingEmptySubsequences: true) {
      if component == "." {
        continue
      }
      guard component != ".." else {
        throw SDKError(
          code: .invalidConfiguration, message: "remote path must not traverse parents")
      }
      components.append(component)
    }
    relativePath = components.joined(separator: "/")
  }

  /// Whether this path identifies the configured source root.
  public var isRoot: Bool { relativePath.isEmpty }

  /// Individual display-path components without applying comparison semantics.
  public var components: [String] {
    relativePath.split(separator: "/").map(String.init)
  }

  /// The final display-path component, or an empty string for the root.
  public var name: String { components.last ?? "" }

  /// The parent path, or `nil` when this is the root.
  public var parent: RemotePath? {
    guard !isRoot else {
      return nil
    }
    return try? RemotePath(components.dropLast().joined(separator: "/"))
  }

  /// Returns a child path without accepting separators, NUL, or traversal components.
  public func appending(component: String) throws -> RemotePath {
    guard !component.isEmpty, component != ".", component != "..",
      !component.contains("/"), !component.contains("\0")
    else {
      throw SDKError(code: .invalidConfiguration, message: "invalid remote path component")
    }
    return try RemotePath(isRoot ? component : "\(relativePath)/\(component)")
  }

  /// Produces a same-source comparison key without changing the display path.
  public func comparisonKey(using semantics: RemotePathSemantics) -> String {
    components
      .map { component in
        var result = Self.normalize(component, using: semantics.unicodeNormalization)
        if semantics.caseSensitivity == .insensitive {
          result = result.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
          )
          result = Self.normalize(result, using: semantics.unicodeNormalization)
        }
        return result
      }
      .joined(separator: "/")
  }

  /// Tests descendant scope using path components rather than string prefixes.
  public func isDescendant(of ancestor: RemotePath, using semantics: RemotePathSemantics) -> Bool {
    let candidateComponents = comparisonKey(using: semantics).split(separator: "/")
    let ancestorComponents = ancestor.comparisonKey(using: semantics).split(separator: "/")
    guard candidateComponents.count > ancestorComponents.count else {
      return false
    }
    return candidateComponents.starts(with: ancestorComponents)
  }

  /// A redacted representation safe for routine diagnostics.
  public var description: String { SensitiveDataRedactor.pathPlaceholder }

  /// A redacted representation safe for routine diagnostics.
  public var debugDescription: String { description }

  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    do {
      try self.init(value)
    } catch let error as SDKError {
      throw DecodingError.dataCorruptedError(
        in: try decoder.singleValueContainer(),
        debugDescription: error.message
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(relativePath)
  }

  private static func normalize(
    _ value: String,
    using normalization: RemoteUnicodeNormalization
  ) -> String {
    switch normalization {
    case .nfc:
      value.precomposedStringWithCanonicalMapping
    case .nfd:
      value.decomposedStringWithCanonicalMapping
    case .preserve, .unknown:
      value
    }
  }
}

/// A source-qualified locator. Equal paths from different sources remain different locators.
public struct RemoteLocator: Codable, Equatable, Hashable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let sourceUID: String
  public let path: RemotePath

  public init(sourceUID: String, path: RemotePath) throws {
    guard !sourceUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !sourceUID.contains("\0")
    else {
      throw SDKError(code: .invalidConfiguration, message: "remote source UID is invalid")
    }
    self.sourceUID = sourceUID
    self.path = path
  }

  /// The path-only key used for comparisons within this locator's source.
  public func pathComparisonKey(using semantics: RemotePathSemantics) -> String {
    path.comparisonKey(using: semantics)
  }

  /// A representation that hides source and path identifiers.
  public var description: String { "<RemoteLocator redacted>" }

  /// A representation that hides source and path identifiers.
  public var debugDescription: String { description }

  private enum CodingKeys: String, CodingKey {
    case sourceUID = "source_uid"
    case path = "relative_path"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        sourceUID: container.decode(String.self, forKey: .sourceUID),
        path: container.decode(RemotePath.self, forKey: .path)
      )
    } catch let error as SDKError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message)
      )
    }
  }
}

/// How long a connector promises an entry stable ID remains meaningful.
public enum RemoteStableIDScope: String, Sendable {
  case none
  case scan
  case persistent
  case unknown
}

extension RemoteStableIDScope: Codable {
  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = RemoteStableIDScope(rawValue: value) ?? .unknown
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// Source facts that determine safe enumeration and identity behavior.
public struct MediaSourceCapabilities: Codable, Equatable, Sendable {
  public let stableIDScope: RemoteStableIDScope
  public let pathSemantics: RemotePathSemantics
  public let supportsRangeReads: Bool
  public let supportsChangeCursor: Bool
  public let deltaDeletionsComplete: Bool

  public init(
    stableIDScope: RemoteStableIDScope,
    pathSemantics: RemotePathSemantics,
    supportsRangeReads: Bool,
    supportsChangeCursor: Bool,
    deltaDeletionsComplete: Bool
  ) throws {
    guard supportsChangeCursor || !deltaDeletionsComplete else {
      throw SDKError(
        code: .invalidConfiguration,
        message: "complete delta deletions require change-cursor support"
      )
    }
    self.stableIDScope = stableIDScope
    self.pathSemantics = pathSemantics
    self.supportsRangeReads = supportsRangeReads
    self.supportsChangeCursor = supportsChangeCursor
    self.deltaDeletionsComplete = deltaDeletionsComplete
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        stableIDScope: container.decode(RemoteStableIDScope.self, forKey: .stableIDScope),
        pathSemantics: RemotePathSemantics(
          caseSensitivity: container.decode(
            RemotePathCaseSensitivity.self,
            forKey: .caseSensitivity
          ),
          unicodeNormalization: container.decode(
            RemoteUnicodeNormalization.self,
            forKey: .unicodeNormalization
          )
        ),
        supportsRangeReads: container.decode(Bool.self, forKey: .supportsRangeReads),
        supportsChangeCursor: container.decode(Bool.self, forKey: .supportsChangeCursor),
        deltaDeletionsComplete: container.decode(Bool.self, forKey: .deltaDeletionsComplete)
      )
    } catch let error as SDKError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message)
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(stableIDScope, forKey: .stableIDScope)
    try container.encode(pathSemantics.caseSensitivity, forKey: .caseSensitivity)
    try container.encode(pathSemantics.unicodeNormalization, forKey: .unicodeNormalization)
    try container.encode(supportsRangeReads, forKey: .supportsRangeReads)
    try container.encode(supportsChangeCursor, forKey: .supportsChangeCursor)
    try container.encode(deltaDeletionsComplete, forKey: .deltaDeletionsComplete)
  }

  private enum CodingKeys: String, CodingKey {
    case stableIDScope = "stable_id_scope"
    case caseSensitivity = "case_sensitivity"
    case unicodeNormalization = "unicode_normalization"
    case supportsRangeReads = "supports_range_reads"
    case supportsChangeCursor = "supports_change_cursor"
    case deltaDeletionsComplete = "delta_deletions_complete"
  }
}

/// The source-independent kind of a remote entry.
public enum RemoteEntryKind: String, Sendable {
  case file
  case directory
  case symbolicLink = "symbolic_link"
  case unknown
}

extension RemoteEntryKind: Codable {
  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = RemoteEntryKind(rawValue: value) ?? .unknown
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// A read-only source entry suitable for scanner fixtures and persistence.
public struct RemoteEntry: Codable, Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let locator: RemoteLocator
  public let kind: RemoteEntryKind
  public let stableID: String?
  public let size: Int64?
  public let modifiedAtMilliseconds: Int64?
  public let entityTag: String?

  public init(
    locator: RemoteLocator,
    kind: RemoteEntryKind,
    stableID: String? = nil,
    size: Int64? = nil,
    modifiedAtMilliseconds: Int64? = nil,
    entityTag: String? = nil
  ) throws {
    guard size.map({ $0 >= 0 }) ?? true else {
      throw SDKError(code: .parseFailure, message: "remote entry size must not be negative")
    }
    guard stableID?.isEmpty != true, stableID?.contains("\0") != true else {
      throw SDKError(code: .parseFailure, message: "remote stable ID is invalid")
    }
    self.locator = locator
    self.kind = kind
    self.stableID = stableID
    self.size = size
    self.modifiedAtMilliseconds = modifiedAtMilliseconds
    self.entityTag = entityTag
  }

  /// A representation that hides locator, stable ID, and etag values.
  public var description: String {
    "<RemoteEntry kind=\(kind.rawValue) size=\(size.map(String.init) ?? "unknown")>"
  }

  /// A representation that hides locator, stable ID, and etag values.
  public var debugDescription: String { description }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        locator: container.decode(RemoteLocator.self, forKey: .locator),
        kind: container.decode(RemoteEntryKind.self, forKey: .kind),
        stableID: container.decodeIfPresent(String.self, forKey: .stableID),
        size: container.decodeIfPresent(Int64.self, forKey: .size),
        modifiedAtMilliseconds: container.decodeIfPresent(
          Int64.self,
          forKey: .modifiedAtMilliseconds
        ),
        entityTag: container.decodeIfPresent(String.self, forKey: .entityTag)
      )
    } catch let error as SDKError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message)
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case locator
    case kind
    case stableID = "stable_id"
    case size
    case modifiedAtMilliseconds = "modified_at_ms"
    case entityTag = "etag"
  }
}

/// A validated request for one page of a directory enumeration.
public struct RemoteDirectoryPageRequest: Codable, Equatable, Hashable, Sendable {
  public let directory: RemoteLocator
  public let cursor: String?
  public let limit: Int

  public init(directory: RemoteLocator, cursor: String? = nil, limit: Int = 500) throws {
    guard cursor?.isEmpty != true, limit > 0 else {
      throw SDKError(code: .invalidConfiguration, message: "remote page request is invalid")
    }
    self.directory = directory
    self.cursor = cursor
    self.limit = limit
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        directory: container.decode(RemoteLocator.self, forKey: .directory),
        cursor: container.decodeIfPresent(String.self, forKey: .cursor),
        limit: container.decode(Int.self, forKey: .limit)
      )
    } catch let error as SDKError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message)
      )
    }
  }
}

/// A validated byte range for a source-independent read operation.
public struct RemoteByteRange: Codable, Equatable, Sendable {
  public let offset: Int64
  public let length: Int

  public init(offset: Int64, length: Int) throws {
    guard offset >= 0, length > 0, Int64(length) <= Int64.max - offset else {
      throw SDKError(code: .invalidConfiguration, message: "remote byte range is invalid")
    }
    self.offset = offset
    self.length = length
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        offset: container.decode(Int64.self, forKey: .offset),
        length: container.decode(Int.self, forKey: .length)
      )
    } catch let error as SDKError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message)
      )
    }
  }
}

/// A connected read-only media source with cursor-paginated directory enumeration.
public protocol MediaSourceSession: Sendable {
  var sourceUID: String { get }
  var capabilities: MediaSourceCapabilities { get async }
  func listDirectory(_ request: RemoteDirectoryPageRequest) async throws
    -> CursorPage<RemoteEntry>
  func stat(_ locator: RemoteLocator) async throws -> RemoteEntry
  func read(at locator: RemoteLocator, range: RemoteByteRange) async throws -> Data
  func disconnect() async
}

/// Injectable connection boundary shared by local, SMB, WebDAV, and fake connectors.
public protocol MediaSourceConnector: Sendable {
  func connect() async throws -> any MediaSourceSession
}

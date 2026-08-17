import Foundation
import StellarCore

/// A synchronized media-source category independent of any platform connector type.
public enum MediaSourceKind: Equatable, Sendable {
  case localFolder
  case deviceMedia
  case smb
  case nfs
  case webdav
  case ftp
  case cloudDrive
  case plex
  case emby
  case jellyfin
  case unknown(String)
}

extension MediaSourceKind: Codable {
  public init(from decoder: Decoder) throws {
    self = Self.decode(try decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(wireValue)
  }

  private static func decode(_ value: String) -> MediaSourceKind {
    switch value {
    case "local_folder": .localFolder
    case "device_media": .deviceMedia
    case "smb": .smb
    case "nfs": .nfs
    case "webdav": .webdav
    case "ftp": .ftp
    case "cloud_drive": .cloudDrive
    case "plex": .plex
    case "emby": .emby
    case "jellyfin": .jellyfin
    default: .unknown(value)
    }
  }

  package var wireValue: String {
    switch self {
    case .localFolder: "local_folder"
    case .deviceMedia: "device_media"
    case .smb: "smb"
    case .nfs: "nfs"
    case .webdav: "webdav"
    case .ftp: "ftp"
    case .cloudDrive: "cloud_drive"
    case .plex: "plex"
    case .emby: "emby"
    case .jellyfin: "jellyfin"
    case .unknown(let value): value
    }
  }
}

/// How a client reaches the configured media source.
public enum MediaSourceConnectionMode: Equatable, Sendable {
  case direct
  case relay
  case automatic
  case unknown(String)
}

extension MediaSourceConnectionMode: Codable {
  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self =
      switch value {
      case "direct": .direct
      case "relay": .relay
      case "automatic": .automatic
      default: .unknown(value)
      }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(wireValue)
  }

  package var wireValue: String {
    switch self {
    case .direct: "direct"
    case .relay: "relay"
    case .automatic: "automatic"
    case .unknown(let value): value
    }
  }
}

/// Where connector credentials are expected to be resolved.
public enum MediaSourceCredentialMode: Equatable, Sendable {
  case synced
  case deviceLocal
  case serverManaged
  case none
  case unknown(String)
}

extension MediaSourceCredentialMode: Codable {
  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self =
      switch value {
      case "synced": .synced
      case "device_local": .deviceLocal
      case "server_managed": .serverManaged
      case "none": .none
      default: .unknown(value)
      }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(wireValue)
  }

  package var wireValue: String {
    switch self {
    case .synced: "synced"
    case .deviceLocal: "device_local"
    case .serverManaged: "server_managed"
    case .none: "none"
    case .unknown(let value): value
    }
  }
}

/// One connector ability advertised by a synchronized source configuration.
public enum MediaSourceCapability: Equatable, Hashable, Sendable {
  case list
  case read
  case rangeRead
  case changeCursor
  case serverSearch
  case stableID
  case unknown(String)
}

extension MediaSourceCapability: Codable {
  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self =
      switch value {
      case "list": .list
      case "read": .read
      case "range_read": .rangeRead
      case "change_cursor": .changeCursor
      case "server_search": .serverSearch
      case "stable_id": .stableID
      default: .unknown(value)
      }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(wireValue)
  }

  package var wireValue: String {
    switch self {
    case .list: "list"
    case .read: "read"
    case .rangeRead: "range_read"
    case .changeCursor: "change_cursor"
    case .serverSearch: "server_search"
    case .stableID: "stable_id"
    case .unknown(let value): value
    }
  }
}

/// Non-secret protocol endpoint fields. Userinfo and credential-bearing URLs are forbidden.
public struct MediaSourceEndpoint: Codable, Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let scheme: String
  public let host: String?
  public let port: Int?
  public let usesTLS: Bool
  public let serviceIdentifier: String?

  public init(
    scheme: String,
    host: String? = nil,
    port: Int? = nil,
    usesTLS: Bool,
    serviceIdentifier: String? = nil
  ) throws {
    let normalizedScheme = scheme.lowercased()
    let normalizedHost = host?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedServiceIdentifier = serviceIdentifier?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      normalizedScheme.range(of: #"^[a-z][a-z0-9+.-]{0,31}$"#, options: .regularExpression)
        != nil,
      normalizedHost?.isEmpty != true,
      normalizedHost.map(Self.validHost) ?? true,
      port.map({ (1...65_535).contains($0) }) ?? true,
      normalizedServiceIdentifier?.isEmpty != true,
      normalizedServiceIdentifier.map({
        $0.utf8.count <= 1_024
          && $0.rangeOfCharacter(from: .controlCharacters) == nil
      }) ?? true
    else {
      throw SDKError(code: .invalidConfiguration, message: "media source endpoint is invalid")
    }
    self.scheme = normalizedScheme
    self.host = normalizedHost
    self.port = port
    self.usesTLS = usesTLS
    self.serviceIdentifier = normalizedServiceIdentifier
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        scheme: container.decode(String.self, forKey: .scheme),
        host: container.decodeIfPresent(String.self, forKey: .host),
        port: container.decodeIfPresent(Int.self, forKey: .port),
        usesTLS: container.decode(Bool.self, forKey: .usesTLS),
        serviceIdentifier: container.decodeIfPresent(String.self, forKey: .serviceIdentifier)
      )
    } catch let error as SDKError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message)
      )
    }
  }

  /// A representation that never reveals host or service identity.
  public var description: String { "<MediaSourceEndpoint scheme=\(scheme) redacted>" }

  /// A representation that never reveals host or service identity.
  public var debugDescription: String { description }

  private static func validHost(_ value: String) -> Bool {
    value.rangeOfCharacter(from: .controlCharacters) == nil
      && value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
      && !value.contains("@") && !value.contains("/")
      && !value.contains("\\") && !value.contains("://")
  }

  private enum CodingKeys: String, CodingKey {
    case scheme
    case host
    case port
    case usesTLS = "uses_tls"
    case serviceIdentifier = "service_identifier"
  }
}

/// Cross-platform automatic scan scheduling preferences.
public struct MediaSourceScanPolicy: Codable, Equatable, Sendable {
  public let automatic: Bool
  public let intervalMilliseconds: Int64?
  public let unmeteredNetworkOnly: Bool
  public let externalPowerOnly: Bool

  public init(
    automatic: Bool = true,
    intervalMilliseconds: Int64? = nil,
    unmeteredNetworkOnly: Bool = false,
    externalPowerOnly: Bool = false
  ) throws {
    guard intervalMilliseconds.map({ $0 >= 60_000 }) ?? true,
      automatic || intervalMilliseconds == nil
    else {
      throw SDKError(code: .invalidConfiguration, message: "media source scan policy is invalid")
    }
    self.automatic = automatic
    self.intervalMilliseconds = intervalMilliseconds
    self.unmeteredNetworkOnly = unmeteredNetworkOnly
    self.externalPowerOnly = externalPowerOnly
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        automatic: container.decodeIfPresent(Bool.self, forKey: .automatic) ?? true,
        intervalMilliseconds: container.decodeIfPresent(Int64.self, forKey: .intervalMilliseconds),
        unmeteredNetworkOnly: container.decodeIfPresent(
          Bool.self,
          forKey: .unmeteredNetworkOnly
        ) ?? false,
        externalPowerOnly: container.decodeIfPresent(Bool.self, forKey: .externalPowerOnly)
          ?? false
      )
    } catch let error as SDKError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message)
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case automatic
    case intervalMilliseconds = "interval_ms"
    case unmeteredNetworkOnly = "unmetered_network_only"
    case externalPowerOnly = "external_power_only"
  }
}

/// Language and provider precedence used by metadata repair jobs.
public struct MediaSourceMetadataPolicy: Codable, Equatable, Sendable {
  public let language: String
  public let region: String?
  public let preferredProviders: [String]
  public let preferLocalMetadata: Bool

  public init(
    language: String = "und",
    region: String? = nil,
    preferredProviders: [String] = [],
    preferLocalMetadata: Bool = true
  ) throws {
    let normalizedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedRegion = region?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let normalizedProviders = preferredProviders.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    guard Self.validLanguage(normalizedLanguage),
      normalizedRegion.map({ $0.range(of: #"^[A-Z]{2}$"#, options: .regularExpression) != nil })
        ?? true,
      normalizedProviders.allSatisfy({
        !$0.isEmpty && !$0.contains("\0")
          && $0.range(of: #"^[a-z0-9][a-z0-9_.-]{0,63}$"#, options: .regularExpression) != nil
      }),
      Set(normalizedProviders).count == normalizedProviders.count
    else {
      throw SDKError(
        code: .invalidConfiguration,
        message: "media source metadata policy is invalid"
      )
    }
    self.language = normalizedLanguage
    self.region = normalizedRegion
    self.preferredProviders = normalizedProviders
    self.preferLocalMetadata = preferLocalMetadata
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        language: container.decodeIfPresent(String.self, forKey: .language) ?? "und",
        region: container.decodeIfPresent(String.self, forKey: .region),
        preferredProviders: container.decodeIfPresent(
          [String].self,
          forKey: .preferredProviders
        ) ?? [],
        preferLocalMetadata: container.decodeIfPresent(Bool.self, forKey: .preferLocalMetadata)
          ?? true
      )
    } catch let error as SDKError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message)
      )
    }
  }

  private static func validLanguage(_ value: String) -> Bool {
    value == "und"
      || value.range(
        of: #"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})?$"#,
        options: .regularExpression
      ) != nil
  }

  private enum CodingKeys: String, CodingKey {
    case language
    case region
    case preferredProviders = "preferred_providers"
    case preferLocalMetadata = "prefer_local_metadata"
  }
}

/// A versioned, non-secret media-source configuration synchronized per Stellar account.
public struct MediaSourceConfig: Codable, Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let sourceUID: String
  public let accountUID: String
  public let kind: MediaSourceKind
  public let displayName: String
  public let endpoint: MediaSourceEndpoint
  public let rootPath: String
  public let includedPaths: [String]
  public let excludedPaths: [String]
  public let scanPolicy: MediaSourceScanPolicy
  public let metadataPolicy: MediaSourceMetadataPolicy
  public let connectionMode: MediaSourceConnectionMode
  public let credentialMode: MediaSourceCredentialMode
  public let credentialUID: String?
  public let capabilities: [MediaSourceCapability]
  public let revision: Int64
  public let updatedAtMilliseconds: Int64
  public let deletedAtMilliseconds: Int64?
  public let schemaVersion: Int

  public init(
    sourceUID: String,
    accountUID: String,
    kind: MediaSourceKind,
    displayName: String,
    endpoint: MediaSourceEndpoint,
    rootPath: String,
    includedPaths: [String] = [""],
    excludedPaths: [String] = [],
    scanPolicy: MediaSourceScanPolicy,
    metadataPolicy: MediaSourceMetadataPolicy,
    connectionMode: MediaSourceConnectionMode = .automatic,
    credentialMode: MediaSourceCredentialMode,
    credentialUID: String? = nil,
    capabilities: [MediaSourceCapability] = [],
    revision: Int64,
    updatedAtMilliseconds: Int64,
    deletedAtMilliseconds: Int64? = nil,
    schemaVersion: Int = 1
  ) throws {
    let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedIncludedPaths = includedPaths.map(Self.normalizePath)
    let normalizedExcludedPaths = excludedPaths.map(Self.normalizePath)
    let normalizedCapabilities = capabilities.sorted { $0.wireValue < $1.wireValue }
    guard !sourceUID.isEmpty, !accountUID.isEmpty,
      !sourceUID.contains("\0"), !accountUID.contains("\0"),
      Self.validWireValue(kind.wireValue), Self.validWireValue(connectionMode.wireValue),
      Self.validWireValue(credentialMode.wireValue),
      !normalizedDisplayName.isEmpty, !normalizedDisplayName.contains("\0"),
      Self.validPath(rootPath), normalizedIncludedPaths.allSatisfy(Self.validPath),
      normalizedExcludedPaths.allSatisfy(Self.validPath),
      Set(normalizedIncludedPaths).count == normalizedIncludedPaths.count,
      Set(normalizedExcludedPaths).count == normalizedExcludedPaths.count,
      Set(normalizedCapabilities).count == normalizedCapabilities.count,
      normalizedCapabilities.allSatisfy({ Self.validWireValue($0.wireValue) }),
      credentialUID?.isEmpty != true, credentialUID?.contains("\0") != true,
      (credentialMode == .synced) == (credentialUID != nil),
      revision >= 0, updatedAtMilliseconds >= 0,
      deletedAtMilliseconds.map({ $0 >= 0 }) ?? true,
      schemaVersion == 1
    else {
      throw SDKError(code: .invalidConfiguration, message: "media source config is invalid")
    }
    self.sourceUID = sourceUID
    self.accountUID = accountUID
    self.kind = kind
    self.displayName = normalizedDisplayName
    self.endpoint = endpoint
    self.rootPath = Self.normalizePath(rootPath)
    self.includedPaths = normalizedIncludedPaths.sorted()
    self.excludedPaths = normalizedExcludedPaths.sorted()
    self.scanPolicy = scanPolicy
    self.metadataPolicy = metadataPolicy
    self.connectionMode = connectionMode
    self.credentialMode = credentialMode
    self.credentialUID = credentialUID
    self.capabilities = normalizedCapabilities
    self.revision = revision
    self.updatedAtMilliseconds = updatedAtMilliseconds
    self.deletedAtMilliseconds = deletedAtMilliseconds
    self.schemaVersion = schemaVersion
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        sourceUID: container.decode(String.self, forKey: .sourceUID),
        accountUID: container.decode(String.self, forKey: .accountUID),
        kind: container.decode(MediaSourceKind.self, forKey: .kind),
        displayName: container.decode(String.self, forKey: .displayName),
        endpoint: container.decode(MediaSourceEndpoint.self, forKey: .endpoint),
        rootPath: container.decode(String.self, forKey: .rootPath),
        includedPaths: container.decodeIfPresent([String].self, forKey: .includedPaths) ?? [""],
        excludedPaths: container.decodeIfPresent([String].self, forKey: .excludedPaths) ?? [],
        scanPolicy: container.decode(MediaSourceScanPolicy.self, forKey: .scanPolicy),
        metadataPolicy: container.decode(MediaSourceMetadataPolicy.self, forKey: .metadataPolicy),
        connectionMode: container.decode(MediaSourceConnectionMode.self, forKey: .connectionMode),
        credentialMode: container.decode(MediaSourceCredentialMode.self, forKey: .credentialMode),
        credentialUID: container.decodeIfPresent(String.self, forKey: .credentialUID),
        capabilities: container.decodeIfPresent(
          [MediaSourceCapability].self,
          forKey: .capabilities
        ) ?? [],
        revision: container.decode(Int64.self, forKey: .revision),
        updatedAtMilliseconds: container.decode(Int64.self, forKey: .updatedAtMilliseconds),
        deletedAtMilliseconds: container.decodeIfPresent(
          Int64.self,
          forKey: .deletedAtMilliseconds
        ),
        schemaVersion: container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
      )
    } catch let error as SDKError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message)
      )
    }
  }

  /// A representation that hides endpoint, root, account, source, and future enum values.
  public var description: String { "<MediaSourceConfig redacted>" }

  /// A representation that hides endpoint, root, account, and source identity.
  public var debugDescription: String { description }

  private static func normalizePath(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "/")
  }

  private static func validPath(_ value: String) -> Bool {
    guard !value.contains("\0") else { return false }
    return !normalizePath(value).split(separator: "/", omittingEmptySubsequences: false)
      .contains("..")
  }

  private static func validWireValue(_ value: String) -> Bool {
    !value.isEmpty && !value.contains("\0") && value.utf8.count <= 64
  }

  private enum CodingKeys: String, CodingKey {
    case sourceUID = "source_uid"
    case accountUID = "account_uid"
    case kind
    case displayName = "display_name"
    case endpoint
    case rootPath = "root_path"
    case includedPaths = "included_paths"
    case excludedPaths = "excluded_paths"
    case scanPolicy = "scan_policy"
    case metadataPolicy = "metadata_policy"
    case connectionMode = "connection_mode"
    case credentialMode = "credential_mode"
    case credentialUID = "credential_uid"
    case capabilities
    case revision
    case updatedAtMilliseconds = "updated_at_ms"
    case deletedAtMilliseconds = "deleted_at_ms"
    case schemaVersion = "schema_version"
  }
}

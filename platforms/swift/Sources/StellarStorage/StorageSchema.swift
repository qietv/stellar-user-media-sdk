import Foundation

/// One versioned SQLite database managed by StellarStorage.
public enum StorageDatabaseKind: String, CaseIterable, Codable, Sendable {
  case account
  case library
  case metadataCache = "metadata_cache"

  /// SQLite application identifier that prevents opening the wrong database file.
  public var applicationID: Int32 {
    switch self {
    case .account: 0x4143_4354
    case .library: 0x4D4C_4942
    case .metadataCache: 0x4D43_4143
    }
  }

  /// Latest schema version supported by this SDK.
  public var currentVersion: Int {
    switch self {
    case .library: 2
    case .account, .metadataCache: 1
    }
  }

  /// Number of non-internal tables in the current schema contract.
  public var expectedBusinessTableCount: Int {
    switch self {
    case .account: 6
    case .library: 29
    case .metadataCache: 3
    }
  }

  /// Reviewed SHA-256 of the latest schema step for this database.
  public var schemaChecksum: String {
    canonicalSchemaChecksum(version: currentVersion) ?? ""
  }
}

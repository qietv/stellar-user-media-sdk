import Foundation
import GRDB
import StellarCore

/// The result of checking one opened Stellar SQLite database.
public struct StorageVerificationReport: Codable, Equatable, Sendable {
  public let kind: StorageDatabaseKind
  public let applicationID: Int32
  public let userVersion: Int
  public let journalMode: String
  public let foreignKeysEnabled: Bool
  public let businessTableCount: Int
  public let foreignKeyViolationCount: Int
  public let quickCheck: [String]
  public let migrationChecksum: String?

  /// Whether all identity, integrity, connection, and migration checks passed.
  public var isValid: Bool {
    applicationID == kind.applicationID && userVersion == kind.currentVersion
      && journalMode.lowercased() == "wal" && foreignKeysEnabled
      && businessTableCount == kind.expectedBusinessTableCount
      && foreignKeyViolationCount == 0 && quickCheck == ["ok"]
      && (kind == .metadataCache || migrationChecksum == kind.schemaChecksum)
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case applicationID = "application_id"
    case userVersion = "user_version"
    case journalMode = "journal_mode"
    case foreignKeysEnabled = "foreign_keys_enabled"
    case businessTableCount = "business_table_count"
    case foreignKeyViolationCount = "foreign_key_violation_count"
    case quickCheck = "quick_check"
    case migrationChecksum = "migration_checksum"
  }
}

/// An opened, migrated SQLite database with serialized business writes and pooled reads.
public actor StorageDatabase {
  public nonisolated let kind: StorageDatabaseKind
  public nonisolated let url: URL

  private let pool: DatabasePool
  private let clock: any SDKClock

  private init(
    kind: StorageDatabaseKind,
    url: URL,
    pool: DatabasePool,
    clock: any SDKClock
  ) {
    self.kind = kind
    self.url = url
    self.pool = pool
    self.clock = clock
  }

  /// Opens or creates a database and applies every supported migration.
  public static func open(
    kind: StorageDatabaseKind,
    at url: URL,
    clock: any SDKClock = SystemSDKClock()
  ) async throws -> StorageDatabase {
    guard url.isFileURL else {
      throw SDKError(code: .invalidConfiguration, message: "database URL must be a file URL")
    }

    let fileManager = FileManager.default
    let path = url.path
    let existed = fileManager.fileExists(atPath: path)
    do {
      if existed {
        try preflightExistingDatabase(kind: kind, path: path)
      } else {
        try fileManager.createDirectory(
          at: url.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
      }

      var configuration = Configuration()
      configuration.label = "StellarStorage.\(kind.rawValue)"
      configuration.foreignKeysEnabled = true
      configuration.busyMode = .timeout(5)
      configuration.maximumReaderCount = 5
      configuration.prepareDatabase { database in
        guard !database.configuration.readonly else { return }
        // Keep large scan batches from repeatedly checkpointing SQLite's small default WAL.
        // 4,096 pages is about 16 MiB with the default page size and remains bounded.
        try database.execute(sql: "PRAGMA wal_autocheckpoint = 4096")
      }
      let pool = try DatabasePool(path: path, configuration: configuration)
      let database = StorageDatabase(kind: kind, url: url, pool: pool, clock: clock)
      try await database.migrateIfNeeded()
      return database
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "database open or migration failed")
    }
  }

  /// Verifies an existing database without migrating or otherwise writing it.
  public static func verifyExisting(
    kind: StorageDatabaseKind,
    at url: URL
  ) async throws -> StorageVerificationReport {
    guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
      throw SDKError(code: .invalidConfiguration, message: "database file does not exist")
    }
    do {
      try preflightExistingDatabase(kind: kind, path: url.path)
      var configuration = Configuration()
      configuration.readonly = true
      configuration.foreignKeysEnabled = true
      configuration.busyMode = .timeout(5)
      let queue = try DatabaseQueue(path: url.path, configuration: configuration)
      return try await queue.read { database in
        try makeVerificationReport(kind: kind, database: database)
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "database verification failed")
    }
  }

  /// Runs identity, connection, foreign-key, and SQLite integrity checks.
  public func verify() async throws -> StorageVerificationReport {
    do {
      return try await pool.read { [kind] database in
        try Self.makeVerificationReport(kind: kind, database: database)
      }
    } catch {
      throw SDKError(code: .storageFailure, message: "database verification failed")
    }
  }

  package func read<Value: Sendable>(
    _ body: @Sendable (Database) throws -> Value
  ) async throws -> Value {
    try await pool.read(body)
  }

  package func write<Value: Sendable>(
    _ body: @Sendable (Database) throws -> Value
  ) async throws -> Value {
    try await pool.write { [kind] database in
      let value = try body(database)
      if kind == .library {
        try database.execute(
          sql: "UPDATE library_revision SET revision = revision + 1 WHERE id = 1"
        )
      }
      return value
    }
  }

  private func migrateIfNeeded() async throws {
    let existingVersion = try await pool.read { database in
      try Int.fetchOne(database, sql: "PRAGMA user_version") ?? 0
    }
    guard existingVersion <= kind.currentVersion else {
      throw SDKError(code: .storageFailure, message: "database schema is newer than this SDK")
    }

    if existingVersion > 0, kind != .metadataCache {
      try await pool.read { [kind] database in
        for version in 1...existingVersion {
          let checksum = try String.fetchOne(
            database,
            sql: "SELECT checksum FROM schema_migration WHERE version = ?",
            arguments: [version]
          )
          guard checksum == kind.canonicalSchemaChecksum(version: version) else {
            throw SDKError(code: .storageFailure, message: "database migration checksum mismatch")
          }
        }
      }
    }
    if existingVersion == kind.currentVersion {
      return
    }

    let appliedAt = clock.nowMilliseconds()
    try await pool.write { [kind] database in
      var version = existingVersion
      if version == 0 {
        try database.execute(sql: kind.schemaSQL)
        version = 1
        if kind != .metadataCache {
          guard let checksum = kind.canonicalSchemaChecksum(version: version) else {
            throw SDKError(code: .storageFailure, message: "base schema checksum is missing")
          }
          try database.execute(
            sql: "INSERT INTO schema_migration(version, applied_at_ms, checksum) VALUES (?, ?, ?)",
            arguments: [version, appliedAt, checksum]
          )
        }
      }
      while version < kind.currentVersion {
        guard let sql = kind.migrationSQL(fromVersion: version),
          let checksum = kind.canonicalSchemaChecksum(version: version + 1)
        else {
          throw SDKError(code: .storageFailure, message: "database migration path is unavailable")
        }
        try database.execute(sql: sql)
        version += 1
        try database.execute(
          sql: "INSERT INTO schema_migration(version, applied_at_ms, checksum) VALUES (?, ?, ?)",
          arguments: [version, appliedAt, checksum]
        )
      }
    }
  }

  private static func preflightExistingDatabase(
    kind: StorageDatabaseKind,
    path: String
  ) throws {
    var configuration = Configuration()
    configuration.readonly = true
    configuration.foreignKeysEnabled = true
    configuration.busyMode = .timeout(5)
    let queue = try DatabaseQueue(path: path, configuration: configuration)
    try queue.read { database in
      let applicationID = Int32(try Int.fetchOne(database, sql: "PRAGMA application_id") ?? 0)
      let userVersion = try Int.fetchOne(database, sql: "PRAGMA user_version") ?? 0
      let tableCount =
        try Int.fetchOne(
          database,
          sql: """
            SELECT COUNT(*)
            FROM sqlite_schema
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
            """
        ) ?? 0
      guard applicationID == 0 || applicationID == kind.applicationID else {
        throw SDKError(code: .storageFailure, message: "database application identity mismatch")
      }
      guard userVersion <= kind.currentVersion else {
        throw SDKError(code: .storageFailure, message: "database schema is newer than this SDK")
      }
      guard applicationID != 0 || (userVersion == 0 && tableCount == 0) else {
        throw SDKError(code: .storageFailure, message: "unidentified non-empty database is unsafe")
      }
    }
  }

  private static func makeVerificationReport(
    kind: StorageDatabaseKind,
    database: Database
  ) throws -> StorageVerificationReport {
    let applicationID = Int32(try Int.fetchOne(database, sql: "PRAGMA application_id") ?? 0)
    let userVersion = try Int.fetchOne(database, sql: "PRAGMA user_version") ?? 0
    let journalMode = try String.fetchOne(database, sql: "PRAGMA journal_mode") ?? ""
    let foreignKeysEnabled = (try Int.fetchOne(database, sql: "PRAGMA foreign_keys") ?? 0) == 1
    let businessTableCount =
      try Int.fetchOne(
        database,
        sql: """
          SELECT COUNT(*)
          FROM sqlite_schema
          WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
          """
      ) ?? 0
    let foreignKeyViolationCount =
      try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM pragma_foreign_key_check"
      ) ?? 0
    let quickCheck = try String.fetchAll(database, sql: "PRAGMA quick_check")
    let migrationChecksum: String?
    if kind == .metadataCache {
      migrationChecksum = nil
    } else {
      migrationChecksum = try String.fetchOne(
        database,
        sql: "SELECT checksum FROM schema_migration WHERE version = ?",
        arguments: [kind.currentVersion]
      )
    }
    return StorageVerificationReport(
      kind: kind,
      applicationID: applicationID,
      userVersion: userVersion,
      journalMode: journalMode,
      foreignKeysEnabled: foreignKeysEnabled,
      businessTableCount: businessTableCount,
      foreignKeyViolationCount: foreignKeyViolationCount,
      quickCheck: quickCheck,
      migrationChecksum: migrationChecksum
    )
  }
}

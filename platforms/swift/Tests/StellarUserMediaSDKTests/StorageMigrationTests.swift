import Foundation
import GRDB
import StellarCore
import StellarStorage
import Testing

@Suite("SQLite storage and migrations", .serialized)
struct StorageMigrationTests {
  @Test("All databases migrate to their current schema, verify, and reopen")
  func migrateVerifyAndReopen() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    for kind in StorageDatabaseKind.allCases {
      let url = directory.appendingPathComponent("\(kind.rawValue).sqlite")
      let database = try await StorageDatabase.open(
        kind: kind,
        at: url,
        clock: StorageFixedClock(now: 1_700_000_000_123)
      )
      let report = try await database.verify()

      #expect(report.kind == kind)
      #expect(report.applicationID == kind.applicationID)
      #expect(report.userVersion == kind.currentVersion)
      #expect(report.journalMode == "wal")
      #expect(report.foreignKeysEnabled)
      #expect(report.businessTableCount == expectedTableCount(kind))
      #expect(report.foreignKeyViolationCount == 0)
      #expect(report.quickCheck == ["ok"])
      #expect(report.isValid)

      let reopened = try await StorageDatabase.open(kind: kind, at: url)
      #expect(try await reopened.verify() == report)
      #expect(try await StorageDatabase.verifyExisting(kind: kind, at: url) == report)
    }
  }

  @Test("An existing zero-byte database file is initialized as an empty database")
  func zeroByteDatabase() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("library.sqlite")
    try Data().write(to: url)

    let database = try await StorageDatabase.open(kind: .library, at: url)

    #expect(try await database.verify().isValid)
  }

  @Test("An existing library v1 database migrates in place to v7")
  func existingLibraryV1MigratesInPlace() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("library.sqlite")
    let schemaURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("specs/storage/sql/library-v1.sql")
    let v1SQL = try String(contentsOf: schemaURL, encoding: .utf8)
    let queue = try DatabaseQueue(path: url.path)
    try await queue.write { database in
      try database.execute(sql: v1SQL)
      try database.execute(
        sql: "INSERT INTO schema_migration(version, applied_at_ms, checksum) VALUES (1, 1, ?)",
        arguments: ["860af5576de63d4aa64342204e27ff8a054df188fba0840f07545647bb5a1484"]
      )
      try database.execute(
        sql:
          "INSERT INTO library_source(uid, kind, display_name, root_uri, created_at_ms, updated_at_ms) VALUES ('preserved', 'smb', 'Preserved', 'smb://preserved', 1, 1)"
      )
    }

    let migrated = try await StorageDatabase.open(kind: .library, at: url)
    let report = try await migrated.verify()
    #expect(report.userVersion == 7)
    #expect(report.businessTableCount == 31)
    #expect(report.isValid)
    let preserved = try await migrated.read { database in
      try String.fetchOne(
        database, sql: "SELECT display_name FROM library_source WHERE uid = 'preserved'")
    }
    #expect(preserved == "Preserved")
    let claimIndexSQL = try await migrated.read { database in
      try String.fetchOne(
        database,
        sql: "SELECT sql FROM sqlite_schema WHERE type = 'index' AND name = ?",
        arguments: ["idx_scan_queue_claim_order"]
      )
    }
    #expect(claimIndexSQL?.contains("'failed'") == false)
  }

  @Test("An existing library v2 database preserves data and normalizes overlapping active runs")
  func existingLibraryV2MigratesInPlace() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("library.sqlite")
    let schemaRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("specs/storage/sql")
    let v1SQL = try String(
      contentsOf: schemaRoot.appendingPathComponent("library-v1.sql"),
      encoding: .utf8
    )
    let v2SQL = try String(
      contentsOf: schemaRoot.appendingPathComponent("library-v2.sql"),
      encoding: .utf8
    )
    let queue = try DatabaseQueue(path: url.path)
    try await queue.write { database in
      try database.execute(sql: v1SQL)
      try database.execute(
        sql: "INSERT INTO schema_migration(version, applied_at_ms, checksum) VALUES (1, 1, ?)",
        arguments: ["860af5576de63d4aa64342204e27ff8a054df188fba0840f07545647bb5a1484"]
      )
      try database.execute(sql: v2SQL)
      try database.execute(
        sql: "INSERT INTO schema_migration(version, applied_at_ms, checksum) VALUES (2, 2, ?)",
        arguments: ["8a9f0dac4e9af7c69d2c8a855335e10e9c44adf286eb0339c38beb7afc5688d9"]
      )
      try database.execute(
        sql:
          "INSERT INTO library_source(uid, kind, display_name, root_uri, created_at_ms, updated_at_ms) VALUES ('v2-source', 'smb', 'V2', 'smb://v2', 1, 1)"
      )
      try database.execute(
        sql: """
          INSERT INTO scan_run(
            uid, source_id, mode, state, checkpoint_json, coverage_json, started_at_ms
          )
          SELECT ?, id, 'full', ?, '{}', '{}', ?
          FROM library_source WHERE uid = 'v2-source'
          """,
        arguments: ["older-active", "enumerating", 10]
      )
      try database.execute(
        sql: """
          INSERT INTO scan_run(
            uid, source_id, mode, state, checkpoint_json, coverage_json, started_at_ms
          )
          SELECT ?, id, 'full', ?, '{}', '{}', ?
          FROM library_source WHERE uid = 'v2-source'
          """,
        arguments: ["newer-active", "queued", 20]
      )
    }

    let migrated = try await StorageDatabase.open(kind: .library, at: url)
    let report = try await migrated.verify()
    #expect(report.userVersion == 7)
    #expect(report.businessTableCount == 31)
    #expect(report.isValid)
    let states = try await migrated.read { database in
      try Row.fetchAll(
        database,
        sql: "SELECT uid, state FROM scan_run ORDER BY id"
      ).map { row in (row["uid"] as String, row["state"] as String) }
    }
    #expect(states.map(\.0) == ["older-active", "newer-active"])
    #expect(states.map(\.1) == ["cancelled", "queued"])
  }

  @Test("An existing library v3 queue becomes revisioned and reclaimable")
  func existingLibraryV3QueueMigratesInPlace() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("library.sqlite")
    let schemaRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("specs/storage/sql")
    let queue = try DatabaseQueue(path: url.path)
    try await queue.write { database in
      for name in ["library-v1.sql", "library-v2.sql", "library-v3.sql"] {
        try database.execute(
          sql: try String(
            contentsOf: schemaRoot.appendingPathComponent(name),
            encoding: .utf8
          )
        )
      }
      for (version, checksum) in [
        (1, "860af5576de63d4aa64342204e27ff8a054df188fba0840f07545647bb5a1484"),
        (2, "8a9f0dac4e9af7c69d2c8a855335e10e9c44adf286eb0339c38beb7afc5688d9"),
        (3, "b0707478dc02df733d69adb1a1d7fab0d359cc7f3cad010b34040b628e80cd69"),
      ] {
        try database.execute(
          sql: "INSERT INTO schema_migration(version, applied_at_ms, checksum) VALUES (?, ?, ?)",
          arguments: [version, version, checksum]
        )
      }
      try database.execute(
        sql: """
          INSERT INTO library_source(
            uid, kind, display_name, root_uri, created_at_ms, updated_at_ms
          ) VALUES ('v3-source', 'smb', 'V3', 'smb://v3', 1, 1)
          """
      )
      try database.execute(
        sql: """
          INSERT INTO scan_run(
            uid, source_id, mode, state, checkpoint_json, coverage_json, started_at_ms,
            finished_at_ms
          )
          SELECT 'v3-run', id, 'full', 'completed', '{}', '{}', 1, 2
          FROM library_source WHERE uid = 'v3-source'
          """
      )
      try database.execute(
        sql: """
          INSERT INTO media_file(
            uid, source_id, stable_key, relative_path, path_compare_key, display_name,
            availability, updated_at_ms
          )
          SELECT 'v3-file', id, 'persistent:v3-file', 'Movie.mkv', 'Movie.mkv',
                 'Movie.mkv', 'present', 2
          FROM library_source WHERE uid = 'v3-source'
          """
      )
      try database.execute(
        sql: """
          INSERT INTO scan_queue(
            run_id, media_file_id, stage, state, lease_until_ms, updated_at_ms
          )
          SELECT run.id, file.id, 'parse', 'running', 999999, 3
          FROM scan_run run, media_file file
          WHERE run.uid = 'v3-run' AND file.uid = 'v3-file'
          """
      )
    }

    let migrated = try await StorageDatabase.open(kind: .library, at: url)
    #expect(try await migrated.verify().isValid)
    let store = try LibraryStore(
      database: migrated,
      clock: StorageFixedClock(now: 10_000)
    )
    let leases = try await store.claimScanFileWork(
      sourceUID: "v3-source",
      stage: .parse,
      workerID: "migration-worker",
      leaseDurationMilliseconds: 1_000
    )
    #expect(leases.count == 1)
    #expect(leases.first?.inputRevision == 1)
  }

  @Test("Database application IDs prevent cross-domain migration")
  func rejectsWrongDatabaseKindWithoutReplacingFile() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("library.sqlite")
    let library = try await StorageDatabase.open(kind: .library, at: url)
    let originalReport = try await library.verify()

    await #expect(throws: SDKError.self) {
      _ = try await StorageDatabase.open(kind: .account, at: url)
    }
    #expect(throws: SDKError.self) {
      _ = try LibrarySourceDefinition(
        uid: "unsafe-source",
        kind: .smb,
        displayName: "Unsafe",
        rootURI: "smb://user:secret@example.test/Media?token=secret"
      )
    }

    let reopened = try await StorageDatabase.open(kind: .library, at: url)
    #expect(try await reopened.verify() == originalReport)
  }

  @Test("A migration checksum mismatch fails without replacing the database")
  func checksumMismatchPreservesDatabase() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("library.sqlite")
    _ = try await StorageDatabase.open(kind: .library, at: url)
    let queue = try DatabaseQueue(path: url.path)
    try await queue.write { database in
      try database.execute(
        sql: "UPDATE schema_migration SET checksum = 'corrupt' WHERE version = 1"
      )
    }
    let sizeBefore = try #require(
      try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    )

    await #expect(throws: SDKError.self) {
      _ = try await StorageDatabase.open(kind: .library, at: url)
    }

    let checksum = try await queue.read { database in
      try String.fetchOne(
        database,
        sql: "SELECT checksum FROM schema_migration WHERE version = 1"
      )
    }
    let tableCount = try await queue.read { database in
      try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
      )
    }
    #expect(checksum == "corrupt")
    #expect(tableCount == 31)
    #expect(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == sizeBefore)
  }

  @Test("A corrupt SQLite file fails closed without being overwritten")
  func corruptDatabaseIsPreserved() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("library.sqlite")
    let corruptBytes = Data("not-a-sqlite-database".utf8)
    try corruptBytes.write(to: url)

    await #expect(throws: SDKError.self) {
      _ = try await StorageDatabase.open(kind: .library, at: url)
    }

    #expect(try Data(contentsOf: url) == corruptBytes)
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "stellar-storage-tests-\(UUID().uuidString)",
      isDirectory: true
    )
  }

  private func expectedTableCount(_ kind: StorageDatabaseKind) -> Int {
    switch kind {
    case .account: 6
    case .library: 31
    case .metadataCache: 3
    }
  }
}

private struct StorageFixedClock: SDKClock {
  let now: Int64

  func nowMilliseconds() -> Int64 { now }

  func sleep(forMilliseconds _: Int64) async throws {}
}

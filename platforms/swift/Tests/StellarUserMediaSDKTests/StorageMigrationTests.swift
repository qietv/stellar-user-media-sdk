import Foundation
import GRDB
import StellarCore
import StellarStorage
import Testing

@Suite("SQLite storage and migrations", .serialized)
struct StorageMigrationTests {
  @Test("All v1 databases migrate, verify, and reopen")
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
      #expect(report.userVersion == 1)
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
    #expect(tableCount == 27)
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
    case .library: 27
    case .metadataCache: 3
    }
  }
}

private struct StorageFixedClock: SDKClock {
  let now: Int64

  func nowMilliseconds() -> Int64 { now }

  func sleep(forMilliseconds _: Int64) async throws {}
}

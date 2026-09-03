import Foundation
import GRDB
import StellarCore
import StellarPosterWall
import StellarRemoteMedia
import StellarStorage
import Testing

@Suite("Library missing lifecycle and garbage collection", .serialized)
struct LibraryMissingLifecycleTests {
  @Test("An anomalous empty snapshot needs repeated authoritative confirmation")
  func emptySnapshotGuard() async throws {
    let fixture = try await makeLifecycleFixture(sourceUID: "guard-source")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let entry = try lifecycleEntry(sourceUID: fixture.sourceUID)

    try await commitLifecycleSnapshot(
      fixture, at: 100, runUID: "guard-initial", entries: [entry]
    )
    try await commitLifecycleSnapshot(
      fixture, at: 200, runUID: "guard-empty-1", entries: []
    )

    let firstResult = try await fixture.database.read { database in
      let file = try Row.fetchOne(
        database,
        sql: "SELECT availability, missing_scan_count FROM media_file LIMIT 1"
      )
      let run = try Row.fetchOne(
        database,
        sql: "SELECT reconcile_missing, error_code FROM scan_run WHERE uid = 'guard-empty-1'"
      )
      return (
        file?["availability"] as String?, file?["missing_scan_count"] as Int?,
        run?["reconcile_missing"] as Int?, run?["error_code"] as String?
      )
    }
    #expect(firstResult.0 == "present")
    #expect(firstResult.1 == 0)
    #expect(firstResult.2 == 0)
    #expect(firstResult.3 == "unsafe_missing_reconciliation")

    try await commitLifecycleSnapshot(
      fixture, at: 300, runUID: "guard-empty-2", entries: []
    )
    let repeatedResult = try await fixture.database.read { database in
      let file = try Row.fetchOne(
        database,
        sql: "SELECT availability, missing_scan_count FROM media_file LIMIT 1"
      )
      let run = try Row.fetchOne(
        database,
        sql: "SELECT reconcile_missing, error_code FROM scan_run WHERE uid = 'guard-empty-2'"
      )
      return (
        file?["availability"] as String?, file?["missing_scan_count"] as Int?,
        run?["reconcile_missing"] as Int?, run?["error_code"] as String?
      )
    }
    #expect(repeatedResult.0 == "missing")
    #expect(repeatedResult.1 == 1)
    #expect(repeatedResult.2 == 1)
    #expect(repeatedResult.3 == nil)
  }

  @Test("A repeated suspicious count must also contain the same file identities")
  func suspiciousDropIdentityGuard() async throws {
    let fixture = try await makeLifecycleFixture(sourceUID: "identity-guard-source")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let entries = try [
      lifecycleEntry(sourceUID: fixture.sourceUID, name: "A.mkv", stableID: "file-a"),
      lifecycleEntry(sourceUID: fixture.sourceUID, name: "B.mkv", stableID: "file-b"),
      lifecycleEntry(sourceUID: fixture.sourceUID, name: "C.mkv", stableID: "file-c"),
    ]
    let policy = try LibraryMissingRetentionPolicy(
      gracePeriodMilliseconds: 100,
      requiredMissingScanCount: 2,
      protectsEmptyResult: true,
      suspiciousDropPercentage: 50,
      suspiciousDropMinimumCount: 1
    )
    try await fixture.store(at: 50).setMissingRetentionPolicy(
      policy, forSourceUID: fixture.sourceUID
    )
    try await commitLifecycleSnapshot(
      fixture, at: 100, runUID: "identity-initial", entries: entries
    )
    try await commitLifecycleSnapshot(
      fixture, at: 200, runUID: "identity-drop-a", entries: [entries[0]]
    )
    try await commitLifecycleSnapshot(
      fixture, at: 300, runUID: "identity-drop-b-1", entries: [entries[1]]
    )

    let changedIdentityResult = try await fixture.database.read { database in
      let reconcile = try Int.fetchOne(
        database,
        sql: "SELECT reconcile_missing FROM scan_run WHERE uid = 'identity-drop-b-1'"
      )
      let present = try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM media_file WHERE availability = 'present'"
      )
      return (reconcile, present)
    }
    #expect(changedIdentityResult.0 == 0)
    #expect(changedIdentityResult.1 == 3)

    try await commitLifecycleSnapshot(
      fixture, at: 400, runUID: "identity-drop-b-2", entries: [entries[1]]
    )
    let repeatedIdentityResult = try await fixture.database.read { database in
      let reconcile = try Int.fetchOne(
        database,
        sql: "SELECT reconcile_missing FROM scan_run WHERE uid = 'identity-drop-b-2'"
      )
      let states = try Row.fetchAll(
        database,
        sql: "SELECT stable_id, availability FROM media_file ORDER BY stable_id"
      ).map { row in (row["stable_id"] as String, row["availability"] as String) }
      return (reconcile, states.map(\.0), states.map(\.1))
    }
    #expect(repeatedIdentityResult.0 == 1)
    #expect(repeatedIdentityResult.1 == ["file-a", "file-b", "file-c"])
    #expect(repeatedIdentityResult.2 == ["missing", "present", "missing"])
  }

  @Test("Network scan failures set only source-level offline state")
  func failedScanOfflineOverlay() async throws {
    let fixture = try await makeLifecycleFixture(sourceUID: "failed-scan-source")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let entry = try lifecycleEntry(sourceUID: fixture.sourceUID)
    try await commitLifecycleSnapshot(
      fixture, at: 100, runUID: "failed-scan-initial", entries: [entry]
    )
    try await fixture.store(at: 200).commit(
      LibraryScanPersistenceBatch(
        runUID: "failed-scan-network-error",
        sourceUID: fixture.sourceUID,
        mode: "full",
        state: "failed",
        checkpointJSON: #"{"phase":"failed"}"#,
        coverageJSON: #"{"roots":[""]}"#,
        entries: [],
        capabilities: nil,
        discoveredEntryCount: 0,
        errorCode: SDKErrorCode.networkUnavailable.rawValue
      )
    )
    let failedState = try await fixture.database.read { database in
      let source = try Row.fetchOne(
        database,
        sql: "SELECT offline_since_ms, last_error_code FROM library_source LIMIT 1"
      )
      let file = try Row.fetchOne(
        database,
        sql: "SELECT availability, missing_scan_count FROM media_file LIMIT 1"
      )
      return (
        source?["offline_since_ms"] as Int64?, source?["last_error_code"] as String?,
        file?["availability"] as String?, file?["missing_scan_count"] as Int?
      )
    }
    #expect(failedState.0 == 200)
    #expect(failedState.1 == SDKErrorCode.networkUnavailable.rawValue)
    #expect(failedState.2 == "present")
    #expect(failedState.3 == 0)

    try await commitLifecycleSnapshot(
      fixture, at: 300, runUID: "failed-scan-recovered", entries: [entry]
    )
    let recoveredSource = try await fixture.database.read { database in
      let row = try Row.fetchOne(
        database,
        sql: "SELECT offline_since_ms, last_error_code FROM library_source LIMIT 1"
      )
      return (row?["offline_since_ms"] as Int64?, row?["last_error_code"] as String?)
    }
    #expect(recoveredSource.0 == nil)
    #expect(recoveredSource.1 == nil)
  }

  @Test("Offline sources suspend cleanup and file tombstones can be revived")
  func offlineSuspensionAndRevival() async throws {
    let fixture = try await makeLifecycleFixture(sourceUID: "revival-source")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let entry = try lifecycleEntry(sourceUID: fixture.sourceUID)
    let policy = try LibraryMissingRetentionPolicy(
      gracePeriodMilliseconds: 100,
      requiredMissingScanCount: 2,
      protectsEmptyResult: false,
      suspiciousDropPercentage: 0,
      suspiciousDropMinimumCount: 1
    )
    try await fixture.store(at: 50).setMissingRetentionPolicy(
      policy, forSourceUID: fixture.sourceUID
    )
    try await commitLifecycleSnapshot(
      fixture, at: 100, runUID: "revival-initial", entries: [entry]
    )

    let identities = try await fixture.database.write { database -> (String, Int64) in
      guard
        let file = try Row.fetchOne(
          database,
          sql: "SELECT id, uid FROM media_file WHERE stable_key = 'persistent:lifecycle-file'"
        )
      else {
        throw SDKError(code: .storageFailure, message: "lifecycle file fixture is missing")
      }
      let fileID: Int64 = file["id"]
      let fileUID: String = file["uid"]
      try database.execute(
        sql: """
          INSERT INTO media_entity(
            uid, kind, canonical_title, status, metadata_state, created_at_ms, updated_at_ms
          ) VALUES ('revival-entity', 'movie', 'Revival', 'active', 'complete', 100, 100)
          """
      )
      let entityID = database.lastInsertedRowID
      try database.execute(
        sql: """
          INSERT INTO file_binding(
            media_file_id, entity_id, binding_role, match_method, confidence,
            matched_query, locked, decided_at_ms
          ) VALUES (?, ?, 'primary', 'provider_search', 1, '{}', 0, 100)
          """,
        arguments: [fileID, entityID]
      )
      try database.execute(
        sql: """
          INSERT INTO playback_profile(uid, display_name, is_default, created_at_ms, updated_at_ms)
          VALUES ('revival-profile', 'Revival', 1, 100, 100)
          """
      )
      let profileID = database.lastInsertedRowID
      try database.execute(
        sql: """
          INSERT INTO playback_state(
            profile_id, entity_id, media_file_id, position_ms, duration_ms,
            completed, play_count, updated_at_ms, revision
          ) VALUES (?, ?, ?, 42000, 90000, 0, 1, 100, 1)
          """,
        arguments: [profileID, entityID, fileID]
      )
      return (fileUID, entityID)
    }

    try await fixture.store(at: 150).markSourceOffline(sourceUID: fixture.sourceUID)
    let offlinePage = try await PosterWallStore(database: fixture.database).page(
      PosterWallQuery()
    )
    #expect(offlinePage.items.first?.availability == .offline)
    try await fixture.store(at: 160).markSourceOnline(sourceUID: fixture.sourceUID)
    try await commitLifecycleSnapshot(
      fixture, at: 200, runUID: "revival-missing-1", entries: []
    )
    try await fixture.store(at: 250).markSourceOffline(sourceUID: fixture.sourceUID)
    let gcPolicy = try LibraryGarbageCollectionPolicy(
      metadataOrphanGracePeriodMilliseconds: 100,
      deletionMarkGracePeriodMilliseconds: 100,
      fileTombstoneRetentionMilliseconds: 1_000,
      batchSize: 20
    )
    let suspended = try await fixture.store(at: 1_000).runGarbageCollection(policy: gcPolicy)
    #expect(suspended.softDeletedFileCount == 0)
    #expect(
      try await fixture.database.read { database in
        try String.fetchOne(database, sql: "SELECT availability FROM media_file LIMIT 1")
      } == "missing"
    )

    try await fixture.store(at: 1_000).markSourceOnline(sourceUID: fixture.sourceUID)
    try await commitLifecycleSnapshot(
      fixture, at: 1_100, runUID: "revival-missing-2", entries: []
    )
    let retired = try await fixture.store(at: 1_100).runGarbageCollection(policy: gcPolicy)
    #expect(retired.softDeletedFileCount == 1)
    #expect(retired.newlyOrphanedEntityCount == 1)

    let tombstone = try await fixture.database.read { database in
      let file = try Row.fetchOne(
        database,
        sql: "SELECT uid, availability, deleted_at_ms FROM media_file LIMIT 1"
      )
      let playback = try Row.fetchOne(
        database,
        sql: "SELECT media_file_id, position_ms FROM playback_state LIMIT 1"
      )
      return (
        file?["uid"] as String?, file?["availability"] as String?,
        file?["deleted_at_ms"] as Int64?, playback?["media_file_id"] as Int64?,
        playback?["position_ms"] as Int64?
      )
    }
    #expect(tombstone.0 == identities.0)
    #expect(tombstone.1 == "deleted")
    #expect(tombstone.2 == 1_100)
    #expect(tombstone.3 == nil)
    #expect(tombstone.4 == 42_000)

    try await commitLifecycleSnapshot(
      fixture, at: 1_150, runUID: "revival-returned", entries: [entry]
    )
    let revived = try await fixture.database.read { database in
      let file = try Row.fetchOne(
        database,
        sql: "SELECT uid, availability, deleted_at_ms FROM media_file LIMIT 1"
      )
      let entity = try Row.fetchOne(
        database,
        sql: "SELECT orphaned_at_ms, gc_marked_at_ms FROM media_entity WHERE id = ?",
        arguments: [identities.1]
      )
      let position = try Int64.fetchOne(
        database, sql: "SELECT position_ms FROM playback_state LIMIT 1"
      )
      return (
        file?["uid"] as String?, file?["availability"] as String?,
        file?["deleted_at_ms"] as Int64?, entity?["orphaned_at_ms"] as Int64?,
        entity?["gc_marked_at_ms"] as Int64?, position
      )
    }
    #expect(revived.0 == identities.0)
    #expect(revived.1 == "present")
    #expect(revived.2 == nil)
    #expect(revived.3 == nil)
    #expect(revived.4 == nil)
    #expect(revived.5 == 42_000)
  }

  @Test("Metadata deletion is two-phase and user-owned state is retained")
  func twoPhaseMetadataCollection() async throws {
    let fixture = try await makeLifecycleFixture(sourceUID: "metadata-gc-source")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try await fixture.database.write { database in
      try database.execute(
        sql: """
          INSERT INTO media_entity(
            uid, kind, canonical_title, status, metadata_state, created_at_ms, updated_at_ms
          ) VALUES
            ('gc-delete', 'movie', 'Delete', 'active', 'complete', 1, 1),
            ('gc-playback', 'movie', 'Playback', 'active', 'complete', 1, 1),
            ('gc-manual', 'movie', 'Manual', 'active', 'manual', 1, 1)
          """
      )
      try database.execute(
        sql: """
          INSERT INTO playback_profile(uid, display_name, is_default, created_at_ms, updated_at_ms)
          VALUES ('gc-profile', 'GC', 1, 1, 1)
          """
      )
      try database.execute(
        sql: """
          INSERT INTO playback_state(
            profile_id, entity_id, position_ms, completed, play_count, updated_at_ms, revision
          )
          SELECT profile.id, entity.id, 12000, 0, 1, 1, 1
          FROM playback_profile profile, media_entity entity
          WHERE profile.uid = 'gc-profile' AND entity.uid = 'gc-playback'
          """
      )
    }
    let policy = try LibraryGarbageCollectionPolicy(
      metadataOrphanGracePeriodMilliseconds: 100,
      deletionMarkGracePeriodMilliseconds: 100,
      fileTombstoneRetentionMilliseconds: 100,
      batchSize: 20
    )

    let first = try await fixture.store(at: 100).runGarbageCollection(policy: policy)
    #expect(first.newlyOrphanedEntityCount == 3)
    #expect(first.markedEntityCount == 0)
    #expect(first.purgedEntityCount == 0)

    let second = try await fixture.store(at: 200).runGarbageCollection(policy: policy)
    #expect(second.markedEntityCount == 3)
    #expect(second.purgedEntityCount == 0)

    let third = try await fixture.store(at: 300).runGarbageCollection(policy: policy)
    #expect(third.purgedEntityCount == 1)
    let retainedUIDs = try await fixture.database.read { database in
      try String.fetchAll(database, sql: "SELECT uid FROM media_entity ORDER BY uid")
    }
    #expect(retainedUIDs == ["gc-manual", "gc-playback"])
  }
}

private struct LifecycleFixture {
  let directory: URL
  let database: StorageDatabase
  let sourceUID: String
  let root: RemoteLocator
  let capabilities: MediaSourceCapabilities

  func store(at now: Int64) throws -> LibraryStore {
    try LibraryStore(database: database, clock: LifecycleFixedClock(now: now))
  }
}

private func makeLifecycleFixture(sourceUID: String) async throws -> LifecycleFixture {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "stellar-missing-lifecycle-\(UUID().uuidString)", isDirectory: true
  )
  let database = try await StorageDatabase.open(
    kind: .library, at: directory.appendingPathComponent("library.sqlite")
  )
  let capabilities = try MediaSourceCapabilities(
    stableIDScope: .persistent,
    pathSemantics: RemotePathSemantics(
      caseSensitivity: .sensitive,
      unicodeNormalization: .preserve
    ),
    supportsRangeReads: true,
    supportsChangeCursor: false,
    deltaDeletionsComplete: false
  )
  let root = try RemoteLocator(sourceUID: sourceUID, path: RemotePath())
  let fixture = LifecycleFixture(
    directory: directory,
    database: database,
    sourceUID: sourceUID,
    root: root,
    capabilities: capabilities
  )
  try await fixture.store(at: 1).registerSource(
    LibrarySourceDefinition(
      uid: sourceUID,
      kind: .smb,
      displayName: "Lifecycle Fixture",
      rootURI: "smb://lifecycle-fixture"
    )
  )
  return fixture
}

private func lifecycleEntry(
  sourceUID: String,
  name: String = "Lifecycle.mkv",
  stableID: String = "lifecycle-file"
) throws -> RemoteEntry {
  try RemoteEntry(
    locator: RemoteLocator(sourceUID: sourceUID, path: RemotePath("Movies/\(name)")),
    kind: .file,
    stableID: stableID,
    size: 1024
  )
}

private func commitLifecycleSnapshot(
  _ fixture: LifecycleFixture,
  at now: Int64,
  runUID: String,
  entries: [RemoteEntry]
) async throws {
  try await fixture.store(at: now).commit(
    LibraryScanPersistenceBatch(
      runUID: runUID,
      sourceUID: fixture.sourceUID,
      mode: "full",
      state: "completed",
      checkpointJSON: #"{"phase":"completed"}"#,
      coverageJSON: #"{"roots":[""]}"#,
      entries: entries,
      capabilities: fixture.capabilities,
      coveredRoots: [fixture.root],
      reconcileMissingEligible: true,
      discoveredEntryCount: Int64(entries.count)
    )
  )
}

private struct LifecycleFixedClock: SDKClock {
  let now: Int64

  func nowMilliseconds() -> Int64 { now }

  func sleep(forMilliseconds _: Int64) async throws {}
}

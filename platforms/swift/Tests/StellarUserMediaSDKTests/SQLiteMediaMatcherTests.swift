import Foundation
import GRDB
import StellarCore
import StellarMediaLibrary
import StellarRemoteMedia
import StellarStorage
import Testing

@Suite("SQLite metadata match persistence", .serialized)
struct SQLiteMediaMatcherTests {
  @Test("Review candidates persist, confirmation locks, and automatic repair preserves the lock")
  func reviewAndManualLock() async throws {
    let contract = try loadFixture()
    let fixture = try await makeFixture(contract)
    defer { fixture.remove() }
    #expect(contract.schemaVersion == 1)
    let testCase = contract.reviewLockCase
    let query = testCase.query
    let reviewCandidate = testCase.reviewCandidate

    let review = try await fixture.matcher.evaluate(
      query: query,
      candidates: [reviewCandidate],
      sourceUID: fixture.sourceUID,
      mediaRelativePath: fixture.reviewPath
    )
    #expect(review.state == testCase.reviewState)
    #expect(review.binding == nil)
    #expect(review.candidates.first?.score == testCase.reviewScore)
    #expect(
      try await fixture.matcher.pendingCandidates(
        sourceUID: fixture.sourceUID,
        mediaRelativePath: fixture.reviewPath
      ) == review.candidates
    )

    let manual = try await fixture.matcher.confirm(
      query: query,
      candidate: reviewCandidate,
      sourceUID: fixture.sourceUID,
      mediaRelativePath: fixture.reviewPath
    )
    #expect(manual.isLocked)
    #expect(manual.method == testCase.confirmedMethod)
    #expect(manual.role == testCase.confirmedRole)
    #expect(
      try await fixture.matcher.pendingCandidates(
        sourceUID: fixture.sourceUID,
        mediaRelativePath: fixture.reviewPath
      ).isEmpty
    )

    let preserved = try await fixture.matcher.evaluate(
      query: query,
      candidates: [testCase.replacementCandidate],
      sourceUID: fixture.sourceUID,
      mediaRelativePath: fixture.reviewPath
    )
    #expect(preserved.state == testCase.preservedState)
    #expect(preserved.binding == manual)
  }

  @Test("Two files with one provider identity become primary and version bindings")
  func bindsMultipleVersionsAndPreservesProviderFailure() async throws {
    let contract = try loadFixture()
    let fixture = try await makeFixture(contract)
    defer { fixture.remove() }
    let testCase = contract.multipleVersionsCase
    let query = testCase.query
    let candidate = testCase.candidate

    let first = try await fixture.matcher.evaluate(
      query: query,
      candidates: [candidate],
      sourceUID: fixture.sourceUID,
      mediaRelativePath: fixture.firstVersionPath
    )
    let second = try await fixture.matcher.evaluate(
      query: query,
      candidates: [candidate],
      sourceUID: fixture.sourceUID,
      mediaRelativePath: fixture.secondVersionPath
    )
    #expect(first.state == testCase.state)
    #expect(first.binding?.role == testCase.firstRole)
    #expect(second.state == testCase.state)
    #expect(second.binding?.role == testCase.secondRole)
    #expect(first.binding?.entityUID == second.binding?.entityUID)

    let beforeFailure = second.binding
    await #expect(throws: SDKError.self) {
      try await fixture.matcher.match(
        query: query,
        sourceUID: fixture.sourceUID,
        mediaRelativePath: fixture.secondVersionPath,
        using: FailingMetadataProvider()
      )
    }
    #expect(
      try await fixture.matcher.binding(
        sourceUID: fixture.sourceUID,
        mediaRelativePath: fixture.secondVersionPath
      ) == beforeFailure
    )
  }

  @Test("Series candidates materialize a stable series-season-episode hierarchy")
  func materializesEpisodeHierarchy() async throws {
    let contract = try loadFixture()
    let fixture = try await makeFixture(contract)
    defer { fixture.remove() }
    let testCase = contract.episodeCase

    let result = try await fixture.matcher.evaluate(
      query: testCase.query,
      candidates: [testCase.candidate],
      sourceUID: fixture.sourceUID,
      mediaRelativePath: fixture.episodePath
    )

    #expect(result.state == testCase.state)
    #expect(result.binding?.entityKind == testCase.entityKind)
    #expect(result.binding?.canonicalTitle == testCase.canonicalTitle)
    #expect(try await fixture.matcher.libraryStore.database.verify().isValid)
    #expect(try await fixture.matcher.metadataCacheStore.database.verify().isValid)
  }

  @Test("Extra files bind idempotently below an existing movie")
  func materializesExtra() async throws {
    let contract = try loadFixture()
    let fixture = try await makeFixture(contract)
    defer { fixture.remove() }
    let movieCase = contract.multipleVersionsCase
    let parent = try await fixture.matcher.evaluate(
      query: movieCase.query,
      candidates: [movieCase.candidate],
      sourceUID: fixture.sourceUID,
      mediaRelativePath: fixture.firstVersionPath
    )
    let parentUID = try #require(parent.binding?.entityUID)
    let testCase = contract.extraCase
    let first = try await fixture.matcher.bindExtra(
      sourceUID: fixture.sourceUID,
      mediaRelativePath: fixture.extraPath,
      parentEntityUID: parentUID,
      title: testCase.title
    )
    let replay = try await fixture.matcher.bindExtra(
      sourceUID: fixture.sourceUID,
      mediaRelativePath: fixture.extraPath,
      parentEntityUID: parentUID,
      title: testCase.title
    )

    #expect(first.entityKind == testCase.entityKind)
    #expect(first.role == testCase.bindingRole)
    #expect(first.method == testCase.matchMethod)
    #expect(first.isLocked == testCase.isLocked)
    #expect(first.entityUID == replay.entityUID)
    #expect(
      try await fixture.matcher.extraBinding(
        sourceUID: fixture.sourceUID,
        mediaRelativePath: fixture.extraPath
      ) == first
    )
  }

  @Test("Search index rebuild preserves manual bindings, playback, and pending outbox")
  func rebuildPreservesDurableState() async throws {
    let contract = try loadFixture()
    let fixture = try await makeFixture(contract)
    defer { fixture.remove() }
    let testCase = contract.reviewLockCase
    let manual = try await fixture.matcher.confirm(
      query: testCase.query,
      candidate: testCase.reviewCandidate,
      sourceUID: fixture.sourceUID,
      mediaRelativePath: fixture.reviewPath
    )

    try await fixture.matcher.libraryStore.database.write { database in
      guard
        let entityID = try Int64.fetchOne(
          database,
          sql: "SELECT id FROM media_entity WHERE uid = ?",
          arguments: [manual.entityUID]
        )
      else {
        throw SDKError(code: .storageFailure, message: "rebuild entity fixture is missing")
      }
      try database.execute(
        sql: """
          INSERT INTO playback_profile(
            uid, display_name, is_default, created_at_ms, updated_at_ms
          ) VALUES ('profile-rebuild', 'Rebuild Fixture', 1, 1700000000000, 1700000000000)
          """
      )
      guard
        let profileID = try Int64.fetchOne(
          database,
          sql: "SELECT id FROM playback_profile WHERE uid = 'profile-rebuild'"
        )
      else {
        throw SDKError(code: .storageFailure, message: "rebuild profile fixture is missing")
      }
      try database.execute(
        sql: """
          INSERT INTO playback_state(
            profile_id, entity_id, position_ms, duration_ms, completed,
            play_count, last_played_at_ms, updated_at_ms, revision
          ) VALUES (?, ?, 42000, 6960000, 0, 1, 1700000000000, 1700000000000, 1)
          """,
        arguments: [profileID, entityID]
      )
      try database.execute(
        sql: """
          INSERT INTO change_log(
            event_uid, entity_type, entity_uid, operation, payload_json,
            device_uid, modified_at_ms
          ) VALUES (
            'event-rebuild', 'playback_state', ?, 'upsert', '{"position_ms":42000}',
            'device-rebuild', 1700000000000
          )
          """,
        arguments: [manual.entityUID]
      )
      try database.execute(
        sql: """
          INSERT INTO search_document(
            entity_id, title, aliases, people, genres, romanized, updated_at_ms
          ) VALUES (?, 'stale title', '', '', '', '', 1)
          """,
        arguments: [entityID]
      )
      try database.execute(
        sql: """
          CREATE TRIGGER fail_search_document_rebuild
          BEFORE INSERT ON search_document
          BEGIN
            SELECT RAISE(ABORT, 'synthetic rebuild failure');
          END
          """
      )
    }

    await #expect(throws: SDKError.self) {
      try await fixture.matcher.libraryStore.rebuildSearchDocuments()
    }
    let titleAfterFailure = try await fixture.matcher.libraryStore.database.read { database in
      try String.fetchOne(
        database,
        sql:
          "SELECT title FROM search_document WHERE entity_id = (SELECT id FROM media_entity WHERE uid = ?)",
        arguments: [manual.entityUID]
      )
    }
    #expect(titleAfterFailure == "stale title")
    try await fixture.matcher.libraryStore.database.write { database in
      try database.execute(sql: "DROP TRIGGER fail_search_document_rebuild")
    }

    let rebuiltCount = try await fixture.matcher.libraryStore.rebuildSearchDocuments()
    let durable = try await fixture.matcher.libraryStore.database.read { database in
      guard
        let row = try Row.fetchOne(
          database,
          sql: """
              SELECT sd.title,
                     fb.locked,
                     ps.position_ms,
                     (SELECT COUNT(*) FROM change_log WHERE uploaded_at_ms IS NULL) AS pending_count
              FROM media_entity e
              JOIN search_document sd ON sd.entity_id = e.id
              JOIN file_binding fb ON fb.entity_id = e.id
              JOIN playback_state ps ON ps.entity_id = e.id
              WHERE e.uid = ?
            """,
          arguments: [manual.entityUID]
        )
      else {
        throw SDKError(code: .storageFailure, message: "rebuilt state fixture is missing")
      }
      return RebuildDurableSnapshot(
        title: row["title"],
        locked: (row["locked"] as Int) == 1,
        positionMilliseconds: row["position_ms"],
        pendingOutboxCount: row["pending_count"]
      )
    }

    #expect(rebuiltCount == 1)
    #expect(durable.title == manual.canonicalTitle)
    #expect(durable.locked)
    #expect(durable.positionMilliseconds == 42_000)
    #expect(durable.pendingOutboxCount == 1)
    #expect(
      try await fixture.matcher.binding(
        sourceUID: fixture.sourceUID,
        mediaRelativePath: fixture.reviewPath
      ) == manual
    )
  }

  private func makeFixture(_ contract: MatchPersistenceFixture) async throws
    -> SQLiteMatcherFixture
  {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "stellar-media-matcher-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let clock = MatchTestClock()
    let libraryDatabase = try await StorageDatabase.open(
      kind: .library,
      at: directory.appendingPathComponent("library.sqlite"),
      clock: clock
    )
    let cacheDatabase = try await StorageDatabase.open(
      kind: .metadataCache,
      at: directory.appendingPathComponent("metadata_cache.sqlite"),
      clock: clock
    )
    let libraryStore = try LibraryStore(database: libraryDatabase, clock: clock)
    let cacheStore = try MetadataCacheStore(database: cacheDatabase)
    let sourceUID = contract.sourceUID
    try await libraryStore.registerSource(
      LibrarySourceDefinition(
        uid: sourceUID,
        kind: .smb,
        displayName: "Match Fixture",
        rootURI: "smb://match-fixture"
      )
    )
    let paths = [
      contract.files.firstVersion,
      contract.files.secondVersion,
      contract.files.review,
      contract.files.episode,
      contract.files.extra,
    ]
    let entries = try paths.enumerated().map { index, path in
      try RemoteEntry(
        locator: RemoteLocator(sourceUID: sourceUID, path: RemotePath(path)),
        kind: .file,
        stableID: "match-file-\(index)",
        size: Int64(1_000 + index),
        modifiedAtMilliseconds: 1_700_000_000_000 + Int64(index)
      )
    }
    let capabilities = try MediaSourceCapabilities(
      stableIDScope: .persistent,
      pathSemantics: RemotePathSemantics(
        caseSensitivity: .sensitive,
        unicodeNormalization: .nfc
      ),
      supportsRangeReads: true,
      supportsChangeCursor: false,
      deltaDeletionsComplete: false
    )
    try await libraryStore.commit(
      LibraryScanPersistenceBatch(
        runUID: "match-scan",
        sourceUID: sourceUID,
        mode: "full",
        state: "completed",
        checkpointJSON: #"{"phase":"completed"}"#,
        coverageJSON: #"{"roots":[""]}"#,
        entries: entries,
        capabilities: capabilities,
        discoveredEntryCount: Int64(entries.count)
      )
    )
    return SQLiteMatcherFixture(
      directory: directory,
      sourceUID: sourceUID,
      firstVersionPath: paths[0],
      secondVersionPath: paths[1],
      reviewPath: paths[2],
      episodePath: paths[3],
      extraPath: paths[4],
      matcher: SQLiteMediaMatcher(
        libraryStore: libraryStore,
        metadataCacheStore: cacheStore,
        clock: clock
      )
    )
  }

  private func loadFixture() throws -> MatchPersistenceFixture {
    let fixtureURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent(
        "specs/fixtures/media-library/metadata-match-persistence-v1.json"
      )
    return try JSONDecoder().decode(
      MatchPersistenceFixture.self,
      from: Data(contentsOf: fixtureURL)
    )
  }
}

private struct MatchPersistenceFixture: Decodable {
  let schemaVersion: Int
  let sourceUID: String
  let files: MatchPersistenceFiles
  let reviewLockCase: ReviewLockFixtureCase
  let multipleVersionsCase: MultipleVersionsFixtureCase
  let episodeCase: EpisodePersistenceFixtureCase
  let extraCase: ExtraPersistenceFixtureCase

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case sourceUID = "source_uid"
    case files
    case reviewLockCase = "review_lock_case"
    case multipleVersionsCase = "multiple_versions_case"
    case episodeCase = "episode_case"
    case extraCase = "extra_case"
  }
}

private struct MatchPersistenceFiles: Decodable {
  let firstVersion: String
  let secondVersion: String
  let review: String
  let episode: String
  let extra: String

  private enum CodingKeys: String, CodingKey {
    case firstVersion = "first_version"
    case secondVersion = "second_version"
    case review
    case episode
    case extra
  }
}

private struct ReviewLockFixtureCase: Decodable {
  let query: MediaMatchQuery
  let reviewCandidate: MediaMetadataCandidate
  let replacementCandidate: MediaMetadataCandidate
  let reviewState: MediaMatchPersistenceState
  let reviewScore: Double
  let confirmedRole: MediaMatchBindingRole
  let confirmedMethod: MediaMatchMethod
  let preservedState: MediaMatchPersistenceState

  private enum CodingKeys: String, CodingKey {
    case query
    case reviewCandidate = "review_candidate"
    case replacementCandidate = "replacement_candidate"
    case reviewState = "review_state"
    case reviewScore = "review_score"
    case confirmedRole = "confirmed_role"
    case confirmedMethod = "confirmed_method"
    case preservedState = "preserved_state"
  }
}

private struct MultipleVersionsFixtureCase: Decodable {
  let query: MediaMatchQuery
  let candidate: MediaMetadataCandidate
  let state: MediaMatchPersistenceState
  let firstRole: MediaMatchBindingRole
  let secondRole: MediaMatchBindingRole

  private enum CodingKeys: String, CodingKey {
    case query
    case candidate
    case state
    case firstRole = "first_role"
    case secondRole = "second_role"
  }
}

private struct EpisodePersistenceFixtureCase: Decodable {
  let query: MediaMatchQuery
  let candidate: MediaMetadataCandidate
  let state: MediaMatchPersistenceState
  let entityKind: ParsedMediaKind
  let canonicalTitle: String

  private enum CodingKeys: String, CodingKey {
    case query
    case candidate
    case state
    case entityKind = "entity_kind"
    case canonicalTitle = "canonical_title"
  }
}

private struct ExtraPersistenceFixtureCase: Decodable {
  let title: String
  let entityKind: ParsedMediaKind
  let bindingRole: MediaMatchBindingRole
  let matchMethod: MediaMatchMethod
  let isLocked: Bool

  private enum CodingKeys: String, CodingKey {
    case title
    case entityKind = "entity_kind"
    case bindingRole = "binding_role"
    case matchMethod = "match_method"
    case isLocked = "is_locked"
  }
}

private struct SQLiteMatcherFixture: Sendable {
  let directory: URL
  let sourceUID: String
  let firstVersionPath: String
  let secondVersionPath: String
  let reviewPath: String
  let episodePath: String
  let extraPath: String
  let matcher: SQLiteMediaMatcher

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}

private struct MatchTestClock: SDKClock {
  func nowMilliseconds() -> Int64 { 1_700_000_000_000 }

  func sleep(forMilliseconds _: Int64) async throws {}
}

private struct RebuildDurableSnapshot: Sendable {
  let title: String
  let locked: Bool
  let positionMilliseconds: Int64
  let pendingOutboxCount: Int
}

private struct FailingMetadataProvider: MediaMetadataProviding {
  func search(_: MediaMatchQuery) async throws -> [MediaMetadataCandidate] {
    throw SDKError(code: .networkUnavailable, message: "synthetic provider failure")
  }
}

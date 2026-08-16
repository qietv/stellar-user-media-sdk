import Foundation
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

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case sourceUID = "source_uid"
    case files
    case reviewLockCase = "review_lock_case"
    case multipleVersionsCase = "multiple_versions_case"
    case episodeCase = "episode_case"
  }
}

private struct MatchPersistenceFiles: Decodable {
  let firstVersion: String
  let secondVersion: String
  let review: String
  let episode: String

  private enum CodingKeys: String, CodingKey {
    case firstVersion = "first_version"
    case secondVersion = "second_version"
    case review
    case episode
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

private struct SQLiteMatcherFixture: Sendable {
  let directory: URL
  let sourceUID: String
  let firstVersionPath: String
  let secondVersionPath: String
  let reviewPath: String
  let episodePath: String
  let matcher: SQLiteMediaMatcher

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}

private struct MatchTestClock: SDKClock {
  func nowMilliseconds() -> Int64 { 1_700_000_000_000 }

  func sleep(forMilliseconds _: Int64) async throws {}
}

private struct FailingMetadataProvider: MediaMetadataProviding {
  func search(_: MediaMatchQuery) async throws -> [MediaMetadataCandidate] {
    throw SDKError(code: .networkUnavailable, message: "synthetic provider failure")
  }
}

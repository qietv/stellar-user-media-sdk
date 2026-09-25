import Foundation
import GRDB
import StellarCore
import StellarMediaLibrary
import StellarRemoteMedia
import StellarStorage
import Testing

@Suite("SDK reaudit regressions", .serialized)
struct ReauditRegressionTests {
  @Test("Numeric titles, release noise, provider IDs and episode ranges reach the query")
  func filenameEvidence() throws {
    let parser = MediaFilenameParser()
    #expect(parser.parse("1917.2019.2160p.mkv").title == "1917")
    #expect(parser.parse("1917.2019.2160p.mkv").year == 2019)
    #expect(parser.parse("2012.mkv").title == "2012")
    #expect(parser.parse("2012.mkv").year == nil)
    #expect(parser.parse("2001.A.Space.Odyssey.1968.mkv").title == "2001 A Space Odyssey")
    let query = try MediaMatchQueryBuilder().build(
      analysis: parser.analyze("Show.S01E01-E02.1080p.{tmdb-42}.mkv"))
    #expect(query.title == "Show")
    #expect(query.episodeEnd == 2)
    #expect(query.externalIDs.first?.value == "42")
    #expect(parser.parse("Arrival.1080p.WEB-DL.x265.mkv").title == "Arrival")
  }

  @Test("Popularity cannot break an identity tie, and conflicting IDs are rejected")
  func ambiguity() throws {
    let query = try MediaMatchQuery(kind: .movie, title: "Example", year: 2024)
    let candidates = try ["a", "b"].enumerated().map { index, id in
      try MediaMetadataCandidate(
        provider: "test", candidateID: id, kind: .movie,
        title: "Example", year: 2024, popularity: Double(index * 100))
    }
    let ranked = MediaMetadataCandidateScorer().rank(query: query, candidates: candidates)
    #expect(
      ranked.allSatisfy { $0.decision == .review && $0.signals.contains(.ambiguousCandidates) })
    let identified = try MediaMatchQuery(
      kind: .movie, title: "Example", year: 2024,
      externalIDs: [LocalMetadataExternalID(provider: "test", namespace: "movie", value: "a")])
    let exact = MediaMetadataCandidateScorer().rank(query: identified, candidates: candidates)
    #expect(exact.first?.candidate.candidateID == "a")
    #expect(exact.last?.signals == [.conflictingExternalID])
  }

  @Test("An expired worker cannot write intake or overwrite the replacement worker's binding")
  func staleWorker() async throws {
    let fixture = try await ReauditFixture.make()
    defer { fixture.remove() }
    let oldStore = try fixture.store(at: 100)
    let leaseA = try #require(
      try await oldStore.claimScanFileWork(
        sourceUID: "source",
        stage: .parse, workerID: "a", leaseDurationMilliseconds: 1_000
      ).first)
    let store = try fixture.store(at: 1_101)
    let leaseB = try #require(
      try await store.claimScanFileWork(
        sourceUID: "source",
        stage: .parse, workerID: "b", leaseDurationMilliseconds: 1_000
      ).first)
    let matcher = fixture.matcher(store)
    let query = try MediaMatchQuery(kind: .movie, title: "Example", year: 2024)
    let winner = try fixture.candidate("b")
    let result = try await matcher.evaluate(
      query: query, candidates: [winner], sourceUID: "source",
      mediaRelativePath: fixture.path, lease: leaseB, metadata: fixture.metadata("b"))
    #expect(result.state == .automaticBound)
    await #expect(throws: SDKError.self) {
      _ = try await matcher.evaluate(
        query: query, candidates: [fixture.candidate("a")],
        sourceUID: "source", mediaRelativePath: fixture.path, lease: leaseA)
    }
    await #expect(throws: SDKError.self) {
      try await SQLiteMediaMetadataStore(store: store).persist(fixture.intake(), lease: leaseA)
    }
    #expect(
      try await matcher.binding(sourceUID: "source", mediaRelativePath: fixture.path)
        == result.binding)
    let parsedCount = try await fixture.database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM parse_result")
    }
    #expect(parsedCount == 0)
  }

  @Test("A material revision changed during provider search rejects the delayed result")
  func staleSearch() async throws {
    let fixture = try await ReauditFixture.make()
    defer { fixture.remove() }
    let store = try fixture.store(at: 100)
    let target = try await store.metadataRefreshTarget(
      sourceUID: "source", mediaRelativePath: fixture.path)
    let matcher = fixture.matcher(store)
    await #expect(throws: SDKError.self) {
      _ = try await matcher.match(
        query: MediaMatchQuery(kind: .movie, title: "Example", year: 2024),
        sourceUID: "source", mediaRelativePath: fixture.path,
        using: InvalidatingProvider(
          store: store, target: target, candidate: fixture.candidate("late")))
    }
    #expect(try await matcher.binding(sourceUID: "source", mediaRelativePath: fixture.path) == nil)
    await #expect(throws: SDKError.self) {
      try await SQLiteMediaMetadataStore(store: store).persist(
        fixture.intake(), expectedRevision: target)
    }
  }

  @Test("Binding rolls back with invalid provider metadata and lease completion is atomic")
  func atomicBinding() async throws {
    let fixture = try await ReauditFixture.make()
    defer { fixture.remove() }
    let store = try fixture.store(at: 100)
    let lease = try #require(
      try await store.claimScanFileWork(
        sourceUID: "source",
        stage: .parse, workerID: "worker"
      ).first)
    let matcher = fixture.matcher(store)
    let query = try MediaMatchQuery(kind: .movie, title: "Example", year: 2024)
    await #expect(throws: SDKError.self) {
      _ = try await matcher.evaluate(
        query: query, candidates: [fixture.candidate("right")],
        sourceUID: "source", mediaRelativePath: fixture.path, lease: lease,
        metadata: fixture.metadata("wrong"))
    }
    #expect(try await matcher.binding(sourceUID: "source", mediaRelativePath: fixture.path) == nil)
    #expect(try await store.hasOutstandingScanWork(sourceUID: "source", stage: .parse))
    let result = try await matcher.evaluate(
      query: query, candidates: [fixture.candidate("right")],
      sourceUID: "source", mediaRelativePath: fixture.path, lease: lease,
      metadata: fixture.metadata("right"), enqueueArtwork: true)
    #expect(result.state == .automaticBound)
    #expect(try await store.hasOutstandingScanWork(sourceUID: "source", stage: .parse) == false)
    #expect(try await store.hasOutstandingScanWork(sourceUID: "source", stage: .artwork))
  }

  @Test("Only changing a sidecar invalidates the revision and cannot overwrite manual identity")
  func sidecarDependency() async throws {
    let fixture = try await ReauditFixture.make()
    defer { fixture.remove() }
    let store = try fixture.store(at: 100)
    let metadataStore = SQLiteMediaMetadataStore(store: store)
    let original = try fixture.intake(digest: "a")
    try await metadataStore.persist(original)
    let target = try #require(try await store.metadataRefreshTargets(sourceUID: "source").first)
    let lease = try #require(
      try await store.claimScanFileWork(
        sourceUID: "source",
        stage: .parse, workerID: "old"
      ).first)
    #expect(try await metadataStore.refreshIfChanged(original, target: target) == false)
    let matcher = fixture.matcher(store)
    let query = try MediaMatchQuery(kind: .movie, title: "Example", year: 2024)
    let manual = try await matcher.confirm(
      query: query, candidate: fixture.candidate("manual"),
      sourceUID: "source", mediaRelativePath: fixture.path)
    #expect(try await metadataStore.refreshIfChanged(fixture.intake(digest: "b"), target: target))
    await #expect(throws: SDKError.self) { try await metadataStore.persist(original, lease: lease) }
    let fresh = try #require(
      try await store.claimScanFileWork(
        sourceUID: "source",
        stage: .parse, workerID: "new"
      ).first)
    #expect(fresh.inputRevision == lease.inputRevision + 1)
    #expect(
      try await matcher.binding(sourceUID: "source", mediaRelativePath: fixture.path) == manual)
    await #expect(throws: SDKError.self) { try await store.invalidateMetadata(target) }
  }

  @Test("Episode ranges require every coordinate and materialize all contained episodes")
  func episodeRange() async throws {
    let fixture = try await ReauditFixture.make()
    defer { fixture.remove() }
    let matcher = fixture.matcher(try fixture.store(at: 100))
    let query = try MediaMatchQuery(
      kind: .episode, title: "Show", season: 1, episode: 1, episodeEnd: 2)
    let first = try MediaMetadataCandidate(
      provider: "test", candidateID: "show", kind: .series,
      title: "Show", availableEpisodes: [MediaEpisodeCoordinate(season: 1, episode: 1)])
    let incomplete = try await matcher.evaluate(
      query: query, candidates: [first], sourceUID: "source",
      mediaRelativePath: fixture.path)
    #expect(incomplete.state == .detailsRequired)
    let full = try MediaMetadataCandidate(
      provider: "test", candidateID: "show", kind: .series,
      title: "Show",
      availableEpisodes: [
        MediaEpisodeCoordinate(season: 1, episode: 1),
        MediaEpisodeCoordinate(season: 1, episode: 2),
      ])
    let result = try await matcher.evaluate(
      query: query, candidates: [full], sourceUID: "source",
      mediaRelativePath: fixture.path)
    #expect(result.state == .automaticBound)
    let episodes = try await fixture.database.read { db in
      try Int.fetchAll(
        db,
        sql: """
          SELECT e.episode_number FROM file_binding b JOIN media_entity e ON e.id = b.entity_id
          WHERE e.kind = 'episode' ORDER BY e.episode_number
          """)
    }
    #expect(episodes == [1, 2])
  }

  @Test("Complete NFO evidence builds a movie or episode offline without manufactured coordinates")
  func offlineMetadata() async throws {
    let fixture = try await ReauditFixture.make()
    defer { fixture.remove() }
    let store = try fixture.store(at: 100)
    let lease = try #require(
      try await store.claimScanFileWork(
        sourceUID: "source", stage: .parse,
        workerID: "offline"
      ).first)
    let document = try NFOParser().parse(
      Data("<movie><title>Offline Movie</title><plot>Local plot</plot></movie>".utf8))
    let evidence = try #require(
      try LocalMetadataMatchEvidence.build(
        document: document,
        sourceUID: "source", mediaRelativePath: fixture.path, stableKey: lease.file.stableKey))
    let result = try await fixture.matcher(store).evaluate(
      query: evidence.query,
      candidates: [evidence.candidate], sourceUID: "source", mediaRelativePath: fixture.path,
      lease: lease, metadata: evidence.metadata, method: .sidecarID)
    #expect(result.state == .automaticBound)
    #expect(result.binding?.canonicalTitle == "Offline Movie")
    #expect(try await store.hasOutstandingScanWork(sourceUID: "source", stage: .parse) == false)
    let episode = try LocalMetadataDocument(
      kind: .episode, title: "Pilot", seriesTitle: "Local Show",
      season: 1, episode: 2)
    let episodeEvidence = try #require(
      try LocalMetadataMatchEvidence.build(
        document: episode,
        sourceUID: "source", mediaRelativePath: "Local Show/Season 1/02.mkv", stableKey: "episode"))
    #expect(episodeEvidence.candidate.title == "Local Show")
    #expect(
      episodeEvidence.candidate.availableEpisodes == [
        try MediaEpisodeCoordinate(season: 1, episode: 2)
      ])
  }

  @Test("Partial publication preserves the last complete success and records a warning")
  func partialScan() async throws {
    let fixture = try await ReauditFixture.make()
    defer { fixture.remove() }
    let store = try fixture.store(at: 200)
    try await fixture.publish(store, run: "partial", error: "scan_partial")
    let values = try await fixture.database.read { db in
      let row = try #require(
        try Row.fetchOne(
          db,
          sql:
            "SELECT last_scan_at_ms, last_successful_scan_at_ms, last_error_code FROM library_source"
        ))
      return (
        row["last_scan_at_ms"] as Int64, row["last_successful_scan_at_ms"] as Int64,
        row["last_error_code"] as String?
      )
    }
    #expect(values.0 == 200)
    #expect(values.1 == 100)
    #expect(values.2 == "scan_partial")
  }
}

private struct ReauditClock: SDKClock {
  let now: Int64
  func nowMilliseconds() -> Int64 { now }
  func sleep(forMilliseconds _: Int64) async throws {}
}

private struct ReauditFixture {
  let directory: URL
  let database: StorageDatabase
  let cache: MetadataCacheStore
  let path = "Example.2024.mkv"

  static func make() async throws -> Self {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let database = try await StorageDatabase.open(
      kind: .library, at: directory.appendingPathComponent("library.sqlite"))
    let cacheDB = try await StorageDatabase.open(
      kind: .metadataCache, at: directory.appendingPathComponent("cache.sqlite"))
    let fixture = try Self(
      directory: directory, database: database, cache: MetadataCacheStore(database: cacheDB))
    let store = try fixture.store(at: 100)
    try await store.registerSource(
      LibrarySourceDefinition(
        uid: "source", kind: .localFolder,
        displayName: "Fixture", rootURI: "file:///fixture"))
    try await fixture.publish(store, run: "initial")
    return fixture
  }
  func store(at now: Int64) throws -> LibraryStore {
    try LibraryStore(database: database, clock: ReauditClock(now: now))
  }
  func matcher(_ store: LibraryStore) -> SQLiteMediaMatcher {
    SQLiteMediaMatcher(libraryStore: store, metadataCacheStore: cache)
  }
  func remove() { try? FileManager.default.removeItem(at: directory) }
  func candidate(_ id: String) throws -> MediaMetadataCandidate {
    try MediaMetadataCandidate(
      provider: "test", candidateID: id, kind: .movie, title: "Example", year: 2024)
  }
  func metadata(_ id: String) throws -> LibraryRemoteMetadata {
    try LibraryRemoteMetadata(
      provider: "test", providerID: id, kind: .movie, locale: "en", title: "Example", year: 2024)
  }
  func intake(digest: String? = nil) throws -> MediaMetadataIntakeBatch {
    let sidecars =
      try digest.map { value in
        [
          try MediaSidecarIntake(
            descriptor: MediaSidecarDescriptor(kind: .nfo, relativePath: "Example.2024.nfo"),
            modifiedAtMilliseconds: 100, sha256: String(repeating: value, count: 64))
        ]
      } ?? []
    return try MediaMetadataIntakeBatch(
      sourceUID: "source", mediaRelativePath: path,
      filename: MediaFilenameParser().analyze(path), sidecars: sidecars)
  }
  func publish(_ store: LibraryStore, run: String, error: String? = nil) async throws {
    let capabilities = try MediaSourceCapabilities(
      stableIDScope: .persistent,
      pathSemantics: RemotePathSemantics(caseSensitivity: .sensitive, unicodeNormalization: .nfc),
      supportsRangeReads: true, supportsChangeCursor: false, deltaDeletionsComplete: false)
    try await store.commit(
      LibraryScanPersistenceBatch(
        runUID: run, sourceUID: "source", mode: "full",
        state: "completed", checkpointJSON: "{}", coverageJSON: "{}",
        entries: [
          RemoteEntry(
            locator: RemoteLocator(sourceUID: "source", path: RemotePath(path)),
            kind: .file, stableID: "stable-file", size: 100)
        ], capabilities: capabilities,
        discoveredEntryCount: 1, errorCode: error))
  }
}

private struct InvalidatingProvider: MediaMetadataProviding {
  let store: LibraryStore
  let target: LibraryMetadataRefreshTarget
  let candidate: MediaMetadataCandidate
  func search(_: MediaMatchQuery) async throws -> [MediaMetadataCandidate] {
    try await store.invalidateMetadata(target)
    return [candidate]
  }
}

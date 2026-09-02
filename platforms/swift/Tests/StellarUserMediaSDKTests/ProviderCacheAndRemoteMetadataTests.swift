import Foundation
import StellarCore
import StellarMediaLibrary
import StellarPosterWall
import StellarRemoteMedia
import StellarStorage
import Testing

@Suite("Provider cache and remote metadata persistence", .serialized)
struct ProviderCacheAndRemoteMetadataTests {
  @Test("Provider responses round-trip only for the full request fingerprint")
  func providerResponseCache() async throws {
    let directory = temporaryDirectory(prefix: "stellar-provider-cache")
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await StorageDatabase.open(
      kind: .metadataCache,
      at: directory.appendingPathComponent("metadata_cache.sqlite")
    )
    let store = try MetadataCacheStore(database: database)
    let entry = try MetadataProviderResponseCacheEntry(
      requestKey: "provider-a1",
      provider: "provider",
      endpoint: "entities/42",
      requestFingerprint: "GET\nhttps://example.test/entities/42\n",
      locale: "zh-CN",
      httpStatus: 200,
      entityTag: #""v1""#,
      responseJSON: #"{"title":"Example"}"#,
      fetchedAtMilliseconds: 1_000,
      expiresAtMilliseconds: 2_000
    )

    try await store.storeProviderResponse(entry)
    let cached = try await store.providerResponse(
      requestKey: entry.requestKey,
      requestFingerprint: entry.requestFingerprint
    )
    #expect(cached == entry)
    #expect(cached?.isFresh(at: 1_999) == true)
    #expect(cached?.isFresh(at: 2_000) == false)
    let collision = try await store.providerResponse(
      requestKey: entry.requestKey,
      requestFingerprint: "different request"
    )
    #expect(collision == nil)
  }

  @Test("Remote metadata, poster selection, and queue completion share one transaction")
  func remoteMetadataCommit() async throws {
    let directory = temporaryDirectory(prefix: "stellar-remote-metadata")
    defer { try? FileManager.default.removeItem(at: directory) }
    let libraryDatabase = try await StorageDatabase.open(
      kind: .library,
      at: directory.appendingPathComponent("library.sqlite")
    )
    let cacheDatabase = try await StorageDatabase.open(
      kind: .metadataCache,
      at: directory.appendingPathComponent("metadata_cache.sqlite")
    )
    let store = try LibraryStore(database: libraryDatabase)
    let cacheStore = try MetadataCacheStore(database: cacheDatabase)
    let sourceUID = "remote-metadata-source"
    let path = "Movies/Example.2024.mkv"
    try await store.registerSource(
      LibrarySourceDefinition(
        uid: sourceUID,
        kind: .smb,
        displayName: "Metadata Fixture",
        rootURI: "smb://metadata-fixture"
      )
    )
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
    let entry = try RemoteEntry(
      locator: RemoteLocator(sourceUID: sourceUID, path: RemotePath(path)),
      kind: .file,
      stableID: "movie-42",
      size: 42
    )
    try await store.commit(
      LibraryScanPersistenceBatch(
        runUID: "remote-metadata-run",
        sourceUID: sourceUID,
        mode: "full",
        state: "completed",
        checkpointJSON: #"{"phase":"completed"}"#,
        coverageJSON: #"{"roots":[""]}"#,
        entries: [entry],
        capabilities: capabilities,
        coveredRoots: [RemoteLocator(sourceUID: sourceUID, path: RemotePath())],
        reconcileMissingEligible: true,
        discoveredEntryCount: 1
      )
    )

    let matcher = SQLiteMediaMatcher(libraryStore: store, metadataCacheStore: cacheStore)
    let query = try MediaMatchQuery(kind: .movie, title: "Example", year: 2024)
    let candidate = try MediaMetadataCandidate(
      provider: "test-provider",
      candidateID: "movie-42",
      kind: .movie,
      title: "Example",
      year: 2024,
      popularity: 1
    )
    let match = try await matcher.evaluate(
      query: query,
      candidates: [candidate],
      sourceUID: sourceUID,
      mediaRelativePath: path
    )
    #expect(match.state == .automaticBound)
    let lease = try #require(
      try await store.claimScanFileWork(
        sourceUID: sourceUID,
        stage: .parse,
        workerID: "metadata-worker"
      ).first
    )

    let wrongMetadata = try LibraryRemoteMetadata(
      provider: "test-provider",
      providerID: "different-id",
      kind: .movie,
      locale: "zh-CN",
      title: "Wrong"
    )
    await #expect(throws: SDKError.self) {
      try await store.commitRemoteMetadata(
        wrongMetadata,
        completing: lease
      )
    }
    let competingClaims = try await store.claimScanFileWork(
      sourceUID: sourceUID,
      stage: .parse,
      workerID: "other-worker"
    )
    #expect(competingClaims.isEmpty)

    let metadata = try LibraryRemoteMetadata(
      provider: "test-provider",
      providerID: "movie-42",
      kind: .movie,
      locale: "zh-CN",
      title: "示例电影",
      originalTitle: "Example",
      overview: "Structured metadata stored with the queue acknowledgement.",
      year: 2024,
      posterURL: "https://images.example.test/poster.jpg",
      posterWidth: 1_000,
      posterHeight: 1_500
    )

    let changedEntry = try RemoteEntry(
      locator: RemoteLocator(sourceUID: sourceUID, path: RemotePath(path)),
      kind: .file,
      stableID: "movie-42",
      size: 43
    )
    try await store.commit(
      LibraryScanPersistenceBatch(
        runUID: "remote-metadata-run-2",
        sourceUID: sourceUID,
        mode: "full",
        state: "completed",
        checkpointJSON: #"{"phase":"completed"}"#,
        coverageJSON: #"{"roots":[""]}"#,
        entries: [changedEntry],
        capabilities: capabilities,
        coveredRoots: [RemoteLocator(sourceUID: sourceUID, path: RemotePath())],
        reconcileMissingEligible: true,
        discoveredEntryCount: 1
      )
    )
    await #expect(throws: SDKError.self) {
      try await store.commitRemoteMetadata(metadata, completing: lease)
    }
    let localizedCount = try await libraryDatabase.read { database in
      try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM localized_metadata") ?? 0
    }
    #expect(localizedCount == 0)
    let currentLease = try #require(
      try await store.claimScanFileWork(
        sourceUID: sourceUID,
        stage: .parse,
        workerID: "metadata-worker"
      ).first
    )
    #expect(currentLease.inputRevision == lease.inputRevision + 1)
    let rootUID = try await store.commitRemoteMetadata(
      metadata,
      completing: currentLease
    )
    let pending = try await store.pendingScanWork(sourceUID: sourceUID, stage: .parse)
    #expect(pending.isEmpty)

    let wall = try PosterWallStore(database: libraryDatabase)
    let page = try await wall.page(
      PosterWallQuery(section: .all, locale: "zh-CN", pageSize: 20)
    )
    let item = try #require(page.items.first)
    #expect(item.mediaUID == rootUID)
    #expect(item.title == "示例电影")
    #expect(item.poster?.remoteReference == "https://images.example.test/poster.jpg")
    let searchPage = try await wall.page(
      PosterWallQuery(
        section: .all,
        searchText: "Example",
        locale: "zh-CN",
        pageSize: 20
      )
    )
    #expect(searchPage.items.map(\.mediaUID) == [rootUID])
    let details = try await wall.details(mediaUID: rootUID, locale: "zh-CN")
    #expect(details.overview == "Structured metadata stored with the queue acknowledgement.")
  }

  private func temporaryDirectory(prefix: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "\(prefix)-\(UUID().uuidString)",
      isDirectory: true
    )
  }
}

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

  @Test("Primary metadata commits before optional visual assets with revision-safe writes")
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
      year: 2024
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
      completing: currentLease,
      enqueueArtwork: true
    )
    let pending = try await store.pendingScanWork(sourceUID: sourceUID, stage: .parse)
    #expect(pending.isEmpty)

    let wall = try PosterWallStore(database: libraryDatabase)
    let primaryPage = try await wall.page(
      PosterWallQuery(section: .all, locale: "zh-CN", pageSize: 20)
    )
    let primaryItem = try #require(primaryPage.items.first)
    #expect(primaryItem.mediaUID == rootUID)
    #expect(primaryItem.title == "示例电影")
    #expect(primaryItem.poster == nil)

    let artworkLease = try #require(
      try await store.claimScanFileWork(
        sourceUID: sourceUID,
        stage: .artwork,
        workerID: "artwork-worker"
      ).first
    )
    let artworkTarget = try await store.remoteArtworkTarget(
      for: artworkLease,
      provider: "test-provider"
    )
    #expect(
      artworkTarget
        == (try LibraryRemoteArtworkTarget(
          provider: "test-provider",
          providerID: "movie-42",
          kind: .movie
        ))
    )
    _ = try await store.commitRemoteArtwork(
      LibraryRemoteArtwork(
        target: artworkTarget,
        locale: "zh-CN",
        remoteURL: "https://images.example.test/poster.jpg",
        width: 1_000,
        height: 1_500
      ),
      completing: artworkLease
    )
    #expect(!(try await store.hasOutstandingScanWork(sourceUID: sourceUID, stage: .artwork)))
    let artworkPage = try await wall.page(
      PosterWallQuery(section: .all, locale: "zh-CN", pageSize: 20)
    )
    #expect(
      artworkPage.items.first?.poster?.remoteReference
        == "https://images.example.test/poster.jpg"
    )
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

    #expect(try await store.enqueueMissingThumbnailWork(sourceUID: sourceUID) == 1)
    let thumbnailLease = try #require(
      try await store.claimScanFileWork(
        sourceUID: sourceUID,
        stage: .artwork,
        workerID: "thumbnail-worker"
      ).first
    )
    _ = try await store.commitGeneratedThumbnail(
      LibraryGeneratedThumbnail(
        localRelativePath: "thumbnails/example.jpg",
        sha256: String(repeating: "a", count: 64),
        mimeType: "image/jpeg",
        width: 1_280,
        height: 720
      ),
      for: thumbnailLease
    )
    #expect(!(try await store.hasOutstandingScanWork(sourceUID: sourceUID, stage: .artwork)))
    #expect(try await store.enqueueMissingThumbnailWork(sourceUID: sourceUID) == 0)
    let thumbnailDetails = try await wall.details(mediaUID: rootUID, locale: "zh-CN")
    let thumbnail = try #require(thumbnailDetails.artwork.first { $0.kind == "thumbnail" })
    #expect(thumbnail.localRelativePath == "thumbnails/example.jpg")

    try await libraryDatabase.write { database in
      try database.execute(sql: "DELETE FROM artwork WHERE kind = 'poster'")
    }
    let fallbackPage = try await wall.page(
      PosterWallQuery(section: .all, locale: "zh-CN", pageSize: 20)
    )
    #expect(fallbackPage.items.first?.poster?.kind == "thumbnail")
    #expect(fallbackPage.items.first?.poster?.localRelativePath == "thumbnails/example.jpg")

    try await libraryDatabase.write { database in
      try database.execute(
        sql: """
          INSERT INTO media_collection(
            uid, kind, title, created_at_ms, updated_at_ms
          ) VALUES ('playlist-example', 'manual', 'Example Playlist', 1, 1)
          """
      )
      try database.execute(
        sql: """
          INSERT INTO collection_item(collection_id, entity_id, position, added_at_ms)
          SELECT collection.id, entity.id, 0, 1
          FROM media_collection collection, media_entity entity
          WHERE collection.uid = 'playlist-example' AND entity.uid = ?
          """,
        arguments: [rootUID]
      )
    }
    let collectionTarget = try await store.collectionThumbnailTarget(
      collectionUID: "playlist-example"
    )
    #expect(collectionTarget.members.map(\.entityUID) == [rootUID])
    #expect(collectionTarget.members.first?.locator.path.relativePath == path)
    #expect(collectionTarget.currentThumbnail == nil)
    let collectionThumbnail = try LibraryGeneratedThumbnail(
      localRelativePath: "thumbnails/playlist-example.jpg",
      sha256: String(repeating: "b", count: 64),
      mimeType: "image/jpeg",
      width: 640,
      height: 360
    )
    _ = try await store.commitGeneratedCollectionThumbnail(
      collectionThumbnail,
      for: collectionTarget
    )
    #expect(
      try await store.collectionThumbnailTarget(collectionUID: "playlist-example")
        .currentThumbnail == collectionThumbnail
    )
    try await libraryDatabase.write { database in
      try database.execute(
        sql: "UPDATE media_file SET availability = 'offline' WHERE relative_path = ?",
        arguments: [path]
      )
    }
    let offlineCollectionTarget = try await store.collectionThumbnailTarget(
      collectionUID: "playlist-example"
    )
    #expect(offlineCollectionTarget.members.isEmpty)
    #expect(offlineCollectionTarget.currentThumbnail == collectionThumbnail)
    try await libraryDatabase.write { database in
      try database.execute(
        sql: """
          UPDATE media_file
          SET availability = 'present', material_revision = material_revision + 1
          WHERE relative_path = ?
          """,
        arguments: [path]
      )
    }
    let changedCollectionTarget = try await store.collectionThumbnailTarget(
      collectionUID: "playlist-example"
    )
    #expect(changedCollectionTarget.inputSignature != collectionTarget.inputSignature)
    #expect(changedCollectionTarget.currentThumbnail == nil)
    await #expect(throws: SDKError.self) {
      _ = try await store.commitGeneratedCollectionThumbnail(
        collectionThumbnail,
        for: collectionTarget
      )
    }

    #expect(
      try await store.enqueueMissingProbeWork(
        sourceUID: sourceUID,
        probeVersion: 1
      ) == 1
    )
    let probeLease = try #require(
      try await store.claimScanFileWork(
        sourceUID: sourceUID,
        stage: .probe,
        workerID: "probe-worker"
      ).first
    )
    try await SQLiteMediaMetadataStore(store: store).persistTechnicalProbe(
      makeTechnicalProbe(version: 1),
      completing: probeLease
    )
    #expect(!(try await store.hasOutstandingScanWork(sourceUID: sourceUID, stage: .probe)))
    #expect(
      try await store.enqueueMissingProbeWork(
        sourceUID: sourceUID,
        probeVersion: 1
      ) == 0
    )
    let probedDetails = try await wall.details(mediaUID: rootUID, locale: "zh-CN")
    #expect(probedDetails.playableFiles.first?.videoCodec == "hevc")
    #expect(probedDetails.playableFiles.first?.width == 3_840)
    #expect(probedDetails.playableFiles.first?.streams.map(\.codec) == ["hevc", "eac3"])

    #expect(
      try await store.enqueueMissingProbeWork(
        sourceUID: sourceUID,
        probeVersion: 2
      ) == 1
    )
    let failedProbeLease = try #require(
      try await store.claimScanFileWork(
        sourceUID: sourceUID,
        stage: .probe,
        workerID: "failing-probe-worker"
      ).first
    )
    try await store.failScanWork(failedProbeLease, errorCode: .remoteUnavailable)
    #expect(
      try await store.claimScanFileWork(
        sourceUID: sourceUID,
        stage: .probe,
        workerID: "blocked-probe-worker"
      ).isEmpty
    )
    #expect(try await store.resetFailedScanWork(sourceUID: sourceUID, stages: [.probe]) == 1)
    let repairedProbeLease = try #require(
      try await store.claimScanFileWork(
        sourceUID: sourceUID,
        stage: .probe,
        workerID: "repair-probe-worker"
      ).first
    )
    try await SQLiteMediaMetadataStore(store: store).persistTechnicalProbe(
      makeTechnicalProbe(version: 2),
      completing: repairedProbeLease
    )
    #expect(!(try await store.hasOutstandingScanWork(sourceUID: sourceUID, stage: .probe)))
  }

  private func makeTechnicalProbe(version: Int) throws -> MediaTechnicalProbeResult {
    try MediaTechnicalProbeResult(
      probeProvider: "fixture-probe",
      probeVersion: version,
      summary: MediaTechnicalSummary(
        container: "matroska",
        durationMilliseconds: 7_020_123,
        videoCodec: "hevc",
        width: 3_840,
        height: 2_160,
        audioCodec: "eac3",
        audioChannels: 6
      ),
      streams: [
        MediaTechnicalStream(
          streamIndex: 0,
          kind: .video,
          codec: "hevc",
          width: 3_840,
          height: 2_160,
          isDefault: true
        ),
        MediaTechnicalStream(
          streamIndex: 1,
          kind: .audio,
          codec: "eac3",
          language: "en",
          channelCount: 6,
          isDefault: true
        ),
      ]
    )
  }

  private func temporaryDirectory(prefix: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "\(prefix)-\(UUID().uuidString)",
      isDirectory: true
    )
  }
}

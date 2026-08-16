import Foundation
import GRDB
import StellarCore
import StellarPosterWall
import StellarStorage
import Testing

@Suite("PosterWall v1 contract", .serialized)
struct PosterWallContractTests {
  @Test("Shared fixture covers sections, filters, search, stable pagination, and selected artwork")
  func listAndSearchFixture() async throws {
    let contract = try loadFixture()
    let fixture = try await makeFixture(contract)
    defer { fixture.remove() }

    #expect(contract.schemaVersion == 1)
    let pagination = contract.cases.titlePagination
    let first = try await fixture.store.page(pagination.query)
    #expect(first.items.map(\.mediaUID) == pagination.expectedPages[0])
    #expect(first.nextCursor != nil)
    let secondQuery = try continuing(pagination.query, from: first)
    let second = try await fixture.store.page(secondQuery)
    #expect(second.items.map(\.mediaUID) == pagination.expectedPages[1])
    #expect(second.nextCursor == nil)
    #expect(second.libraryRevision == first.libraryRevision)
    #expect(second.items.first?.poster?.artworkUID == "art-matrix-selected")

    let listCases = [
      contract.cases.recentlyAdded,
      contract.cases.search,
      contract.cases.genre,
      contract.cases.collection,
    ]
    for testCase in listCases {
      let page = try await fixture.store.page(testCase.query)
      #expect(page.items.map(\.mediaUID) == testCase.expectedUIDs)
    }

    let watching = contract.cases.continueWatching
    let watchingPage = try await fixture.store.page(watching.query)
    #expect(watchingPage.items.map(\.mediaUID) == watching.expectedUIDs)
    #expect(watchingPage.items.compactMap(\.progress) == watching.expectedProgress)
    #expect(watchingPage.items.first?.unwatchedEpisodeCount == 1)
  }

  @Test("Details expose series hierarchy, playable files, artwork, and stream summaries")
  func detailsFixture() async throws {
    let contract = try loadFixture()
    let fixture = try await makeFixture(contract)
    defer { fixture.remove() }
    let expected = contract.cases.details

    let details = try await fixture.store.details(
      mediaUID: expected.mediaUID,
      profileUID: contract.profileUID,
      locale: "en"
    )
    #expect(details.genres == expected.expectedGenres)
    #expect(details.externalIDs.map(\.value) == expected.expectedExternalIDs)
    #expect(details.seasons.map(\.mediaUID) == expected.expectedSeasonUIDs)
    #expect(details.seasons.flatMap(\.episodes).map(\.mediaUID) == expected.expectedEpisodeUIDs)
    #expect(
      details.seasons.flatMap(\.episodes).flatMap(\.files).map(\.fileUID)
        == expected.expectedEpisodeFileUIDs
    )
    #expect(details.item.poster?.artworkUID == expected.expectedSelectedPosterUID)
    #expect(
      details.seasons.flatMap(\.episodes).flatMap(\.files).flatMap(\.streams).map(\.kind)
        == expected.expectedStreamKinds
    )
    #expect(details.overview == "Humanity has colonized the Solar System.")
  }

  @Test("A cursor fails closed after the library revision changes")
  func staleCursorFailsClosed() async throws {
    let contract = try loadFixture()
    let fixture = try await makeFixture(contract)
    defer { fixture.remove() }
    let query = contract.cases.titlePagination.query
    let first = try await fixture.store.page(query)
    #expect(first.nextCursor != nil)

    try await fixture.database.write { database in
      try database.execute(
        sql: "UPDATE media_entity SET updated_at_ms = updated_at_ms + 1 WHERE uid = 'movie-alien'"
      )
    }
    let continuation = try continuing(query, from: first)
    do {
      _ = try await fixture.store.page(continuation)
      Issue.record("stale cursor unexpectedly succeeded")
    } catch let error as SDKError {
      #expect(error.code == .conflict)
    }
  }

  @Test("Artwork cache identities include every variant dimension and reject signed references")
  func artworkCacheContract() async throws {
    let request = try PosterWallArtworkVariantRequest(
      artworkUID: "art-expanse-poster",
      provider: "fixture",
      remoteReference: "/expanse-poster.jpg",
      targetPixelWidth: 600,
      targetPixelHeight: 900
    )
    let larger = try PosterWallArtworkVariantRequest(
      artworkUID: "art-expanse-poster",
      provider: "fixture",
      remoteReference: "/expanse-poster.jpg",
      targetPixelWidth: 1200,
      targetPixelHeight: 1800
    )
    #expect(request.cacheIdentity != larger.cacheIdentity)
    let record = try PosterWallArtworkCacheRecord(
      request: request,
      localRelativePath: "fixture/600x900/art-expanse-poster.jpg",
      byteCount: 1024,
      lastAccessedAtMilliseconds: 5000
    )
    let index = InMemoryPosterWallArtworkCacheIndex()
    try await index.store(record)
    #expect(try await index.record(for: request) == record)
    try await index.remove(request)
    #expect(try await index.record(for: request) == nil)

    #expect(throws: SDKError.self) {
      try PosterWallArtworkVariantRequest(
        artworkUID: "temporary",
        provider: "fixture",
        remoteReference: "https://images.example.test/poster.jpg?token=temporary",
        targetPixelWidth: 600,
        targetPixelHeight: 900
      )
    }
  }

  private func continuing(_ query: PosterWallQuery, from page: PosterWallPage) throws
    -> PosterWallQuery
  {
    try PosterWallQuery(
      section: query.section,
      sort: query.sort,
      filter: query.filter,
      searchText: query.searchText,
      profileUID: query.profileUID,
      collectionUID: query.collectionUID,
      locale: query.locale,
      pageSize: query.pageSize,
      cursor: page.nextCursor,
      libraryRevision: page.libraryRevision,
      randomSeed: query.randomSeed
    )
  }

  private func makeFixture(_ contract: PosterWallFixtureContract) async throws
    -> PosterWallFixture
  {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "stellar-poster-wall-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = try await StorageDatabase.open(
      kind: .library,
      at: directory.appendingPathComponent("library.sqlite")
    )
    try await seed(contract.seed, profileUID: contract.profileUID, database: database)
    return PosterWallFixture(
      directory: directory,
      database: database,
      store: try PosterWallStore(database: database)
    )
  }

  private func seed(
    _ seed: PosterWallSeed,
    profileUID: String,
    database: StorageDatabase
  ) async throws {
    try await database.write { database in
      for source in seed.sources {
        try database.execute(
          sql: """
            INSERT INTO library_source(
              uid, kind, display_name, root_uri, scan_policy, enabled, created_at_ms, updated_at_ms
            ) VALUES (?, ?, ?, ?, 'incremental', 1, 1, 1)
            """,
          arguments: [source.uid, source.kind, source.displayName, source.rootURI]
        )
      }
      for entity in seed.entities {
        let parentID = try entity.parentUID.flatMap { parentUID in
          try Int64.fetchOne(
            database,
            sql: "SELECT id FROM media_entity WHERE uid = ?",
            arguments: [parentUID]
          )
        }
        try database.execute(
          sql: """
            INSERT INTO media_entity(
              uid, kind, parent_id, canonical_title, sort_title, year, season_number,
              episode_number, release_date, status, metadata_state, created_at_ms, updated_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', 'complete', ?, ?)
            """,
          arguments: [
            entity.uid, entity.kind, parentID, entity.title, entity.title, entity.year,
            entity.seasonNumber, entity.episodeNumber, entity.releaseDate,
            entity.createdAtMilliseconds, entity.updatedAtMilliseconds,
          ]
        )
      }
      for file in seed.files {
        let sourceID = try requiredID(
          table: "library_source",
          uid: file.sourceUID,
          database: database
        )
        try database.execute(
          sql: """
            INSERT INTO media_file(
              uid, source_id, stable_key, relative_path, path_compare_key, display_name,
              size_bytes, availability, updated_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 5000)
            """,
          arguments: [
            file.uid, sourceID, file.uid, file.relativePath, file.relativePath,
            file.relativePath.split(separator: "/").last.map(String.init) ?? file.relativePath,
            file.sizeBytes, file.availability,
          ]
        )
      }
      for binding in seed.bindings {
        try database.execute(
          sql: """
            INSERT INTO file_binding(
              media_file_id, entity_id, binding_role, match_method, confidence,
              matched_query, locked, decided_at_ms
            ) VALUES (?, ?, ?, 'provider_search', 1.0, '{}', 0, 5000)
            """,
          arguments: [
            try requiredID(table: "media_file", uid: binding.fileUID, database: database),
            try requiredID(table: "media_entity", uid: binding.entityUID, database: database),
            binding.role,
          ]
        )
      }
      for metadata in seed.localizedMetadata {
        try database.execute(
          sql: """
            INSERT INTO localized_metadata(
              entity_id, locale, title, overview, tagline, content_rating,
              provider, materialized_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, 'fixture', 5000)
            """,
          arguments: [
            try requiredID(table: "media_entity", uid: metadata.entityUID, database: database),
            metadata.locale, metadata.title, metadata.overview, metadata.tagline,
            metadata.contentRating,
          ]
        )
      }
      for genre in seed.genres {
        try database.execute(
          sql: "INSERT INTO genre(uid, provider, provider_key) VALUES (?, 'fixture', ?)",
          arguments: [genre.uid, genre.uid]
        )
        let genreID = database.lastInsertedRowID
        try database.execute(
          sql: "INSERT INTO genre_name(genre_id, locale, name) VALUES (?, 'und', ?)",
          arguments: [genreID, genre.name]
        )
        for (position, entityUID) in genre.entityUIDs.enumerated() {
          try database.execute(
            sql: "INSERT INTO entity_genre(entity_id, genre_id, position) VALUES (?, ?, ?)",
            arguments: [
              try requiredID(table: "media_entity", uid: entityUID, database: database),
              genreID, position,
            ]
          )
        }
      }
      for artwork in seed.artwork {
        try database.execute(
          sql: """
            INSERT INTO artwork(
              uid, entity_id, kind, locale, provider, remote_url, width, height,
              score, is_selected, updated_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 5000)
            """,
          arguments: [
            artwork.uid,
            try requiredID(table: "media_entity", uid: artwork.entityUID, database: database),
            artwork.kind, artwork.locale, artwork.provider, artwork.remoteReference,
            artwork.width, artwork.height, artwork.score, artwork.isSelected ? 1 : 0,
          ]
        )
      }
      for document in seed.searchDocuments {
        try database.execute(
          sql: """
            INSERT INTO search_document(
              entity_id, title, aliases, people, genres, romanized, updated_at_ms
            ) VALUES (?, ?, ?, ?, ?, '', 5000)
            """,
          arguments: [
            try requiredID(table: "media_entity", uid: document.entityUID, database: database),
            document.title, document.aliases, document.people, document.genres,
          ]
        )
      }
      for collection in seed.collections {
        try database.execute(
          sql: """
            INSERT INTO media_collection(
              uid, kind, title, sort_title, created_at_ms, updated_at_ms
            ) VALUES (?, 'manual', ?, ?, 5000, 5000)
            """,
          arguments: [collection.uid, collection.title, collection.title]
        )
        let collectionID = database.lastInsertedRowID
        for (position, entityUID) in collection.entityUIDs.enumerated() {
          try database.execute(
            sql: """
              INSERT INTO collection_item(collection_id, entity_id, position, added_at_ms)
              VALUES (?, ?, ?, 5000)
              """,
            arguments: [
              collectionID,
              try requiredID(table: "media_entity", uid: entityUID, database: database),
              position,
            ]
          )
        }
      }
      try database.execute(
        sql: """
          INSERT INTO playback_profile(uid, display_name, is_default, created_at_ms, updated_at_ms)
          VALUES (?, 'Main', 1, 5000, 5000)
          """,
        arguments: [profileUID]
      )
      let profileID = database.lastInsertedRowID
      for playback in seed.playback {
        try database.execute(
          sql: """
            INSERT INTO playback_state(
              profile_id, entity_id, position_ms, duration_ms, completed, play_count,
              last_played_at_ms, updated_at_ms, revision
            ) VALUES (?, ?, ?, ?, ?, 1, ?, ?, 1)
            """,
          arguments: [
            profileID,
            try requiredID(table: "media_entity", uid: playback.entityUID, database: database),
            playback.positionMilliseconds, playback.durationMilliseconds,
            playback.completed ? 1 : 0, playback.lastPlayedAtMilliseconds,
            playback.lastPlayedAtMilliseconds,
          ]
        )
      }
      for summary in seed.technicalSummaries {
        try database.execute(
          sql: """
            INSERT INTO technical_summary(
              media_file_id, duration_ms, video_codec, width, height,
              probe_provider, probe_version, probed_at_ms
            ) VALUES (?, ?, ?, ?, ?, 'fixture', 1, 5000)
            """,
          arguments: [
            try requiredID(table: "media_file", uid: summary.fileUID, database: database),
            summary.durationMilliseconds, summary.videoCodec, summary.width, summary.height,
          ]
        )
      }
      for stream in seed.streams {
        try database.execute(
          sql: """
            INSERT INTO media_stream(
              media_file_id, stream_index, kind, codec, language, title, is_default, is_forced
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            try requiredID(table: "media_file", uid: stream.fileUID, database: database),
            stream.index, stream.kind, stream.codec, stream.language, stream.title,
            stream.isDefault ? 1 : 0, stream.isForced ? 1 : 0,
          ]
        )
      }
    }
  }

  private func requiredID(table: String, uid: String, database: Database) throws -> Int64 {
    guard ["library_source", "media_file", "media_entity"].contains(table),
      let value = try Int64.fetchOne(
        database,
        sql: "SELECT id FROM \(table) WHERE uid = ?",
        arguments: [uid]
      )
    else {
      throw SDKError(code: .storageFailure, message: "PosterWall fixture identity is missing")
    }
    return value
  }

  private func loadFixture() throws -> PosterWallFixtureContract {
    let fixtureURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("specs/fixtures/media-library/poster-wall-v1.json")
    return try JSONDecoder().decode(
      PosterWallFixtureContract.self,
      from: Data(contentsOf: fixtureURL)
    )
  }
}

private struct PosterWallFixture: Sendable {
  let directory: URL
  let database: StorageDatabase
  let store: PosterWallStore

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}

private struct PosterWallFixtureContract: Decodable, Sendable {
  let schemaVersion: Int
  let profileUID: String
  let seed: PosterWallSeed
  let cases: PosterWallCases

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case profileUID = "profile_uid"
    case seed
    case cases
  }
}

private struct PosterWallSeed: Decodable, Sendable {
  let sources: [SeedSource]
  let entities: [SeedEntity]
  let files: [SeedFile]
  let bindings: [SeedBinding]
  let localizedMetadata: [SeedLocalizedMetadata]
  let genres: [SeedGenre]
  let artwork: [SeedArtwork]
  let searchDocuments: [SeedSearchDocument]
  let collections: [SeedCollection]
  let playback: [SeedPlayback]
  let technicalSummaries: [SeedTechnicalSummary]
  let streams: [SeedStream]

  private enum CodingKeys: String, CodingKey {
    case sources
    case entities
    case files
    case bindings
    case localizedMetadata = "localized_metadata"
    case genres
    case artwork
    case searchDocuments = "search_documents"
    case collections
    case playback
    case technicalSummaries = "technical_summaries"
    case streams
  }
}

private struct SeedSource: Decodable, Sendable {
  let uid: String
  let kind: String
  let displayName: String
  let rootURI: String

  private enum CodingKeys: String, CodingKey {
    case uid
    case kind
    case displayName = "display_name"
    case rootURI = "root_uri"
  }
}

private struct SeedEntity: Decodable, Sendable {
  let uid: String
  let kind: String
  let parentUID: String?
  let title: String
  let year: Int?
  let seasonNumber: Int?
  let episodeNumber: Int?
  let releaseDate: String?
  let createdAtMilliseconds: Int64
  let updatedAtMilliseconds: Int64

  private enum CodingKeys: String, CodingKey {
    case uid
    case kind
    case parentUID = "parent_uid"
    case title
    case year
    case seasonNumber = "season_number"
    case episodeNumber = "episode_number"
    case releaseDate = "release_date"
    case createdAtMilliseconds = "created_at_ms"
    case updatedAtMilliseconds = "updated_at_ms"
  }
}

private struct SeedFile: Decodable, Sendable {
  let uid: String
  let sourceUID: String
  let relativePath: String
  let availability: String
  let sizeBytes: Int64

  private enum CodingKeys: String, CodingKey {
    case uid
    case sourceUID = "source_uid"
    case relativePath = "relative_path"
    case availability
    case sizeBytes = "size_bytes"
  }
}

private struct SeedBinding: Decodable, Sendable {
  let fileUID: String
  let entityUID: String
  let role: String

  private enum CodingKeys: String, CodingKey {
    case fileUID = "file_uid"
    case entityUID = "entity_uid"
    case role
  }
}

private struct SeedLocalizedMetadata: Decodable, Sendable {
  let entityUID: String
  let locale: String
  let title: String
  let overview: String?
  let tagline: String?
  let contentRating: String?

  private enum CodingKeys: String, CodingKey {
    case entityUID = "entity_uid"
    case locale
    case title
    case overview
    case tagline
    case contentRating = "content_rating"
  }
}

private struct SeedGenre: Decodable, Sendable {
  let uid: String
  let name: String
  let entityUIDs: [String]

  private enum CodingKeys: String, CodingKey {
    case uid
    case name
    case entityUIDs = "entity_uids"
  }
}

private struct SeedArtwork: Decodable, Sendable {
  let uid: String
  let entityUID: String
  let kind: String
  let locale: String
  let provider: String
  let remoteReference: String
  let width: Int
  let height: Int
  let score: Double
  let isSelected: Bool

  private enum CodingKeys: String, CodingKey {
    case uid
    case entityUID = "entity_uid"
    case kind
    case locale
    case provider
    case remoteReference = "remote_reference"
    case width
    case height
    case score
    case isSelected = "is_selected"
  }
}

private struct SeedSearchDocument: Decodable, Sendable {
  let entityUID: String
  let title: String
  let aliases: String
  let people: String
  let genres: String

  private enum CodingKeys: String, CodingKey {
    case entityUID = "entity_uid"
    case title
    case aliases
    case people
    case genres
  }
}

private struct SeedCollection: Decodable, Sendable {
  let uid: String
  let title: String
  let entityUIDs: [String]

  private enum CodingKeys: String, CodingKey {
    case uid
    case title
    case entityUIDs = "entity_uids"
  }
}

private struct SeedPlayback: Decodable, Sendable {
  let entityUID: String
  let positionMilliseconds: Int64
  let durationMilliseconds: Int64
  let completed: Bool
  let lastPlayedAtMilliseconds: Int64

  private enum CodingKeys: String, CodingKey {
    case entityUID = "entity_uid"
    case positionMilliseconds = "position_ms"
    case durationMilliseconds = "duration_ms"
    case completed
    case lastPlayedAtMilliseconds = "last_played_at_ms"
  }
}

private struct SeedTechnicalSummary: Decodable, Sendable {
  let fileUID: String
  let durationMilliseconds: Int64
  let videoCodec: String
  let width: Int
  let height: Int

  private enum CodingKeys: String, CodingKey {
    case fileUID = "file_uid"
    case durationMilliseconds = "duration_ms"
    case videoCodec = "video_codec"
    case width
    case height
  }
}

private struct SeedStream: Decodable, Sendable {
  let fileUID: String
  let index: Int
  let kind: String
  let codec: String
  let language: String
  let title: String?
  let isDefault: Bool
  let isForced: Bool

  private enum CodingKeys: String, CodingKey {
    case fileUID = "file_uid"
    case index
    case kind
    case codec
    case language
    case title
    case isDefault = "is_default"
    case isForced = "is_forced"
  }
}

private struct PosterWallCases: Decodable, Sendable {
  let titlePagination: PosterWallPaginationCase
  let recentlyAdded: PosterWallListCase
  let continueWatching: PosterWallProgressCase
  let search: PosterWallListCase
  let genre: PosterWallListCase
  let collection: PosterWallListCase
  let details: PosterWallDetailsCase

  private enum CodingKeys: String, CodingKey {
    case titlePagination = "title_pagination"
    case recentlyAdded = "recently_added"
    case continueWatching = "continue_watching"
    case search
    case genre
    case collection
    case details
  }
}

private struct PosterWallPaginationCase: Decodable, Sendable {
  let query: PosterWallQuery
  let expectedPages: [[String]]

  private enum CodingKeys: String, CodingKey {
    case query
    case expectedPages = "expected_pages"
  }
}

private struct PosterWallListCase: Decodable, Sendable {
  let query: PosterWallQuery
  let expectedUIDs: [String]

  private enum CodingKeys: String, CodingKey {
    case query
    case expectedUIDs = "expected_uids"
  }
}

private struct PosterWallProgressCase: Decodable, Sendable {
  let query: PosterWallQuery
  let expectedUIDs: [String]
  let expectedProgress: [Double]

  private enum CodingKeys: String, CodingKey {
    case query
    case expectedUIDs = "expected_uids"
    case expectedProgress = "expected_progress"
  }
}

private struct PosterWallDetailsCase: Decodable, Sendable {
  let mediaUID: String
  let expectedGenres: [String]
  let expectedExternalIDs: [String]
  let expectedSeasonUIDs: [String]
  let expectedEpisodeUIDs: [String]
  let expectedEpisodeFileUIDs: [String]
  let expectedSelectedPosterUID: String
  let expectedStreamKinds: [String]

  private enum CodingKeys: String, CodingKey {
    case mediaUID = "media_uid"
    case expectedGenres = "expected_genres"
    case expectedExternalIDs = "expected_external_ids"
    case expectedSeasonUIDs = "expected_season_uids"
    case expectedEpisodeUIDs = "expected_episode_uids"
    case expectedEpisodeFileUIDs = "expected_episode_file_uids"
    case expectedSelectedPosterUID = "expected_selected_poster_uid"
    case expectedStreamKinds = "expected_stream_kinds"
  }
}

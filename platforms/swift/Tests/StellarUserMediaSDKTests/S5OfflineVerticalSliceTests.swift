import Foundation
import StellarCore
import StellarMediaLibrary
import StellarPosterWall
import StellarRemoteMedia
import StellarSMB2Core
import StellarStorage
import Testing

@Suite("S5 offline vertical slice", .serialized)
struct S5OfflineVerticalSliceTests {
  @Test("SMB fixture scans, materializes, and produces PosterWall JSON")
  func smbToPosterWall() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "stellar-s5-vertical-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let libraryDatabase = try await StorageDatabase.open(
      kind: .library,
      at: directory.appendingPathComponent("library.sqlite")
    )
    let cacheDatabase = try await StorageDatabase.open(
      kind: .metadataCache,
      at: directory.appendingPathComponent("metadata_cache.sqlite")
    )
    let libraryStore = try LibraryStore(database: libraryDatabase)
    let cacheStore = try MetadataCacheStore(database: cacheDatabase)
    let sourceUID = "smb-s5-fixture"
    try await libraryStore.registerSource(
      LibrarySourceDefinition(
        uid: sourceUID,
        kind: .smb,
        displayName: "S5 Fixture",
        rootURI: "smb://fixture.invalid/Media"
      )
    )

    let rootPath = try SMB2Path()
    let moviesPath = try SMB2Path("Movies")
    let moviePath = try SMB2Path("Movies/Arrival.2016.mkv")
    let root = try SMB2Entry(path: rootPath, kind: .directory, stableID: "root")
    let movies = try SMB2Entry(path: moviesPath, kind: .directory, stableID: "movies")
    let movie = try SMB2Entry(
      path: moviePath,
      kind: .file,
      size: 1_024,
      modifiedAtMilliseconds: 1_700_000_000_000,
      stableID: "arrival-file"
    )
    let request = try SMB2ConnectionRequest(
      endpoint: SMB2Endpoint(server: "fixture.invalid", share: "Media"),
      credential: SMB2Credential(username: "fixture-user", password: "")
    )
    let connector = SMB2MediaSourceConnector(
      transport: S5FixtureSMBTransport(
        session: S5FixtureSMBSession(root: root, movies: movies, movie: movie)
      ),
      configuration: try SMB2MediaSourceConfiguration(
        sourceUID: sourceUID,
        connectionRequest: request,
        stableIDScope: .persistent
      )
    )
    let rootLocator = try RemoteLocator(sourceUID: sourceUID, path: RemotePath())
    let scan = try await MediaScanner().scan(
      MediaScanRequest(
        runUID: "s5-vertical-scan",
        sourceUID: sourceUID,
        mode: .full,
        roots: [rootLocator]
      ),
      using: connector,
      sink: SQLiteMediaScanSink(store: libraryStore)
    )

    #expect(scan.completion.reconcileMissingEligible)
    #expect(scan.checkpoint.discoveredEntryCount == 2)
    #expect(try await libraryStore.snapshot().files.map(\.relativePath) == [moviePath.relativePath])

    let parsed = MediaFilenameParser().parse(moviePath.relativePath)
    let query = try MediaMatchQueryBuilder().build(filename: parsed)
    let candidate = try MediaMetadataCandidate(
      provider: "tmdb",
      candidateID: "329865",
      kind: .movie,
      title: "Arrival",
      year: 2016,
      externalIDs: [
        try LocalMetadataExternalID(
          provider: "tmdb",
          namespace: "movie",
          value: "329865",
          isPrimary: true
        )
      ],
      popularity: 42.5
    )
    let matcher = SQLiteMediaMatcher(
      libraryStore: libraryStore,
      metadataCacheStore: cacheStore
    )
    let matched = try await matcher.evaluate(
      query: query,
      candidates: [candidate],
      sourceUID: sourceUID,
      mediaRelativePath: moviePath.relativePath
    )
    let binding = try #require(matched.binding)
    #expect(matched.state == .automaticBound)

    #expect(try await libraryStore.rebuildSearchDocuments() == 1)
    let wall = try PosterWallStore(database: libraryDatabase)
    let page = try await wall.page(try PosterWallQuery(section: .movies, pageSize: 10))
    let details = try await wall.details(mediaUID: binding.entityUID)
    let json = String(
      decoding: try canonicalEncoder().encode(page),
      as: UTF8.self
    )

    #expect(page.schemaVersion == 1)
    #expect(page.items.count == 1)
    #expect(page.items[0].title == "Arrival")
    #expect(details.playableFiles.map(\.relativePath) == [moviePath.relativePath])
    #expect(json.contains(#""schema_version":1"#))
    #expect(json.contains(#""title":"Arrival""#))
  }

  private func canonicalEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}

private actor S5FixtureSMBTransport: SMB2Transport {
  let session: any SMB2Session

  init(session: any SMB2Session) {
    self.session = session
  }

  func connect(_: SMB2ConnectionRequest) async throws -> any SMB2Session { session }
}

private actor S5FixtureSMBSession: SMB2Session {
  nonisolated let connectionInfo = SMB2ConnectionInfo(
    dialect: .smb311,
    signingPolicy: .enabled,
    encryptionPolicy: .disabled,
    implementationVersion: "fixture"
  )
  private let root: SMB2Entry
  private let movies: SMB2Entry
  private let movie: SMB2Entry
  private var disconnected = false

  init(root: SMB2Entry, movies: SMB2Entry, movie: SMB2Entry) {
    self.root = root
    self.movies = movies
    self.movie = movie
  }

  func listDirectory(at path: SMB2Path) async throws -> [SMB2Entry] {
    try requireConnected()
    if path == root.path { return [movies] }
    if path == movies.path { return [movie] }
    throw SDKError(code: .metadataNotFound, message: "fixture directory was not found")
  }

  func stat(_ path: SMB2Path) async throws -> SMB2Entry {
    try requireConnected()
    if path == root.path { return root }
    if path == movies.path { return movies }
    if path == movie.path { return movie }
    throw SDKError(code: .metadataNotFound, message: "fixture entry was not found")
  }

  func read(at path: SMB2Path, range: SMB2ByteRange) async throws -> Data {
    try requireConnected()
    guard path == movie.path else {
      throw SDKError(code: .metadataNotFound, message: "fixture entry was not found")
    }
    let bytes = Data("fixture-video".utf8)
    let lower = min(Int(range.offset), bytes.count)
    let upper = min(bytes.count, lower + range.length)
    return bytes.subdata(in: lower..<upper)
  }

  func disconnect() async { disconnected = true }

  private func requireConnected() throws {
    guard !disconnected else {
      throw SDKError(code: .remoteUnavailable, message: "fixture session disconnected")
    }
  }
}

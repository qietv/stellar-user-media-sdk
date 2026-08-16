import Foundation
import StellarCore
import StellarMediaLibrary
import StellarRemoteMedia
import StellarStorage
import Testing

@Suite("SQLite media metadata persistence", .serialized)
struct SQLiteMediaMetadataStoreTests {
  @Test("Filename, sidecars, local documents, and probe results commit atomically")
  func persistsCompleteIntake() async throws {
    let fixture = try await makeFixture()
    defer { fixture.remove() }
    let metadataStore = SQLiteMediaMetadataStore(store: fixture.store)
    let batch = try makeIntake(mediaPath: fixture.mediaPath, includeProbe: true)

    try await metadataStore.persist(batch)

    let snapshot = try #require(
      try await fixture.store.metadataIntakeSnapshot(
        sourceUID: fixture.sourceUID,
        mediaRelativePath: fixture.mediaPath
      )
    )
    #expect(snapshot.parseResult.mediaKind == "movie")
    #expect(snapshot.parseResult.cleanTitle == "Blade Runner")
    #expect(snapshot.parseResult.hintYear == 1982)
    #expect(snapshot.parseResult.edition == "Final Cut")
    #expect(snapshot.parseResult.parserVersion == MediaFilenameParser.version)
    #expect(snapshot.parseResult.rawTokensJSON?.contains(#""noise_tokens""#) == true)
    #expect(Set(snapshot.sidecars.map(\.kind)) == ["nfo", "metadata_json", "subtitle"])
    #expect(
      snapshot.sidecars.first(where: { $0.kind == "nfo" })?.parsedJSON?
        .contains("Blade Runner") == true
    )
    #expect(
      snapshot.sidecars.first(where: { $0.kind == "metadata_json" })?.parsedJSON?
        .contains("Arrival") == true
    )
    #expect(
      snapshot.sidecars.first(where: { $0.kind == "subtitle" })?.parsedJSON?
        .contains(#""hearing_impaired":true"#) == true
    )
    #expect(snapshot.technicalProbe?.probeProvider == "fixture-probe")
    #expect(snapshot.technicalProbe?.summary.width == 3_840)
    #expect(snapshot.technicalProbe?.streams.map(\.streamIndex) == [0, 1])
  }

  @Test("Missing probe preserves success and a later row failure rolls back the whole batch")
  func preservesProbeAndRollsBack() async throws {
    let fixture = try await makeFixture()
    defer { fixture.remove() }
    let metadataStore = SQLiteMediaMetadataStore(store: fixture.store)
    try await metadataStore.persist(
      makeIntake(mediaPath: fixture.mediaPath, includeProbe: true)
    )

    let noProbe = try makeIntake(
      mediaPath: fixture.mediaPath,
      includeProbe: false,
      sidecarLimit: 1
    )
    try await metadataStore.persist(noProbe)
    let preserved = try #require(
      try await fixture.store.metadataIntakeSnapshot(
        sourceUID: fixture.sourceUID,
        mediaRelativePath: fixture.mediaPath
      )
    )
    #expect(preserved.sidecars.count == 1)
    #expect(preserved.technicalProbe?.probeProvider == "fixture-probe")

    let changedAnalysis = try MediaFilenameParser().analyze("Changed.Title.2025.1080p.mkv")
    let failing = try MediaMetadataIntakeBatch(
      sourceUID: fixture.sourceUID,
      mediaRelativePath: fixture.mediaPath,
      filename: changedAnalysis,
      sidecars: Array(try makeIntake(mediaPath: fixture.mediaPath).sidecars.prefix(3)),
      technicalProbe: nil
    )
    await #expect(throws: SDKError.self) {
      try await metadataStore.persist(failing)
    }
    let afterFailure = try #require(
      try await fixture.store.metadataIntakeSnapshot(
        sourceUID: fixture.sourceUID,
        mediaRelativePath: fixture.mediaPath
      )
    )
    #expect(afterFailure == preserved)
  }

  private func makeFixture() async throws -> MetadataSQLiteFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "stellar-metadata-intake-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = try await StorageDatabase.open(
      kind: .library,
      at: directory.appendingPathComponent("library.sqlite"),
      clock: MetadataTestClock()
    )
    let store = try LibraryStore(
      database: database,
      clock: MetadataTestClock(),
      uuidGenerator: RepeatingMetadataUUIDGenerator()
    )
    let sourceUID = "metadata-source"
    let mediaPath = "Movies/Blade Runner (1982)/Blade.Runner.1982.Final.Cut.2160p.mkv"
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
      locator: RemoteLocator(sourceUID: sourceUID, path: RemotePath(mediaPath)),
      kind: .file,
      stableID: "blade-runner-file",
      size: 1_024,
      modifiedAtMilliseconds: 1_700_000_000_000
    )
    try await store.commit(
      LibraryScanPersistenceBatch(
        runUID: "metadata-scan",
        sourceUID: sourceUID,
        mode: "full",
        state: "completed",
        checkpointJSON: #"{"phase":"completed"}"#,
        coverageJSON: #"{"roots":[""]}"#,
        entries: [entry],
        capabilities: capabilities,
        discoveredEntryCount: 1
      )
    )
    return MetadataSQLiteFixture(
      directory: directory,
      sourceUID: sourceUID,
      mediaPath: mediaPath,
      store: store
    )
  }

  private func makeIntake(
    mediaPath: String,
    includeProbe: Bool = false,
    sidecarLimit: Int = .max
  ) throws -> MediaMetadataIntakeBatch {
    let classifier = MediaSidecarClassifier()
    let nfoPath = "Movies/Blade Runner (1982)/Blade.Runner.1982.Final.Cut.2160p.nfo"
    let jsonPath = "Movies/Blade Runner (1982)/movie.json"
    let subtitlePath =
      "Movies/Blade Runner (1982)/Blade.Runner.1982.Final.Cut.2160p.zh-Hans.sdh.srt"
    let nfo = try NFOParser().parse(
      Data(
        """
        <movie><title>Blade Runner</title><year>1982</year>
        <uniqueid type="tmdb" default="true">78</uniqueid></movie>
        """.utf8
      )
    )
    let json = try LocalMetadataJSONParser().parse(
      Data(
        #"{"kind":"movie","title":"Arrival","external_ids":[],"artwork":[]}"#.utf8
      )
    )
    let sidecars = try [
      MediaSidecarIntake(
        descriptor: #require(try classifier.classify(mediaPath: mediaPath, candidatePath: nfoPath)),
        modifiedAtMilliseconds: 1_700_000_000_001,
        sha256: String(repeating: "a", count: 64),
        metadata: nfo
      ),
      MediaSidecarIntake(
        descriptor: #require(
          try classifier.classify(mediaPath: mediaPath, candidatePath: jsonPath)
        ),
        metadata: json
      ),
      MediaSidecarIntake(
        descriptor: #require(
          try classifier.classify(mediaPath: mediaPath, candidatePath: subtitlePath)
        )
      ),
    ]
    return try MediaMetadataIntakeBatch(
      sourceUID: "metadata-source",
      mediaRelativePath: mediaPath,
      filename: MediaFilenameParser().analyze(mediaPath),
      sidecars: Array(sidecars.prefix(sidecarLimit)),
      technicalProbe: includeProbe ? makeProbe() : nil
    )
  }

  private func makeProbe() throws -> MediaTechnicalProbeResult {
    try MediaTechnicalProbeResult(
      probeProvider: "fixture-probe",
      probeVersion: 1,
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
}

private struct MetadataSQLiteFixture: Sendable {
  let directory: URL
  let sourceUID: String
  let mediaPath: String
  let store: LibraryStore

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}

private struct MetadataTestClock: SDKClock {
  func nowMilliseconds() -> Int64 { 1_700_000_000_000 }

  func sleep(forMilliseconds _: Int64) async throws {}
}

private final class RepeatingMetadataUUIDGenerator: SDKUUIDGenerating, @unchecked Sendable {
  private let lock = NSLock()
  private var invocation = 0

  func makeUUID() -> UUID {
    lock.lock()
    defer { lock.unlock() }
    invocation += 1
    let suffix = invocation >= 6 ? 6 : invocation
    return UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", suffix))!
  }
}

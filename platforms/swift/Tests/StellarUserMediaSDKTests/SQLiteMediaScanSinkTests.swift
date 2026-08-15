import Foundation
import StellarCore
import StellarLocalMedia
import StellarMediaLibrary
import StellarRemoteMedia
import StellarStorage
import Testing

@Suite("SQLite media scan persistence", .serialized)
struct SQLiteMediaScanSinkTests {
  @Test("A large file batch is atomic and replay-idempotent")
  func largeBatch() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "stellar-sqlite-large-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await StorageDatabase.open(
      kind: .library,
      at: directory.appendingPathComponent("library.sqlite")
    )
    let store = try LibraryStore(database: database)
    let sourceUID = "large-source"
    try await store.registerSource(
      LibrarySourceDefinition(
        uid: sourceUID,
        kind: .smb,
        displayName: "Large",
        rootURI: "smb://large-fixture"
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
    let root = try RemoteLocator(sourceUID: sourceUID, path: RemotePath())
    let entries = try (0..<2_000).map { index in
      try RemoteEntry(
        locator: RemoteLocator(
          sourceUID: sourceUID,
          path: RemotePath(String(format: "Movies/%05d.mkv", index))
        ),
        kind: .file,
        stableID: "file-\(index)",
        size: Int64(index)
      )
    }
    let batch = try LibraryScanPersistenceBatch(
      runUID: "large-run",
      sourceUID: sourceUID,
      mode: "full",
      state: "completed",
      checkpointJSON: #"{"phase":"completed"}"#,
      coverageJSON: #"{"roots":[""]}"#,
      entries: entries,
      capabilities: capabilities,
      coveredRoots: [root],
      reconcileMissingEligible: true,
      discoveredEntryCount: Int64(entries.count)
    )

    try await store.commit(batch)
    try await store.commit(batch)

    let snapshot = try await store.snapshot()
    #expect(snapshot.files.count == 2_000)
    #expect(snapshot.files.allSatisfy({ $0.availability == "present" }))
  }

  @Test("The public scanner fixture produces the canonical database snapshot idempotently")
  func publicFixtureSnapshot() async throws {
    let fixture = try JSONDecoder().decode(
      SQLiteScannerFixture.self,
      from: Data(contentsOf: scannerFixtureURL)
    )
    let scenario = try #require(
      fixture.scenarios.first(where: { $0.expectedLibrarySnapshot != nil })
    )
    let expectedSnapshot = try #require(scenario.expectedLibrarySnapshot)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "stellar-sqlite-manifest-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await StorageDatabase.open(
      kind: .library,
      at: directory.appendingPathComponent("library.sqlite")
    )
    let store = try LibraryStore(database: database)
    try await store.registerSource(
      LibrarySourceDefinition(
        uid: fixture.sourceUID,
        kind: .smb,
        displayName: "Fixture",
        rootURI: "smb://fixture"
      )
    )
    let scanner = MediaScanner(
      configuration: try MediaScannerConfiguration(
        pageSize: scenario.pages.first?.request.limit ?? 500,
        maxConcurrentDirectoryRequests: 1
      )
    )
    let connector = SQLiteFixtureConnector(
      sourceUID: fixture.sourceUID,
      capabilities: fixture.capabilities,
      pages: scenario.pages
    )
    let sink = SQLiteMediaScanSink(store: store)

    _ = try await scanner.scan(scenario.request, using: connector, sink: sink)
    #expect(try await store.snapshot() == expectedSnapshot)

    let repeatedRequest = try MediaScanRequest(
      runUID: "scan-full-repeat",
      sourceUID: scenario.request.sourceUID,
      mode: scenario.request.mode,
      roots: scenario.request.roots
    )
    _ = try await scanner.scan(repeatedRequest, using: connector, sink: sink)
    #expect(try await store.snapshot() == expectedSnapshot)

    let scopedScenario = try #require(
      fixture.scenarios.first(where: { $0.name == "scoped_incremental" })
    )
    _ = try await scanner.scan(
      scopedScenario.request,
      using: SQLiteFixtureConnector(
        sourceUID: fixture.sourceUID,
        capabilities: fixture.capabilities,
        pages: scopedScenario.pages
      ),
      sink: sink
    )
    let scopedSnapshot = try await store.snapshot()
    #expect(
      scopedSnapshot.files.first(where: { $0.stableKey == "persistent:file-cafe" })?
        .availability == "missing")
    #expect(
      scopedSnapshot.files.first(where: { $0.stableKey == "persistent:file-cafe" })?
        .missingScanCount == 1)
    #expect(
      scopedSnapshot.files.first(where: {
        $0.stableKey == "persistent:file-foundation-s01e01"
      })?.availability == "present")
  }

  @Test("Full scans persist moves, additions, and completion-authorized missing facts")
  func fullScanPersistence() async throws {
    let fixture = try SQLiteScanFixture()
    defer { fixture.remove() }
    let sourceUID = "sqlite-local-source"
    let database = try await StorageDatabase.open(
      kind: .library,
      at: fixture.databaseURL,
      clock: SQLiteScanClock(now: 1_700_000_000_000)
    )
    let store = try LibraryStore(
      database: database,
      clock: SQLiteScanClock(now: 1_700_000_000_000)
    )
    try await store.registerSource(
      LibrarySourceDefinition(
        uid: sourceUID,
        kind: .localFolder,
        displayName: "Fixture",
        rootURI: "file://local-source"
      )
    )
    let connector = LocalMediaSourceConnector(
      configuration: try LocalMediaSourceConfiguration(
        sourceUID: sourceUID,
        rootURL: fixture.mediaURL,
        pathSemantics: RemotePathSemantics(
          caseSensitivity: .sensitive,
          unicodeNormalization: .preserve
        )
      )
    )
    let scanner = MediaScanner(
      configuration: try MediaScannerConfiguration(
        pageSize: 1,
        maxConcurrentDirectoryRequests: 1
      )
    )
    let sink = SQLiteMediaScanSink(store: store)
    let root = try RemoteLocator(sourceUID: sourceUID, path: RemotePath())

    let firstRequest = try MediaScanRequest(
      runUID: "sqlite-full-1",
      sourceUID: sourceUID,
      mode: .full,
      roots: [root]
    )
    let firstResult = try await scanner.scan(firstRequest, using: connector, sink: sink)
    let firstSnapshot = try await store.snapshot()
    let originalStableKey = try #require(
      firstSnapshot.files.first(where: { $0.relativePath == "Arrival.mkv" })?.stableKey
    )

    #expect(firstResult.completion.reconcileMissingEligible)
    #expect(firstSnapshot.files.map(\.relativePath) == ["Arrival.mkv", "Old.mkv"])
    #expect(firstSnapshot.files.allSatisfy({ $0.availability == "present" }))
    #expect(try await sink.loadCheckpoint(runUID: firstRequest.runUID) == firstResult.checkpoint)

    try FileManager.default.moveItem(
      at: fixture.mediaURL.appendingPathComponent("Arrival.mkv"),
      to: fixture.mediaURL.appendingPathComponent("Arrival Renamed.mkv")
    )
    try FileManager.default.removeItem(at: fixture.mediaURL.appendingPathComponent("Old.mkv"))
    try Data("new".utf8).write(to: fixture.mediaURL.appendingPathComponent("New.mkv"))

    let secondRequest = try MediaScanRequest(
      runUID: "sqlite-full-2",
      sourceUID: sourceUID,
      mode: .full,
      roots: [root]
    )
    _ = try await scanner.scan(secondRequest, using: connector, sink: sink)
    let secondSnapshot = try await store.snapshot()
    let renamed = try #require(
      secondSnapshot.files.first(where: { $0.relativePath == "Arrival Renamed.mkv" })
    )
    let missing = try #require(
      secondSnapshot.files.first(where: { $0.relativePath == "Old.mkv" })
    )

    #expect(secondSnapshot.files.count == 3)
    #expect(renamed.stableKey == originalStableKey)
    #expect(renamed.availability == "present")
    #expect(missing.availability == "missing")
    #expect(missing.missingScanCount == 1)
    #expect(
      secondSnapshot.files.first(where: { $0.relativePath == "New.mkv" })?.availability
        == "present")

    let interruptedRequest = try MediaScanRequest(
      runUID: "sqlite-interrupted-3",
      sourceUID: sourceUID,
      mode: .full,
      roots: [root]
    )
    await #expect(throws: SDKError.self) {
      _ = try await scanner.scan(
        interruptedRequest,
        using: try InterruptingSQLiteConnector(sourceUID: sourceUID),
        sink: sink
      )
    }
    let interruptedSnapshot = try await store.snapshot()
    let storedFailure = try #require(
      try await sink.loadCheckpoint(runUID: interruptedRequest.runUID)
    )

    #expect(storedFailure.phase == .failed)
    #expect(
      interruptedSnapshot.files.first(where: { $0.relativePath == "Arrival Renamed.mkv" })?
        .availability == "present")
    #expect(
      interruptedSnapshot.files.first(where: { $0.relativePath == "New.mkv" })?.availability
        == "present")

    let cancelledRequest = try MediaScanRequest(
      runUID: "sqlite-cancelled-4",
      sourceUID: sourceUID,
      mode: .full,
      roots: [root]
    )
    let blockingConnector = BlockingSQLiteConnector(
      sourceUID: sourceUID,
      capabilities: try MediaSourceCapabilities(
        stableIDScope: .persistent,
        pathSemantics: RemotePathSemantics(
          caseSensitivity: .sensitive,
          unicodeNormalization: .preserve
        ),
        supportsRangeReads: true,
        supportsChangeCursor: false,
        deltaDeletionsComplete: false
      )
    )
    let cancelledTask = Task {
      try await scanner.scan(cancelledRequest, using: blockingConnector, sink: sink)
    }
    await blockingConnector.waitUntilListing()
    cancelledTask.cancel()
    await #expect(throws: SDKError.self) {
      _ = try await cancelledTask.value
    }
    let cancelledCheckpoint = try #require(
      try await sink.loadCheckpoint(runUID: cancelledRequest.runUID)
    )
    let cancelledSnapshot = try await store.snapshot()

    #expect(cancelledCheckpoint.phase == .cancelled)
    #expect(cancelledCheckpoint.lastErrorCode == .cancelled)
    #expect(
      cancelledSnapshot.files.first(where: { $0.relativePath == "Arrival Renamed.mkv" })?
        .availability == "present")
    #expect(
      cancelledSnapshot.files.first(where: { $0.relativePath == "New.mkv" })?.availability
        == "present")
  }

  private var scannerFixtureURL: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("specs/fixtures/media-library/scanner-state-v1.json")
  }
}

private final class SQLiteScanFixture: @unchecked Sendable {
  let rootURL: URL
  let mediaURL: URL
  let databaseURL: URL

  init() throws {
    rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "stellar-sqlite-scan-\(UUID().uuidString)",
      isDirectory: true
    )
    mediaURL = rootURL.appendingPathComponent("Media", isDirectory: true)
    databaseURL = rootURL.appendingPathComponent("library.sqlite")
    try FileManager.default.createDirectory(at: mediaURL, withIntermediateDirectories: true)
    try Data("arrival".utf8).write(to: mediaURL.appendingPathComponent("Arrival.mkv"))
    try Data("old".utf8).write(to: mediaURL.appendingPathComponent("Old.mkv"))
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}

private struct SQLiteScanClock: SDKClock {
  let now: Int64

  func nowMilliseconds() -> Int64 { now }

  func sleep(forMilliseconds _: Int64) async throws {}
}

private struct InterruptingSQLiteConnector: MediaSourceConnector {
  let session: InterruptingSQLiteSession

  init(sourceUID: String) throws {
    session = try InterruptingSQLiteSession(sourceUID: sourceUID)
  }

  func connect() async throws -> any MediaSourceSession { session }
}

private actor InterruptingSQLiteSession: MediaSourceSession {
  nonisolated let sourceUID: String
  nonisolated let capabilities: MediaSourceCapabilities
  private let root: RemoteLocator
  private let entry: RemoteEntry

  init(sourceUID: String) throws {
    self.sourceUID = sourceUID
    capabilities = try MediaSourceCapabilities(
      stableIDScope: .persistent,
      pathSemantics: RemotePathSemantics(
        caseSensitivity: .sensitive,
        unicodeNormalization: .preserve
      ),
      supportsRangeReads: false,
      supportsChangeCursor: false,
      deltaDeletionsComplete: false
    )
    root = try RemoteLocator(sourceUID: sourceUID, path: RemotePath())
    entry = try RemoteEntry(
      locator: RemoteLocator(sourceUID: sourceUID, path: RemotePath("Partial.mkv")),
      kind: .file,
      stableID: "partial-file",
      size: 7
    )
  }

  func listDirectory(_ request: RemoteDirectoryPageRequest) async throws
    -> CursorPage<RemoteEntry>
  {
    guard request.directory == root else {
      throw SDKError(code: .invalidConfiguration, message: "unexpected directory")
    }
    if request.cursor == nil {
      return try CursorPage(items: [entry], nextCursor: "interrupted")
    }
    throw SDKError(code: .networkUnavailable, message: "fixture interruption")
  }

  func stat(_ locator: RemoteLocator) async throws -> RemoteEntry {
    guard locator == root else {
      throw SDKError(code: .metadataNotFound, message: "fixture entry not found")
    }
    return try RemoteEntry(locator: root, kind: .directory, stableID: "root")
  }

  func read(at _: RemoteLocator, range _: RemoteByteRange) async throws -> Data {
    throw SDKError(code: .invalidConfiguration, message: "range read is unsupported")
  }

  func disconnect() async {}
}

private actor BlockingSQLiteConnector: MediaSourceConnector {
  private let session: BlockingSQLiteSession

  init(sourceUID: String, capabilities: MediaSourceCapabilities) {
    session = BlockingSQLiteSession(sourceUID: sourceUID, capabilities: capabilities)
  }

  func connect() async throws -> any MediaSourceSession { session }

  func waitUntilListing() async {
    await session.waitUntilListing()
  }
}

private actor BlockingSQLiteSession: MediaSourceSession {
  nonisolated let sourceUID: String
  nonisolated let capabilities: MediaSourceCapabilities
  private var isListing = false

  init(sourceUID: String, capabilities: MediaSourceCapabilities) {
    self.sourceUID = sourceUID
    self.capabilities = capabilities
  }

  func listDirectory(_: RemoteDirectoryPageRequest) async throws -> CursorPage<RemoteEntry> {
    isListing = true
    try await Task.sleep(for: .seconds(60))
    return try CursorPage(items: [], nextCursor: nil)
  }

  func stat(_ locator: RemoteLocator) async throws -> RemoteEntry {
    try RemoteEntry(locator: locator, kind: .directory, stableID: "fixture-root")
  }

  func read(at _: RemoteLocator, range _: RemoteByteRange) async throws -> Data {
    throw SDKError(code: .metadataNotFound, message: "read is unused by cancellation fixture")
  }

  func disconnect() async {}

  func waitUntilListing() async {
    while !isListing {
      await Task.yield()
    }
  }
}

private struct SQLiteScannerFixture: Decodable {
  let sourceUID: String
  let capabilities: MediaSourceCapabilities
  let scenarios: [SQLiteFixtureScenario]

  private enum CodingKeys: String, CodingKey {
    case sourceUID = "source_uid"
    case capabilities
    case scenarios
  }
}

private struct SQLiteFixtureScenario: Decodable {
  let name: String
  let request: MediaScanRequest
  let pages: [SQLiteFixturePage]
  let expectedLibrarySnapshot: LibrarySnapshot?

  private enum CodingKeys: String, CodingKey {
    case name
    case request
    case pages
    case expectedLibrarySnapshot = "expected_library_snapshot"
  }
}

private struct SQLiteFixturePage: Decodable, Sendable {
  let request: RemoteDirectoryPageRequest
  let response: CursorPage<RemoteEntry>
}

private struct SQLiteFixtureConnector: MediaSourceConnector {
  let sourceUID: String
  let capabilities: MediaSourceCapabilities
  let pages: [SQLiteFixturePage]

  func connect() async throws -> any MediaSourceSession {
    try SQLiteFixtureSession(
      sourceUID: sourceUID,
      capabilities: capabilities,
      pages: pages
    )
  }
}

private actor SQLiteFixtureSession: MediaSourceSession {
  nonisolated let sourceUID: String
  nonisolated let capabilities: MediaSourceCapabilities
  private let pages: [SQLiteFixturePage]
  private let root: RemoteLocator

  init(
    sourceUID: String,
    capabilities: MediaSourceCapabilities,
    pages: [SQLiteFixturePage]
  ) throws {
    self.sourceUID = sourceUID
    self.capabilities = capabilities
    self.pages = pages
    root = try RemoteLocator(sourceUID: sourceUID, path: RemotePath())
  }

  func listDirectory(_ request: RemoteDirectoryPageRequest) async throws
    -> CursorPage<RemoteEntry>
  {
    guard let page = pages.first(where: { $0.request == request }) else {
      throw SDKError(code: .metadataNotFound, message: "fixture page is missing")
    }
    return page.response
  }

  func stat(_ locator: RemoteLocator) async throws -> RemoteEntry {
    let isEnumeratedDirectory =
      locator == root
      || pages.contains(where: { $0.request.directory == locator })
    guard isEnumeratedDirectory else {
      throw SDKError(code: .metadataNotFound, message: "fixture directory is missing")
    }
    return try RemoteEntry(
      locator: locator,
      kind: .directory,
      stableID: locator.path.isRoot ? "root" : "directory:\(locator.path.relativePath)"
    )
  }

  func read(at _: RemoteLocator, range _: RemoteByteRange) async throws -> Data {
    throw SDKError(code: .invalidConfiguration, message: "range read is unsupported")
  }

  func disconnect() async {}
}

import Foundation
import GRDB
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
    let original = try #require(
      secondSnapshot.files.first(where: { $0.relativePath == "Arrival.mkv" })
    )
    let missing = try #require(
      secondSnapshot.files.first(where: { $0.relativePath == "Old.mkv" })
    )

    #expect(secondSnapshot.files.count == 4)
    #expect(renamed.stableKey != originalStableKey)
    #expect(renamed.availability == "present")
    #expect(original.stableKey == originalStableKey)
    #expect(original.availability == "missing")
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

  @Test("Unchanged files stay done while changed and failed files remain actionable")
  func durableScanWorkQueue() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "stellar-sqlite-work-queue-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await StorageDatabase.open(
      kind: .library,
      at: directory.appendingPathComponent("library.sqlite")
    )
    let store = try LibraryStore(database: database)
    let sourceUID = "queue-source"
    try await store.registerSource(
      LibrarySourceDefinition(
        uid: sourceUID,
        kind: .smb,
        displayName: "Queue",
        rootURI: "smb://queue-fixture"
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

    func commit(runUID: String, size: Int64) async throws {
      let entry = try RemoteEntry(
        locator: RemoteLocator(sourceUID: sourceUID, path: RemotePath("Movie.mkv")),
        kind: .file,
        stableID: "movie-file",
        size: size,
        modifiedAtMilliseconds: 1_700_000_000_000
      )
      try await store.commit(
        LibraryScanPersistenceBatch(
          runUID: runUID,
          sourceUID: sourceUID,
          mode: "full",
          state: "completed",
          checkpointJSON: #"{"phase":"completed"}"#,
          coverageJSON: #"{"roots":[""]}"#,
          entries: [entry],
          capabilities: capabilities,
          coveredRoots: [root],
          reconcileMissingEligible: true,
          discoveredEntryCount: 1
        )
      )
    }

    try await commit(runUID: "queue-run-1", size: 100)
    #expect(
      try await store.pendingScanWork(sourceUID: sourceUID, stage: .parse)
        == [try LibraryScanWorkItem(relativePath: "Movie.mkv", attempts: 0)]
    )

    try await store.completeScanWork(
      sourceUID: sourceUID,
      relativePath: "Movie.mkv",
      stage: .parse
    )
    #expect(try await store.pendingScanWork(sourceUID: sourceUID, stage: .parse).isEmpty)

    try await commit(runUID: "queue-run-2", size: 100)
    #expect(try await store.pendingScanWork(sourceUID: sourceUID, stage: .parse).isEmpty)

    try await commit(runUID: "queue-run-3", size: 200)
    #expect(
      try await store.pendingScanWork(sourceUID: sourceUID, stage: .parse)
        == [try LibraryScanWorkItem(relativePath: "Movie.mkv", attempts: 0)]
    )

    try await store.retryScanWork(
      sourceUID: sourceUID,
      relativePath: "Movie.mkv",
      stage: .parse,
      errorCode: .networkUnavailable
    )
    #expect(
      try await store.pendingScanWork(sourceUID: sourceUID, stage: .parse)
        == [try LibraryScanWorkItem(relativePath: "Movie.mkv", attempts: 1)]
    )

    try await store.completeScanWork(
      sourceUID: sourceUID,
      relativePath: "Movie.mkv",
      stage: .parse
    )
    #expect(try await store.pendingScanWork(sourceUID: sourceUID, stage: .parse).isEmpty)
  }

  @Test("Compact checkpoint restores its frontier and replays only unfinished pages")
  func compactCheckpointResume() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "stellar-sqlite-frontier-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await StorageDatabase.open(
      kind: .library,
      at: directory.appendingPathComponent("library.sqlite")
    )
    let store = try LibraryStore(database: database)
    let sourceUID = "frontier-source"
    try await store.registerSource(
      LibrarySourceDefinition(
        uid: sourceUID,
        kind: .smb,
        displayName: "Frontier",
        rootURI: "smb://frontier-fixture"
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
    let request = try MediaScanRequest(
      runUID: "frontier-resume-run",
      sourceUID: sourceUID,
      mode: .full,
      roots: [root]
    )

    await #expect(throws: SDKError.self) {
      _ = try await scanner.scan(
        request,
        using: try InterruptingSQLiteConnector(sourceUID: sourceUID),
        sink: sink
      )
    }
    let checkpoint = try #require(try await sink.loadCheckpoint(runUID: request.runUID))
    let checkpointJSON = try #require(try await store.checkpointJSON(runUID: request.runUID))
    #expect(checkpoint.schemaVersion == 2)
    #expect(checkpoint.pendingPageCount == 1)
    #expect(checkpoint.processedPageCount == 1)
    #expect(checkpoint.discoveredEntryCount == 1)
    #expect(checkpointJSON.utf8.count < 2_048)
    #expect(!checkpointJSON.contains("seen_entry_identity_keys"))
    #expect(!checkpointJSON.contains("completed_pages"))
    let durableCounts = try await database.read { database in
      (
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM scan_frontier WHERE state = 'pending'"
        ) ?? 0,
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM scan_frontier WHERE state = 'completed'"
        ) ?? 0,
        try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM scan_seen") ?? 0
      )
    }
    #expect(durableCounts.0 == 1)
    #expect(durableCounts.1 == 1)
    #expect(durableCounts.2 == 1)

    let result = try await scanner.scan(
      request,
      using: try ResumingSQLiteConnector(sourceUID: sourceUID),
      sink: sink,
      resumeFrom: checkpoint
    )
    #expect(result.checkpoint.phase == .completed)
    #expect(result.checkpoint.pendingPageCount == 0)
    #expect(result.checkpoint.processedPageCount == 2)
    #expect(result.checkpoint.discoveredEntryCount == 2)
    #expect(
      try await store.snapshot().files.map(\.relativePath) == ["Partial.mkv", "Recovered.mkv"])
    let retainedRunState = try await database.read { database in
      (
        try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM scan_frontier") ?? 0,
        try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM scan_seen") ?? 0
      )
    }
    #expect(retainedRunState.0 == 0)
    #expect(retainedRunState.1 == 0)
  }

  @Test("Pending scan work joins file facts and paginates without a full snapshot")
  func pagedScanFileWork() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "stellar-sqlite-paged-work-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await StorageDatabase.open(
      kind: .library,
      at: directory.appendingPathComponent("library.sqlite")
    )
    let store = try LibraryStore(database: database)
    let sourceUID = "paged-work-source"
    try await store.registerSource(
      LibrarySourceDefinition(
        uid: sourceUID,
        kind: .smb,
        displayName: "Paged Work",
        rootURI: "smb://paged-work-fixture"
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
    let entries = try ["Zulu.mkv", "Alpha.mkv", "Middle.mkv"].enumerated().map {
      index, path in
      try RemoteEntry(
        locator: RemoteLocator(sourceUID: sourceUID, path: RemotePath(path)),
        kind: .file,
        stableID: "paged-file-\(index)",
        size: Int64(index + 1)
      )
    }
    try await store.commit(
      LibraryScanPersistenceBatch(
        runUID: "paged-work-run",
        sourceUID: sourceUID,
        mode: "full",
        state: "completed",
        checkpointJSON: #"{"phase":"completed"}"#,
        coverageJSON: #"{"roots":[""]}"#,
        entries: entries,
        capabilities: capabilities,
        coveredRoots: [RemoteLocator(sourceUID: sourceUID, path: RemotePath())],
        reconcileMissingEligible: true,
        discoveredEntryCount: Int64(entries.count)
      )
    )

    let summary = try await store.sourceMediaSummary(sourceUID: sourceUID)
    #expect(summary.presentFileCount == 3)
    #expect(summary.matchedFileCount == 0)
    let first = try await store.pendingScanFileWorkPage(
      sourceUID: sourceUID,
      stage: .parse,
      pageSize: 2
    )
    #expect(first.items.map(\.file.relativePath) == ["Alpha.mkv", "Middle.mkv"])
    #expect(first.items.map(\.file.sizeBytes) == [2, 3])
    #expect(first.items.allSatisfy({ !$0.hasMatchingBinding && $0.attempts == 0 }))
    let cursor = try #require(first.nextCursor)
    let second = try await store.pendingScanFileWorkPage(
      sourceUID: sourceUID,
      stage: .parse,
      pageSize: 2,
      cursor: cursor
    )
    #expect(second.items.map(\.file.relativePath) == ["Zulu.mkv"])
    #expect(second.nextCursor == nil)
    await #expect(throws: SDKError.self) {
      try await store.pendingScanFileWorkPage(
        sourceUID: sourceUID,
        stage: .artwork,
        pageSize: 2,
        cursor: cursor
      )
    }
  }

  @Test("Unchanged scans advance observation without rewriting material timestamps")
  func unchangedObservationFastPath() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "stellar-sqlite-unchanged-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await StorageDatabase.open(
      kind: .library,
      at: directory.appendingPathComponent("library.sqlite")
    )
    let sourceUID = "unchanged-source"
    let firstStore = try LibraryStore(
      database: database,
      clock: SQLiteScanClock(now: 100)
    )
    try await firstStore.registerSource(
      LibrarySourceDefinition(
        uid: sourceUID,
        kind: .smb,
        displayName: "Unchanged",
        rootURI: "smb://unchanged-fixture"
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
    let entry = try RemoteEntry(
      locator: RemoteLocator(sourceUID: sourceUID, path: RemotePath("Movie.mkv")),
      kind: .file,
      stableID: "movie-file",
      size: 100,
      modifiedAtMilliseconds: 50
    )

    func commit(_ store: LibraryStore, runUID: String) async throws {
      try await store.commit(
        LibraryScanPersistenceBatch(
          runUID: runUID,
          sourceUID: sourceUID,
          mode: "full",
          state: "completed",
          checkpointJSON: #"{"phase":"completed"}"#,
          coverageJSON: #"{"roots":[""]}"#,
          entries: [entry],
          capabilities: capabilities,
          coveredRoots: [root],
          reconcileMissingEligible: true,
          discoveredEntryCount: 1
        )
      )
    }

    try await commit(firstStore, runUID: "unchanged-run-1")
    try await firstStore.completeScanWork(
      sourceUID: sourceUID,
      relativePath: "Movie.mkv",
      stage: .parse
    )
    let secondStore = try LibraryStore(
      database: database,
      clock: SQLiteScanClock(now: 200)
    )
    try await commit(secondStore, runUID: "unchanged-run-2")

    let materialUpdatedAt = try await database.read { database in
      try Int64.fetchOne(
        database,
        sql: """
          SELECT file.updated_at_ms
          FROM media_file AS file
          WHERE file.stable_key = 'persistent:movie-file'
          """
      )
    }
    let observedRunUID = try await database.read { database in
      try String.fetchOne(
        database,
        sql: """
          SELECT run.uid
          FROM media_file AS file
          JOIN scan_run AS run ON run.id = file.last_seen_run_id
          WHERE file.stable_key = 'persistent:movie-file'
          """
      )
    }
    #expect(materialUpdatedAt == 100)
    #expect(observedRunUID == "unchanged-run-2")
    let secondChangedCount = try await database.read { database in
      try Int.fetchOne(
        database,
        sql: "SELECT changed_count FROM scan_run WHERE uid = 'unchanged-run-2'"
      )
    }
    #expect(secondChangedCount == 0)
    #expect(try await secondStore.pendingScanWork(sourceUID: sourceUID, stage: .parse).isEmpty)
  }

  @Test("Set-based scoped missing treats path punctuation literally")
  func setBasedScopedMissing() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "stellar-sqlite-scope-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await StorageDatabase.open(
      kind: .library,
      at: directory.appendingPathComponent("library.sqlite")
    )
    let store = try LibraryStore(database: database)
    let sourceUID = "scope-source"
    try await store.registerSource(
      LibrarySourceDefinition(
        uid: sourceUID,
        kind: .smb,
        displayName: "Scope",
        rootURI: "smb://scope-fixture"
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
    let scopedRoot = try RemoteLocator(
      sourceUID: sourceUID,
      path: RemotePath("Scoped_100%")
    )
    let paths = [
      "Scoped_100%/Missing.mkv",
      "Scoped_100%/Present.mkv",
      "Scoped_100%Extra/Outside.mkv",
      "ScopedX100%/Outside.mkv",
    ]
    let entries = try paths.enumerated().map { index, path in
      try RemoteEntry(
        locator: RemoteLocator(sourceUID: sourceUID, path: RemotePath(path)),
        kind: .file,
        stableID: "scope-file-\(index)",
        size: Int64(index)
      )
    }
    try await store.commit(
      LibraryScanPersistenceBatch(
        runUID: "scope-run-1",
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
    )
    try await store.commit(
      LibraryScanPersistenceBatch(
        runUID: "scope-run-2",
        sourceUID: sourceUID,
        mode: "incremental",
        state: "completed",
        checkpointJSON: #"{"phase":"completed"}"#,
        coverageJSON: #"{"roots":["Scoped_100%"]}"#,
        entries: [entries[1]],
        capabilities: capabilities,
        coveredRoots: [scopedRoot],
        reconcileMissingEligible: true,
        discoveredEntryCount: 1
      )
    )

    let snapshot = try await store.snapshot()
    #expect(
      snapshot.files.first(where: { $0.relativePath == paths[0] })?.availability == "missing"
    )
    #expect(
      snapshot.files.filter { $0.relativePath != paths[0] }
        .allSatisfy { $0.availability == "present" }
    )
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

private struct ResumingSQLiteConnector: MediaSourceConnector {
  let session: ResumingSQLiteSession

  init(sourceUID: String) throws {
    session = try ResumingSQLiteSession(sourceUID: sourceUID)
  }

  func connect() async throws -> any MediaSourceSession { session }
}

private actor ResumingSQLiteSession: MediaSourceSession {
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
      locator: RemoteLocator(sourceUID: sourceUID, path: RemotePath("Recovered.mkv")),
      kind: .file,
      stableID: "recovered-file",
      size: 9
    )
  }

  func listDirectory(_ request: RemoteDirectoryPageRequest) async throws
    -> CursorPage<RemoteEntry>
  {
    guard request.directory == root, request.cursor == "interrupted" else {
      throw SDKError(code: .invalidConfiguration, message: "finished page was replayed")
    }
    return try CursorPage(items: [entry], nextCursor: nil)
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

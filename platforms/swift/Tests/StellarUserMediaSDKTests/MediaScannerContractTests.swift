import Foundation
import StellarCore
import StellarMediaLibrary
import StellarRemoteMedia
import Testing

@Suite("Media scanner contracts")
struct MediaScannerContractTests {
  @Test("Shared fixture covers full, scoped incremental, and repair modes")
  func sharedScannerFixture() async throws {
    let fixture = try loadFixture()
    let scanner = MediaScanner(
      configuration: try MediaScannerConfiguration(
        pageSize: 2,
        maxConcurrentDirectoryRequests: 2
      )
    )

    #expect(fixture.schemaVersion == 1)
    #expect(
      fixture.scenarios.map(\.name) == [
        "full_success",
        "interrupted_page",
        "scoped_incremental",
        "repair_without_enumeration",
      ])

    for scenario in fixture.scenarios where scenario.failureRequest == nil {
      let sink = RecordingScanSink()
      let observer = RecordingScanObserver()
      let connector = FixtureScanConnector(
        sourceUID: fixture.sourceUID,
        capabilities: fixture.capabilities,
        pages: scenario.pages,
        failureRequest: nil
      )
      let result = try await scanner.scan(
        scenario.request,
        using: connector,
        sink: sink,
        observer: observer
      )

      #expect(result.checkpoint.phase == scenario.expected.phase)
      #expect(
        result.completion.reconcileMissingEligible
          == scenario.expected.reconcileMissingEligible
      )
      #expect(result.checkpoint.discoveredEntryCount == scenario.expected.discoveredEntryCount)
      #expect(result.checkpoint.processedPageCount == scenario.expected.processedPageCount)
      #expect(await sink.entryIdentityKeys == scenario.expected.entryIdentityKeys)
      #expect(await sink.completion == result.completion)
      #expect(await observer.kinds.first == .started)
      #expect(await observer.kinds.last == .completed)

      let encodedCheckpoint = try JSONEncoder().encode(result.checkpoint)
      #expect(
        try JSONDecoder().decode(MediaScanCheckpoint.self, from: encodedCheckpoint)
          == result.checkpoint
      )

      if scenario.request.mode == .repair {
        #expect(await connector.connectionCount == 0)
      } else {
        #expect(await connector.connectionCount == 1)
      }

      if scenario.name == "full_success" {
        let reorderedPages = try scenario.pages.reversed().map { page in
          FixtureScanPage(
            request: page.request,
            response: try CursorPage(
              items: page.response.items.reversed(),
              nextCursor: page.response.nextCursor
            )
          )
        }
        let reorderedSink = RecordingScanSink()
        let reorderedConnector = FixtureScanConnector(
          sourceUID: fixture.sourceUID,
          capabilities: fixture.capabilities,
          pages: reorderedPages,
          failureRequest: nil
        )
        _ = try await scanner.scan(
          scenario.request,
          using: reorderedConnector,
          sink: reorderedSink
        )
        #expect(await reorderedSink.entryIdentityKeys == scenario.expected.entryIdentityKeys)
      }
    }
  }

  @Test("Interrupted pagination keeps its checkpoint and cannot reconcile missing")
  func interruptedPaginationAndResume() async throws {
    let fixture = try loadFixture()
    let scenario = try #require(
      fixture.scenarios.first(where: { $0.name == "interrupted_page" })
    )
    let scanner = MediaScanner(
      configuration: try MediaScannerConfiguration(
        pageSize: 2,
        maxConcurrentDirectoryRequests: 1
      )
    )
    let sink = RecordingScanSink()
    let failingConnector = FixtureScanConnector(
      sourceUID: fixture.sourceUID,
      capabilities: fixture.capabilities,
      pages: scenario.pages,
      failureRequest: scenario.failureRequest
    )

    await #expect(throws: SDKError.self) {
      _ = try await scanner.scan(scenario.request, using: failingConnector, sink: sink)
    }

    let failedCheckpoint = try #require(await sink.checkpoint)
    #expect(failedCheckpoint.phase == scenario.expected.phase)
    #expect(failedCheckpoint.lastErrorCode == .remoteUnavailable)
    #expect(failedCheckpoint.discoveredEntryCount == scenario.expected.discoveredEntryCount)
    #expect(failedCheckpoint.processedPageCount == scenario.expected.processedPageCount)
    #expect(await sink.completion == nil)
    #expect(await sink.entryIdentityKeys == scenario.expected.entryIdentityKeys)

    let resumedConnector = FixtureScanConnector(
      sourceUID: fixture.sourceUID,
      capabilities: fixture.capabilities,
      pages: scenario.pages,
      failureRequest: nil
    )
    let resumed = try await scanner.scan(
      scenario.request,
      using: resumedConnector,
      sink: sink,
      resumeFrom: failedCheckpoint
    )

    #expect(resumed.checkpoint.phase == .completed)
    #expect(resumed.completion.reconcileMissingEligible)
    #expect(resumed.checkpoint.discoveredEntryCount == 2)
    #expect(resumed.checkpoint.processedPageCount == 3)
    #expect(
      await sink.entryIdentityKeys == [
        "stable:directory-movies",
        "stable:file-arrival",
      ])
  }

  @Test("Duplicate entries are idempotent and repeated cursors fail closed")
  func duplicateAndCursorSafety() async throws {
    let fixture = try loadFixture()
    let root = try RemoteLocator(sourceUID: fixture.sourceUID, path: RemotePath())
    let movie = try RemoteEntry(
      locator: RemoteLocator(
        sourceUID: fixture.sourceUID,
        path: RemotePath("Arrival.mkv")
      ),
      kind: .file,
      stableID: "file-arrival",
      size: 7
    )
    let initialRequest = try RemoteDirectoryPageRequest(directory: root, limit: 2)
    let repeatedRequest = try RemoteDirectoryPageRequest(
      directory: root,
      cursor: "repeat",
      limit: 2
    )
    let pages = [
      FixtureScanPage(
        request: initialRequest,
        response: try CursorPage(items: [movie, movie], nextCursor: "repeat")
      ),
      FixtureScanPage(
        request: repeatedRequest,
        response: try CursorPage(items: [], nextCursor: "repeat")
      ),
    ]
    let request = try MediaScanRequest(
      runUID: "scan-repeated-cursor",
      sourceUID: fixture.sourceUID,
      mode: .full,
      roots: [root]
    )
    let sink = RecordingScanSink()
    let connector = FixtureScanConnector(
      sourceUID: fixture.sourceUID,
      capabilities: fixture.capabilities,
      pages: pages,
      failureRequest: nil
    )
    let scanner = MediaScanner(
      configuration: try MediaScannerConfiguration(
        pageSize: 2,
        maxConcurrentDirectoryRequests: 1
      )
    )

    await #expect(throws: SDKError.self) {
      _ = try await scanner.scan(request, using: connector, sink: sink)
    }

    let checkpoint = try #require(await sink.checkpoint)
    #expect(checkpoint.phase == .failed)
    #expect(checkpoint.lastErrorCode == .parseFailure)
    #expect(checkpoint.discoveredEntryCount == 1)
    #expect(checkpoint.processedPageCount == 1)
    #expect(await sink.entryIdentityKeys == ["stable:file-arrival"])
    #expect(await sink.completion == nil)
  }

  @Test("Entries outside the requested directory fail without a completion batch")
  func abnormalPathFailsClosed() async throws {
    let fixture = try loadFixture()
    let root = try RemoteLocator(sourceUID: fixture.sourceUID, path: RemotePath())
    let abnormal = try RemoteEntry(
      locator: RemoteLocator(
        sourceUID: fixture.sourceUID,
        path: RemotePath("Movies/Nested.mkv")
      ),
      kind: .file,
      stableID: "file-nested"
    )
    let page = FixtureScanPage(
      request: try RemoteDirectoryPageRequest(directory: root, limit: 2),
      response: try CursorPage(items: [abnormal], nextCursor: nil)
    )
    let request = try MediaScanRequest(
      runUID: "scan-abnormal-path",
      sourceUID: fixture.sourceUID,
      mode: .full,
      roots: [root]
    )
    let sink = RecordingScanSink()
    let connector = FixtureScanConnector(
      sourceUID: fixture.sourceUID,
      capabilities: fixture.capabilities,
      pages: [page],
      failureRequest: nil
    )
    let scanner = MediaScanner(
      configuration: try MediaScannerConfiguration(
        pageSize: 2,
        maxConcurrentDirectoryRequests: 1
      )
    )

    await #expect(throws: SDKError.self) {
      _ = try await scanner.scan(request, using: connector, sink: sink)
    }

    #expect(await sink.checkpoint?.phase == .failed)
    #expect(await sink.checkpoint?.processedPageCount == 0)
    #expect(await sink.entryIdentityKeys.isEmpty)
    #expect(await sink.completion == nil)
  }

  @Test("Cancellation persists resumable state and never produces completion")
  func cancellation() async throws {
    let fixture = try loadFixture()
    let scenario = try #require(
      fixture.scenarios.first(where: { $0.name == "full_success" })
    )
    let sink = RecordingScanSink()
    let connector = BlockingScanConnector(
      sourceUID: fixture.sourceUID,
      capabilities: fixture.capabilities
    )
    let scanner = MediaScanner(
      configuration: try MediaScannerConfiguration(
        pageSize: 2,
        maxConcurrentDirectoryRequests: 1
      )
    )
    let task = Task {
      try await scanner.scan(scenario.request, using: connector, sink: sink)
    }

    await connector.waitUntilListing()
    task.cancel()
    await #expect(throws: SDKError.self) {
      _ = try await task.value
    }

    #expect(await sink.checkpoint?.phase == .cancelled)
    #expect(await sink.checkpoint?.lastErrorCode == .cancelled)
    #expect(await sink.completion == nil)
  }

  @Test("Persistent IDs preserve moves and failed scans cannot coordinate deletions")
  func movesAndDeletionSafety() async throws {
    let fixture = try loadFixture()
    let root = try RemoteLocator(sourceUID: fixture.sourceUID, path: RemotePath())
    let original = try RemoteEntry(
      locator: RemoteLocator(sourceUID: fixture.sourceUID, path: RemotePath("Original.mkv")),
      kind: .file,
      stableID: "file-moved"
    )
    let laterDeleted = try RemoteEntry(
      locator: RemoteLocator(sourceUID: fixture.sourceUID, path: RemotePath("Deleted.mkv")),
      kind: .file,
      stableID: "file-deleted"
    )
    let moved = try RemoteEntry(
      locator: RemoteLocator(sourceUID: fixture.sourceUID, path: RemotePath("Moved.mkv")),
      kind: .file,
      stableID: "file-moved"
    )
    let firstPageRequest = try RemoteDirectoryPageRequest(directory: root, limit: 2)
    let secondPageRequest = try RemoteDirectoryPageRequest(
      directory: root,
      cursor: "root-page-2",
      limit: 2
    )
    let scanner = MediaScanner(
      configuration: try MediaScannerConfiguration(
        pageSize: 2,
        maxConcurrentDirectoryRequests: 1
      )
    )
    let sink = ReconcilingScanSink(semantics: fixture.capabilities.pathSemantics)
    let firstRequest = try MediaScanRequest(
      runUID: "scan-move-generation-1",
      sourceUID: fixture.sourceUID,
      mode: .full,
      roots: [root]
    )
    let firstConnector = FixtureScanConnector(
      sourceUID: fixture.sourceUID,
      capabilities: fixture.capabilities,
      pages: [
        FixtureScanPage(
          request: firstPageRequest,
          response: try CursorPage(items: [original, laterDeleted], nextCursor: nil)
        )
      ],
      failureRequest: nil
    )
    _ = try await scanner.scan(firstRequest, using: firstConnector, sink: sink)

    #expect(await sink.path(for: "file-moved") == "Original.mkv")
    #expect(await sink.isPresent("file-deleted"))

    let secondRequest = try MediaScanRequest(
      runUID: "scan-move-generation-2",
      sourceUID: fixture.sourceUID,
      mode: .full,
      roots: [root]
    )
    let secondPages = [
      FixtureScanPage(
        request: firstPageRequest,
        response: try CursorPage(items: [moved], nextCursor: "root-page-2")
      ),
      FixtureScanPage(
        request: secondPageRequest,
        response: try CursorPage(items: [], nextCursor: nil)
      ),
    ]
    let interruptedConnector = FixtureScanConnector(
      sourceUID: fixture.sourceUID,
      capabilities: fixture.capabilities,
      pages: secondPages,
      failureRequest: secondPageRequest
    )
    await #expect(throws: SDKError.self) {
      _ = try await scanner.scan(secondRequest, using: interruptedConnector, sink: sink)
    }

    #expect(await sink.path(for: "file-moved") == "Moved.mkv")
    #expect(await sink.isPresent("file-deleted"))

    let interruptedCheckpoint = try #require(await sink.checkpoint)
    let resumedConnector = FixtureScanConnector(
      sourceUID: fixture.sourceUID,
      capabilities: fixture.capabilities,
      pages: secondPages,
      failureRequest: nil
    )
    _ = try await scanner.scan(
      secondRequest,
      using: resumedConnector,
      sink: sink,
      resumeFrom: interruptedCheckpoint
    )

    #expect(await sink.path(for: "file-moved") == "Moved.mkv")
    #expect(await sink.isPresent("file-moved"))
    #expect(await sink.isPresent("file-deleted") == false)
  }

  @Test("Directory requests respect the configured concurrency bound")
  func boundedConcurrency() async throws {
    let fixture = try loadFixture()
    let root = try RemoteLocator(sourceUID: fixture.sourceUID, path: RemotePath())
    let directories = try (1...4).map { index in
      try RemoteEntry(
        locator: RemoteLocator(
          sourceUID: fixture.sourceUID,
          path: RemotePath("Directory-\(index)")
        ),
        kind: .directory,
        stableID: "directory-\(index)"
      )
    }
    var pages: [RemoteDirectoryPageRequest: CursorPage<RemoteEntry>] = [
      try RemoteDirectoryPageRequest(directory: root, limit: 10):
        try CursorPage(items: directories, nextCursor: nil)
    ]
    for directory in directories {
      pages[try RemoteDirectoryPageRequest(directory: directory.locator, limit: 10)] =
        try CursorPage(items: [], nextCursor: nil)
    }
    let tracker = ConcurrencyTracker()
    let connector = DelayedScanConnector(
      sourceUID: fixture.sourceUID,
      capabilities: fixture.capabilities,
      pages: pages,
      tracker: tracker
    )
    let request = try MediaScanRequest(
      runUID: "scan-bounded-concurrency",
      sourceUID: fixture.sourceUID,
      mode: .full,
      roots: [root]
    )
    let scanner = MediaScanner(
      configuration: try MediaScannerConfiguration(
        pageSize: 10,
        maxConcurrentDirectoryRequests: 2
      )
    )

    let result = try await scanner.scan(request, using: connector, sink: RecordingScanSink())

    #expect(result.checkpoint.processedPageCount == 5)
    #expect(await tracker.maximumActive == 2)
    #expect(await tracker.active == 0)

    let serialCapabilities = try MediaSourceCapabilities(
      stableIDScope: fixture.capabilities.stableIDScope,
      pathSemantics: fixture.capabilities.pathSemantics,
      supportsRangeReads: fixture.capabilities.supportsRangeReads,
      supportsChangeCursor: fixture.capabilities.supportsChangeCursor,
      deltaDeletionsComplete: fixture.capabilities.deltaDeletionsComplete,
      preferredDirectoryRequestConcurrency: 1
    )
    let serialTracker = ConcurrencyTracker()
    let serialConnector = DelayedScanConnector(
      sourceUID: fixture.sourceUID,
      capabilities: serialCapabilities,
      pages: pages,
      tracker: serialTracker
    )
    let serialRequest = try MediaScanRequest(
      runUID: "scan-source-limited-concurrency",
      sourceUID: fixture.sourceUID,
      mode: .full,
      roots: [root]
    )
    let permissiveScanner = MediaScanner(
      configuration: try MediaScannerConfiguration(
        pageSize: 10,
        maxConcurrentDirectoryRequests: 4
      )
    )

    _ = try await permissiveScanner.scan(
      serialRequest,
      using: serialConnector,
      sink: RecordingScanSink()
    )

    #expect(await serialTracker.maximumActive == 1)
    #expect(await serialTracker.active == 0)
  }

  @Test("Coverage overlap and changed root identity fail before enumeration")
  func preflightSafety() async throws {
    let fixture = try loadFixture()
    let root = try RemoteLocator(sourceUID: fixture.sourceUID, path: RemotePath())
    #expect(throws: SDKError.self) {
      _ = try MediaScanRequest(
        runUID: "invalid-full-scope",
        sourceUID: fixture.sourceUID,
        mode: .full,
        roots: [
          RemoteLocator(sourceUID: fixture.sourceUID, path: RemotePath("Movies"))
        ]
      )
    }

    let overlapping = try MediaScanRequest(
      runUID: "overlapping-incremental",
      sourceUID: fixture.sourceUID,
      mode: .incremental,
      roots: [
        RemoteLocator(sourceUID: fixture.sourceUID, path: RemotePath("Movies")),
        RemoteLocator(sourceUID: fixture.sourceUID, path: RemotePath("movies/Children")),
      ]
    )
    let overlappingSink = RecordingScanSink()
    let overlappingConnector = FixtureScanConnector(
      sourceUID: fixture.sourceUID,
      capabilities: fixture.capabilities,
      pages: [],
      failureRequest: nil
    )
    await #expect(throws: SDKError.self) {
      _ = try await MediaScanner().scan(
        overlapping,
        using: overlappingConnector,
        sink: overlappingSink
      )
    }
    #expect(await overlappingSink.checkpoint?.phase == .failed)
    #expect(await overlappingSink.completion == nil)

    let scenario = try #require(
      fixture.scenarios.first(where: { $0.name == "interrupted_page" })
    )
    let scanner = MediaScanner(
      configuration: try MediaScannerConfiguration(
        pageSize: 2,
        maxConcurrentDirectoryRequests: 1
      )
    )
    let sink = RecordingScanSink()
    let interruptedConnector = FixtureScanConnector(
      sourceUID: fixture.sourceUID,
      capabilities: fixture.capabilities,
      pages: scenario.pages,
      failureRequest: scenario.failureRequest
    )
    await #expect(throws: SDKError.self) {
      _ = try await scanner.scan(scenario.request, using: interruptedConnector, sink: sink)
    }
    let checkpoint = try #require(await sink.checkpoint)
    #expect(checkpoint.rootIdentities.first?.locator == root)
    #expect(checkpoint.rootIdentities.first?.stableID == "fixture-root")

    let replacedRootConnector = FixtureScanConnector(
      sourceUID: fixture.sourceUID,
      capabilities: fixture.capabilities,
      pages: scenario.pages,
      failureRequest: nil,
      rootStableID: "replacement-root"
    )
    await #expect(throws: SDKError.self) {
      _ = try await scanner.scan(
        scenario.request,
        using: replacedRootConnector,
        sink: sink,
        resumeFrom: checkpoint
      )
    }
    #expect(await sink.checkpoint?.phase == .failed)
    #expect(await sink.checkpoint?.lastErrorCode == .conflict)
    #expect(await sink.completion == nil)
  }

  @Test("A failed page commit retains the last durable checkpoint for replay")
  func pageCommitFailure() async throws {
    let fixture = try loadFixture()
    let scenario = try #require(
      fixture.scenarios.first(where: { $0.name == "scoped_incremental" })
    )
    let scanner = MediaScanner(
      configuration: try MediaScannerConfiguration(
        pageSize: 2,
        maxConcurrentDirectoryRequests: 1
      )
    )
    let sink = FailingPageScanSink()
    let connector = FixtureScanConnector(
      sourceUID: fixture.sourceUID,
      capabilities: fixture.capabilities,
      pages: scenario.pages,
      failureRequest: nil
    )

    await #expect(throws: SDKError.self) {
      _ = try await scanner.scan(scenario.request, using: connector, sink: sink)
    }
    let failedCheckpoint = try #require(await sink.checkpoint)
    #expect(failedCheckpoint.phase == .failed)
    #expect(failedCheckpoint.lastErrorCode == .storageFailure)
    #expect(failedCheckpoint.processedPageCount == 0)
    #expect(failedCheckpoint.discoveredEntryCount == 0)
    #expect(await sink.entryIdentityKeys.isEmpty)
    #expect(await sink.completion == nil)

    let resumedConnector = FixtureScanConnector(
      sourceUID: fixture.sourceUID,
      capabilities: fixture.capabilities,
      pages: scenario.pages,
      failureRequest: nil
    )
    let result = try await scanner.scan(
      scenario.request,
      using: resumedConnector,
      sink: sink,
      resumeFrom: failedCheckpoint
    )
    #expect(result.checkpoint.phase == .completed)
    #expect(result.checkpoint.processedPageCount == 1)
    #expect(await sink.entryIdentityKeys == ["stable:file-arrival"])
    #expect(await sink.completion == result.completion)
  }

  private func loadFixture() throws -> ScannerFixture {
    try JSONDecoder().decode(
      ScannerFixture.self,
      from: Data(contentsOf: sharedFixtureURL)
    )
  }

  private var sharedFixtureURL: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("specs/fixtures/media-library/scanner-state-v1.json")
  }
}

private struct ScannerFixture: Decodable, Sendable {
  let schemaVersion: Int
  let sourceUID: String
  let capabilities: MediaSourceCapabilities
  let scenarios: [ScannerScenario]

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case sourceUID = "source_uid"
    case capabilities
    case scenarios
  }
}

private struct ScannerScenario: Decodable, Sendable {
  let name: String
  let request: MediaScanRequest
  let pages: [FixtureScanPage]
  let failureRequest: RemoteDirectoryPageRequest?
  let expected: ScannerExpected

  private enum CodingKeys: String, CodingKey {
    case name
    case request
    case pages
    case failureRequest = "failure_request"
    case expected
  }
}

private struct FixtureScanPage: Codable, Sendable {
  let request: RemoteDirectoryPageRequest
  let response: CursorPage<RemoteEntry>
}

private struct ScannerExpected: Decodable, Sendable {
  let phase: MediaScanPhase
  let reconcileMissingEligible: Bool
  let discoveredEntryCount: Int64
  let processedPageCount: Int64
  let entryIdentityKeys: [String]

  private enum CodingKeys: String, CodingKey {
    case phase
    case reconcileMissingEligible = "reconcile_missing_eligible"
    case discoveredEntryCount = "discovered_entry_count"
    case processedPageCount = "processed_page_count"
    case entryIdentityKeys = "entry_identity_keys"
  }
}

private actor RecordingScanSink: MediaScanSink {
  private(set) var checkpoint: MediaScanCheckpoint?
  private(set) var completion: MediaScanCompletion?
  private var entries: [String: RemoteEntry] = [:]
  private var enumerationState: MediaScanEnumerationState?

  var entryIdentityKeys: [String] { entries.keys.sorted() }

  func commit(_ batch: MediaScanBatch) async throws {
    enumerationState = try applyingEnumerationChanges(from: batch, to: enumerationState)
    for entry in batch.entries {
      let identity =
        entry.stableID.map { "stable:\($0)" }
        ?? "path:\(entry.locator.path.relativePath)"
      entries[identity] = entry
    }
    checkpoint = batch.checkpoint
    if let completion = batch.completion {
      self.completion = completion
    }
  }

  func loadEnumerationState(runUID _: String) async throws -> MediaScanEnumerationState? {
    enumerationState
  }
}

private actor RecordingScanObserver: MediaScanObserver {
  private var events: [MediaScanEvent] = []

  var kinds: [MediaScanEventKind] { events.map(\.kind) }

  func emit(_ event: MediaScanEvent) async {
    events.append(event)
  }
}

private actor FailingPageScanSink: MediaScanSink {
  private var shouldFailPageCommit = true
  private var entries: [String: RemoteEntry] = [:]
  private(set) var checkpoint: MediaScanCheckpoint?
  private(set) var completion: MediaScanCompletion?
  private var enumerationState: MediaScanEnumerationState?

  var entryIdentityKeys: [String] { entries.keys.sorted() }

  func commit(_ batch: MediaScanBatch) async throws {
    if shouldFailPageCommit, !batch.entries.isEmpty {
      shouldFailPageCommit = false
      throw SDKError(code: .storageFailure, message: "injected page commit failure")
    }
    enumerationState = try applyingEnumerationChanges(from: batch, to: enumerationState)
    for entry in batch.entries {
      entries[entry.stableID.map { "stable:\($0)" } ?? entry.locator.path.relativePath] = entry
    }
    checkpoint = batch.checkpoint
    if let completion = batch.completion {
      self.completion = completion
    }
  }

  func loadEnumerationState(runUID _: String) async throws -> MediaScanEnumerationState? {
    enumerationState
  }
}

private actor ReconcilingScanSink: MediaScanSink {
  private struct Record: Sendable {
    var entry: RemoteEntry
    var lastSeenRunUID: String
    var isPresent: Bool
  }

  private let semantics: RemotePathSemantics
  private var records: [String: Record] = [:]
  private(set) var checkpoint: MediaScanCheckpoint?
  private var enumerationState: MediaScanEnumerationState?

  init(semantics: RemotePathSemantics) {
    self.semantics = semantics
  }

  func commit(_ batch: MediaScanBatch) async throws {
    enumerationState = try applyingEnumerationChanges(from: batch, to: enumerationState)
    for entry in batch.entries {
      let identity = entry.stableID ?? entry.locator.pathComparisonKey(using: semantics)
      records[identity] = Record(
        entry: entry,
        lastSeenRunUID: batch.checkpoint.request.runUID,
        isPresent: true
      )
    }
    checkpoint = batch.checkpoint

    guard let completion = batch.completion, completion.reconcileMissingEligible else { return }
    for (identity, var record) in records {
      let isCovered = completion.coveredRoots.contains { root in
        record.entry.locator.path == root.path
          || record.entry.locator.path.isDescendant(of: root.path, using: semantics)
      }
      if isCovered, record.lastSeenRunUID != completion.runUID {
        record.isPresent = false
        records[identity] = record
      }
    }
  }

  func loadEnumerationState(runUID _: String) async throws -> MediaScanEnumerationState? {
    enumerationState
  }

  func path(for stableID: String) -> String? {
    records[stableID]?.entry.locator.path.relativePath
  }

  func isPresent(_ stableID: String) -> Bool {
    records[stableID]?.isPresent ?? false
  }
}

private func applyingEnumerationChanges(
  from batch: MediaScanBatch,
  to existing: MediaScanEnumerationState?
) throws -> MediaScanEnumerationState? {
  if let replacement = batch.enumerationState { return replacement }
  guard let transition = batch.pageTransition, let existing else { return existing }
  var pending = Set(existing.pendingPages)
  var completed = Set(existing.completedPages)
  guard pending.remove(transition.completedPage) != nil else {
    throw SDKError(code: .storageFailure, message: "fixture scan frontier is stale")
  }
  completed.insert(transition.completedPage)
  pending.formUnion(transition.enqueuedPages.filter { !completed.contains($0) })
  let seenEntries = Set(existing.seenEntryIdentityKeys)
    .union(transition.seenEntryIdentityKeys)
  let seenDirectories = Set(existing.seenDirectoryIdentityKeys)
    .union(transition.seenDirectoryIdentityKeys)
  return try MediaScanEnumerationState(
    pendingPages: Array(pending),
    completedPages: Array(completed),
    seenEntryIdentityKeys: Array(seenEntries),
    seenDirectoryIdentityKeys: Array(seenDirectories)
  )
}

private actor FixtureScanConnector: MediaSourceConnector {
  private let session: FixtureScanSession
  private(set) var connectionCount = 0

  init(
    sourceUID: String,
    capabilities: MediaSourceCapabilities,
    pages: [FixtureScanPage],
    failureRequest: RemoteDirectoryPageRequest?,
    rootStableID: String = "fixture-root"
  ) {
    session = FixtureScanSession(
      sourceUID: sourceUID,
      capabilities: capabilities,
      pages: pages,
      failureRequest: failureRequest,
      rootStableID: rootStableID
    )
  }

  func connect() async throws -> any MediaSourceSession {
    connectionCount += 1
    return session
  }
}

private actor FixtureScanSession: MediaSourceSession {
  nonisolated let sourceUID: String
  nonisolated let capabilities: MediaSourceCapabilities
  private let pages: [RemoteDirectoryPageRequest: CursorPage<RemoteEntry>]
  private let failureRequest: RemoteDirectoryPageRequest?
  private let rootStableID: String
  private var hasFailed = false

  init(
    sourceUID: String,
    capabilities: MediaSourceCapabilities,
    pages: [FixtureScanPage],
    failureRequest: RemoteDirectoryPageRequest?,
    rootStableID: String
  ) {
    self.sourceUID = sourceUID
    self.capabilities = capabilities
    self.pages = Dictionary(uniqueKeysWithValues: pages.map { ($0.request, $0.response) })
    self.failureRequest = failureRequest
    self.rootStableID = rootStableID
  }

  func listDirectory(_ request: RemoteDirectoryPageRequest) async throws
    -> CursorPage<RemoteEntry>
  {
    if request == failureRequest, !hasFailed {
      hasFailed = true
      throw SDKError(code: .remoteUnavailable, message: "injected page interruption")
    }
    guard let page = pages[request] else {
      throw SDKError(code: .metadataNotFound, message: "fixture page not found")
    }
    return page
  }

  func stat(_ locator: RemoteLocator) async throws -> RemoteEntry {
    guard locator.sourceUID == sourceUID else {
      throw SDKError(code: .metadataNotFound, message: "fixture root not found")
    }
    return try RemoteEntry(
      locator: locator,
      kind: .directory,
      stableID: locator.path.isRoot ? rootStableID : "root-\(locator.path.relativePath)"
    )
  }

  func read(at _: RemoteLocator, range _: RemoteByteRange) async throws -> Data {
    throw SDKError(code: .metadataNotFound, message: "read is unused by scanner fixture")
  }

  func disconnect() async {}
}

private actor BlockingScanConnector: MediaSourceConnector {
  private let session: BlockingScanSession

  init(sourceUID: String, capabilities: MediaSourceCapabilities) {
    session = BlockingScanSession(sourceUID: sourceUID, capabilities: capabilities)
  }

  func connect() async throws -> any MediaSourceSession { session }

  func waitUntilListing() async {
    await session.waitUntilListing()
  }
}

private actor BlockingScanSession: MediaSourceSession {
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

private actor ConcurrencyTracker {
  private(set) var active = 0
  private(set) var maximumActive = 0

  func begin() {
    active += 1
    maximumActive = max(maximumActive, active)
  }

  func end() {
    active -= 1
  }
}

private struct DelayedScanConnector: MediaSourceConnector {
  let session: DelayedScanSession

  init(
    sourceUID: String,
    capabilities: MediaSourceCapabilities,
    pages: [RemoteDirectoryPageRequest: CursorPage<RemoteEntry>],
    tracker: ConcurrencyTracker
  ) {
    session = DelayedScanSession(
      sourceUID: sourceUID,
      capabilities: capabilities,
      pages: pages,
      tracker: tracker
    )
  }

  func connect() async throws -> any MediaSourceSession { session }
}

private struct DelayedScanSession: MediaSourceSession {
  let sourceUID: String
  let capabilities: MediaSourceCapabilities
  let pages: [RemoteDirectoryPageRequest: CursorPage<RemoteEntry>]
  let tracker: ConcurrencyTracker

  func listDirectory(_ request: RemoteDirectoryPageRequest) async throws
    -> CursorPage<RemoteEntry>
  {
    await tracker.begin()
    do {
      try await Task.sleep(for: .milliseconds(10))
      let page = try #require(pages[request])
      await tracker.end()
      return page
    } catch {
      await tracker.end()
      throw error
    }
  }

  func stat(_ locator: RemoteLocator) async throws -> RemoteEntry {
    try RemoteEntry(locator: locator, kind: .directory, stableID: "fixture-root")
  }

  func read(at _: RemoteLocator, range _: RemoteByteRange) async throws -> Data {
    throw SDKError(code: .metadataNotFound, message: "read is unused by concurrency fixture")
  }

  func disconnect() async {}
}

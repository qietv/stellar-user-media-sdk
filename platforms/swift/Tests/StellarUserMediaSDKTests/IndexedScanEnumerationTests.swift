import Foundation
import GRDB
import StellarCore
import StellarMediaLibrary
import StellarRemoteMedia
import StellarStorage
import Testing

@Suite("Indexed scan enumeration")
struct IndexedScanEnumerationTests {
  @Test("SQLite membership and frontier reads stay limited to the requested window")
  func boundedIndexReads() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await StorageDatabase.open(
      kind: .library, at: directory.appendingPathComponent("library.sqlite"))
    let store = try LibraryStore(database: database)
    try await store.registerSource(
      LibrarySourceDefinition(
        uid: "indexed", kind: .smb, displayName: "Indexed", rootURI: "smb://fixture"))
    let root = try RemoteLocator(sourceUID: "indexed", path: RemotePath())
    let checkpoint = try MediaScanCheckpoint(
      request: MediaScanRequest(
        runUID: "indexed-run", sourceUID: "indexed", mode: .full, roots: [root]))
    try await SQLiteMediaScanSink(store: store).commit(
      MediaScanBatch(
        entries: [], checkpoint: checkpoint,
        enumerationState: MediaScanEnumerationState(
          pendingPages: [MediaScanPageCursor(directory: root)], completedPages: [],
          seenEntryIdentityKeys: [], seenDirectoryIdentityKeys: []), pageTransition: nil
      ))
    try await database.write { database in
      let runID = try #require(
        try Int64.fetchOne(database, sql: "SELECT id FROM scan_run WHERE uid = 'indexed-run'"))
      let seen = try database.makeStatement(sql: "INSERT INTO scan_seen VALUES (?, ?, ?)")
      for index in 0..<20_000 { try seen.execute(arguments: [runID, "entry-\(index)", index % 2]) }
      let frontier = try database.makeStatement(
        sql: "INSERT INTO scan_frontier VALUES (?, ?, '', 'pending', 0)")
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      for index in 0..<2_000 {
        let locator = try RemoteLocator(sourceUID: "indexed", path: RemotePath("Folder-\(index)"))
        try frontier.execute(arguments: [
          runID, String(decoding: encoder.encode(locator), as: UTF8.self),
        ])
      }
    }
    let summary = try #require(
      try await store.scanEnumerationSummary(runUID: "indexed-run", sourceUID: "indexed"))
    #expect(summary.pendingPageCount == 2_001)
    #expect(summary.seenEntryCount == 20_000)
    let window = try await store.scanPendingPages(runUID: "indexed-run", limit: 8)
    #expect(window.count == 8)
    let membership = try await store.scanEnumerationMembership(
      runUID: "indexed-run", pages: window,
      identityKeys: ["entry-1", "entry-1", "entry-19998", "missing"])
    #expect(membership.pendingPages.count == 8)
    #expect(Set(membership.seenEntryIdentityKeys) == ["entry-1", "entry-19998"])
    #expect(membership.seenDirectoryIdentityKeys == ["entry-1"])
  }

  @Test("Repeated truncated scans publish observed files without marking omitted files missing")
  func truncatedScansPreserveExistingFiles() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await StorageDatabase.open(
      kind: .library, at: directory.appendingPathComponent("library.sqlite"))
    let store = try LibraryStore(database: database)
    try await store.registerSource(
      LibrarySourceDefinition(
        uid: "limited", kind: .webdav, displayName: "Limited", rootURI: "https://dav.example.test"))
    let sink = SQLiteMediaScanSink(store: store)
    let root = try RemoteLocator(sourceUID: "limited", path: RemotePath())
    for run in 0..<4 {
      let truncated = run > 0
      let result = try await MediaScanner().scan(
        MediaScanRequest(
          runUID: "limited-\(run)", sourceUID: "limited", mode: .full, roots: [root]),
        using: LimitedDirectoryFixture(truncated: truncated), sink: sink)
      #expect(result.checkpoint.hasTruncatedDirectories == truncated)
      #expect(result.checkpoint.outcome == (truncated ? .partial : .complete))
      #expect(result.checkpoint.truncatedDirectories == (truncated ? [root] : []))
      #expect(result.completion.reconcileMissingEligible == !truncated)
      let stored = try #require(try await sink.loadCheckpoint(runUID: "limited-\(run)"))
      #expect(stored.hasTruncatedDirectories == truncated)
      #expect(stored.outcome == result.checkpoint.outcome)
      #expect(stored.truncatedDirectories == result.checkpoint.truncatedDirectories)
    }
    let counts = try await database.read { database in
      let total = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM media_file")
      let missing = try Int.fetchOne(
        database, sql: "SELECT COUNT(*) FROM media_file WHERE missing_since_ms IS NOT NULL")
      let reconciled = try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM scan_run WHERE uid <> 'limited-0' AND reconcile_missing <> 0")
      return [total, missing, reconciled]
    }
    #expect(counts == [2, 0, 0])
  }

  @Test("Indexed scanner deduplicates across pages and bounds live directory handles")
  func wideTree() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await StorageDatabase.open(
      kind: .library, at: directory.appendingPathComponent("library.sqlite"))
    let store = try LibraryStore(database: database)
    try await store.registerSource(
      LibrarySourceDefinition(
        uid: "wide", kind: .smb, displayName: "Wide", rootURI: "smb://fixture"))
    let connector = try WideTreeConnector()
    let root = try RemoteLocator(sourceUID: "wide", path: RemotePath())
    let sink = IndexedSinkDecorator(base: SQLiteMediaScanSink(store: store))
    let result = try await MediaScanner(
      configuration: MediaScannerConfiguration(pageSize: 11, maxConcurrentDirectoryRequests: 4)
    ).scan(
      MediaScanRequest(runUID: "wide-run", sourceUID: "wide", mode: .full, roots: [root]),
      using: connector, sink: sink
    )
    #expect(await sink.committedPages == result.checkpoint.processedPageCount)
    #expect(result.completion.reconcileMissingEligible)
    #expect(result.checkpoint.discoveredEntryCount == 64 * 20 + 64)
    #expect(await connector.session.maximumOpenDirectoryCount <= 4)
    #expect(await connector.session.openDirectoryCount == 0)
    let fileCount = try await database.read {
      try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM media_file")
    }
    #expect(fileCount == 64 * 20)
  }
}

private struct WideTreeConnector: MediaSourceConnector {
  let session: WideTreeSession
  init() throws { session = try WideTreeSession() }
  func connect() async throws -> any MediaSourceSession { session }
}

private actor WideTreeSession: MediaSourceSession {
  nonisolated let sourceUID = "wide"
  nonisolated let capabilities: MediaSourceCapabilities
  private var openDirectories = Set<RemoteLocator>()
  private(set) var maximumOpenDirectoryCount = 0
  var openDirectoryCount: Int { openDirectories.count }

  init() throws {
    capabilities = try MediaSourceCapabilities(
      stableIDScope: .persistent,
      pathSemantics: RemotePathSemantics(
        caseSensitivity: .sensitive, unicodeNormalization: .preserve), supportsRangeReads: true,
      supportsChangeCursor: false, deltaDeletionsComplete: false,
      preferredDirectoryRequestConcurrency: 4)
  }

  func listDirectory(_ request: RemoteDirectoryPageRequest) async throws -> CursorPage<RemoteEntry>
  {
    if request.cursor == nil {
      #expect(openDirectories.insert(request.directory).inserted)
      maximumOpenDirectoryCount = max(maximumOpenDirectoryCount, openDirectories.count)
    }
    let start = request.cursor.flatMap(Int.init) ?? 0
    let isRoot = request.directory.path.relativePath.isEmpty
    let count = isRoot ? 64 : 21
    let end = min(start + request.limit, count)
    var items: [RemoteEntry] = []
    for index in start..<end {
      // Repeat the first file on the last page, after it has left the scanner's working set.
      let effectiveIndex = !isRoot && index == 20 ? 0 : index
      let path = try request.directory.path.appending(
        component: isRoot ? "Folder-\(index)" : "Video-\(effectiveIndex).mkv")
      items.append(
        try RemoteEntry(
          locator: RemoteLocator(sourceUID: sourceUID, path: path),
          kind: isRoot ? .directory : .file, stableID: path.relativePath, size: isRoot ? nil : 10))
    }
    if end == count { openDirectories.remove(request.directory) }
    return try CursorPage(items: items, nextCursor: end == count ? nil : String(end))
  }

  func stat(_ locator: RemoteLocator) async throws -> RemoteEntry {
    try RemoteEntry(locator: locator, kind: .directory, stableID: "root")
  }
  func read(at _: RemoteLocator, range _: RemoteByteRange) async throws -> Data { Data() }
  func disconnect() async { openDirectories.removeAll() }
}

private actor IndexedSinkDecorator: MediaScanSink {
  nonisolated let base: SQLiteMediaScanSink
  private(set) var committedPages: Int64 = 0
  nonisolated var enumerationIndex: (any MediaScanEnumerationIndex)? { base.enumerationIndex }
  init(base: SQLiteMediaScanSink) { self.base = base }
  func commit(_ batch: MediaScanBatch) async throws {
    try await base.commit(batch)
    committedPages += Int64(batch.pageTransitions.count)
  }
  func loadEnumerationState(runUID: String) async throws -> MediaScanEnumerationState? {
    Issue.record("Indexed sink decorators must never load the full enumeration state")
    return try await base.loadEnumerationState(runUID: runUID)
  }
}

private struct LimitedDirectoryFixture: MediaSourceConnector, MediaSourceSession {
  let truncated: Bool
  let sourceUID = "limited"
  let capabilities: MediaSourceCapabilities

  init(truncated: Bool) throws {
    self.truncated = truncated
    capabilities = try MediaSourceCapabilities(
      stableIDScope: .none,
      pathSemantics: RemotePathSemantics(
        caseSensitivity: .sensitive, unicodeNormalization: .preserve),
      supportsRangeReads: true, supportsChangeCursor: false, deltaDeletionsComplete: false)
  }

  func connect() async throws -> any MediaSourceSession { self }
  func listDirectory(_ request: RemoteDirectoryPageRequest) async throws -> CursorPage<RemoteEntry>
  {
    let names = truncated ? ["kept.mkv"] : ["kept.mkv", "omitted.mkv"]
    return try CursorPage(
      items: names.map {
        try RemoteEntry(
          locator: RemoteLocator(sourceUID: sourceUID, path: RemotePath($0)), kind: .file)
      }, nextCursor: nil, isTruncated: truncated)
  }
  func stat(_ locator: RemoteLocator) async throws -> RemoteEntry {
    // Default policy probes exclusion markers separately.
    guard locator.path.isRoot else {
      throw SDKError(code: .metadataNotFound, message: "No exclusion marker")
    }
    return try RemoteEntry(locator: locator, kind: .directory)
  }
  func read(at _: RemoteLocator, range _: RemoteByteRange) async throws -> Data { Data() }
  func disconnect() async {}
}

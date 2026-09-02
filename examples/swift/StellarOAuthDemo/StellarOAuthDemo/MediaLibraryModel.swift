import Combine
import Foundation
import StellarSMB2Apple
import StellarSMB2Core
import StellarUserMediaSDK

private enum DemoScanFilePolicy {
  private static let videoExtensions: Set<String> = [
    "3gp", "avi", "flv", "m2ts", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "mts",
    "ts", "webm", "wmv",
  ]

  static func isVideoPath(_ path: String) -> Bool {
    guard let separator = path.utf8.lastIndex(of: 46),
      path.utf8.lastIndex(of: 47).map({ $0 < separator }) ?? true
    else {
      return false
    }
    let extensionStart = path.index(after: separator)
    guard extensionStart != path.endIndex else { return false }
    return videoExtensions.contains(path[extensionStart...].lowercased())
  }

  static func shouldPersist(_ entry: RemoteEntry) -> Bool {
    entry.kind != .file || isVideoPath(entry.locator.path.relativePath)
  }
}

enum DemoScanState: Equatable {
  case idle
  case preparing
  case scanning
  case enriching
  case pausing
  case paused
  case completed
  case failed

  var label: String {
    switch self {
    case .idle: "Ready"
    case .preparing: "Preparing"
    case .scanning: "Scanning files"
    case .enriching: "Matching metadata"
    case .pausing: "Pausing"
    case .paused: "Paused"
    case .completed: "Completed"
    case .failed: "Needs attention"
    }
  }
}

private struct DemoScanProgress: Equatable, Sendable {
  var discoveredEntryCount: Int64 = 0
  var processedPageCount: Int64 = 0
  var pendingPageCount = 0
  var currentFile: String?
}

struct DemoPosterItem: Identifiable, Equatable, Sendable {
  let mediaUID: String
  let kind: PosterWallMediaKind
  let title: String
  let originalTitle: String?
  let overview: String?
  let year: Int?
  let artworkURL: URL?
  let availability: PosterWallAvailability

  var id: String { mediaUID }
}

private struct DemoMetadataWorkItem: Sendable {
  let lease: LibraryScanWorkLease

  var file: LibraryFileFact { lease.file }
  var hasMatchingBinding: Bool { lease.hasMatchingBinding }
}

private enum DemoMetadataWorkResult: Sendable {
  case matched(path: String, wasAlreadyMatched: Bool)
  case preserved(path: String)
  case skipped(path: String)
  case retry(path: String)
}

@MainActor
final class MediaLibraryModel: ObservableObject {
  static let mediaServiceOrigin = "https://dev-api-st.2dland.cn"

  @Published var server = "172.31.36.200"
  @Published var port = ""
  @Published var share = "video"
  @Published var rootPath = ""
  @Published var username = "coldlake"
  @Published var password = ""

  @Published private(set) var scanState: DemoScanState = .idle
  @Published private(set) var notice = "Enter the SMB password, then start a full scan."
  @Published private(set) var noticeIsError = false
  @Published private var scanProgress = DemoScanProgress()
  @Published private(set) var mediaFileCount = 0
  @Published private(set) var matchedFileCount = 0
  @Published private(set) var failedFileCount = 0
  @Published private(set) var posterItems: [DemoPosterItem] = []
  @Published private(set) var isPosterWallLoading = false
  @Published private(set) var posterWallNotice = "Scan an SMB source to build the poster wall."

  private var scanTask: Task<Void, Never>?
  private var scanProgressPublishTask: Task<Void, Never>?
  private var pendingScanProgress: DemoScanProgress?
  private var activeRequest: MediaScanRequest?
  private var metadataRecoverySourceUID: String?
  private var libraryDatabase: StorageDatabase?
  private var libraryStore: LibraryStore?
  private var metadataCacheStore: MetadataCacheStore?
  private var mediaInfoClient: TestMediaInfoClient?

  var discoveredEntryCount: Int64 { scanProgress.discoveredEntryCount }
  var processedPageCount: Int64 { scanProgress.processedPageCount }
  var pendingPageCount: Int { scanProgress.pendingPageCount }
  var currentFile: String? { scanProgress.currentFile }

  var canStartOrResume: Bool {
    scanTask == nil && [.idle, .paused, .completed, .failed].contains(scanState)
  }

  var canPause: Bool {
    scanTask != nil && [.preparing, .scanning, .enriching].contains(scanState)
  }

  var inputsAreDisabled: Bool {
    scanTask != nil || scanState == .paused
  }

  var credentialInputIsDisabled: Bool {
    scanTask != nil
  }

  var primaryActionTitle: String {
    if scanState == .paused, metadataRecoverySourceUID != nil {
      return "Resume metadata"
    }
    return switch scanState {
    case .paused: "Resume scan"
    case .completed: "Scan again"
    default: "Start scan"
    }
  }

  func prepareIfNeeded() async {
    do {
      if libraryStore == nil || metadataCacheStore == nil {
        let folder = try applicationSupportFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let library = try await StorageDatabase.open(
          kind: .library,
          at: folder.appendingPathComponent("library.sqlite")
        )
        let metadata = try await StorageDatabase.open(
          kind: .metadataCache,
          at: folder.appendingPathComponent("metadata_cache.sqlite")
        )
        libraryDatabase = library
        libraryStore = try LibraryStore(database: library)
        let cacheStore = try MetadataCacheStore(database: metadata)
        metadataCacheStore = cacheStore
        mediaInfoClient = TestMediaInfoClient(cacheStore: cacheStore)
      }
      try await restoreDurableWorkIfAvailable()
    } catch {
      scanState = .failed
      show(error: error)
      posterWallNotice = "The local media library could not be opened."
    }
  }

  func startOrResume() {
    guard canStartOrResume else { return }
    scanTask = Task { [weak self] in
      await self?.runScan()
    }
  }

  func pause() {
    guard canPause else { return }
    if scanState == .enriching, let sourceUID = activeRequest?.sourceUID {
      metadataRecoverySourceUID = sourceUID
      activeRequest = nil
    }
    scanState = .pausing
    show("Saving the current checkpoint…")
    scanTask?.cancel()
  }

  func refreshPosterWall() async {
    await prepareIfNeeded()
    guard let libraryDatabase else { return }
    isPosterWallLoading = true
    defer { isPosterWallLoading = false }

    do {
      let wall = try PosterWallStore(database: libraryDatabase)
      var allItems: [PosterWallItem] = []
      var cursor: String?
      var revision: String?
      repeat {
        let page = try await wall.page(
          PosterWallQuery(
            section: .all,
            sort: .title,
            locale: "zh-CN",
            pageSize: 200,
            cursor: cursor,
            libraryRevision: revision
          )
        )
        revision = page.libraryRevision
        cursor = page.nextCursor
        allItems.append(contentsOf: page.items)
      } while cursor != nil

      posterItems = allItems.map { item in
        return DemoPosterItem(
          mediaUID: item.mediaUID,
          kind: item.kind,
          title: item.title,
          originalTitle: nil,
          overview: nil,
          year: item.year,
          artworkURL: item.poster?.remoteReference.flatMap(URL.init(string:)),
          availability: item.availability
        )
      }
      posterWallNotice =
        posterItems.isEmpty
        ? "No matched movies or series are available yet."
        : "Showing \(posterItems.count) matched movies and series."
    } catch {
      posterWallNotice = Self.message(for: error)
    }
  }

  func posterDetails(for item: DemoPosterItem) async -> DemoPosterItem {
    await prepareIfNeeded()
    guard let libraryDatabase else { return item }
    do {
      let details = try await PosterWallStore(database: libraryDatabase).details(
        mediaUID: item.mediaUID,
        locale: "zh-CN"
      )
      return DemoPosterItem(
        mediaUID: item.mediaUID,
        kind: item.kind,
        title: details.item.title,
        originalTitle: details.originalTitle,
        overview: details.overview,
        year: details.item.year,
        artworkURL: details.item.poster?.remoteReference.flatMap(URL.init(string:)),
        availability: details.item.availability
      )
    } catch {
      return item
    }
  }

  private func runScan() async {
    defer { scanTask = nil }
    await prepareIfNeeded()
    guard let libraryStore, let metadataCacheStore, let mediaInfoClient else { return }

    do {
      if let sourceUID = metadataRecoverySourceUID {
        scanState = .enriching
        show("Continuing durable metadata work without rescanning the SMB source…")
        try await enrichLibrary(
          sourceUID: sourceUID,
          libraryStore: libraryStore,
          metadataCacheStore: metadataCacheStore,
          mediaInfoClient: mediaInfoClient
        )
        try Task.checkCancellation()
        if try await libraryStore.hasOutstandingScanWork(sourceUID: sourceUID, stage: .parse) {
          scanState = .paused
          updateCurrentFile(nil)
          show("Metadata work is deferred or leased. Resume later; no SMB rescan is needed.")
        } else {
          metadataRecoverySourceUID = nil
          scanState = .completed
          updateCurrentFile(nil)
          show(
            "Metadata completed: \(mediaFileCount) video files, \(matchedFileCount) matched, "
              + "\(failedFileCount) skipped."
          )
        }
        await refreshPosterWall()
        return
      }

      let connection = try makeConnection()
      let sqliteSink = SQLiteMediaScanSink(store: libraryStore)
      var checkpoint: MediaScanCheckpoint?
      var isResume = scanState == .paused && activeRequest != nil
      if isResume, let request = activeRequest {
        checkpoint = try await sqliteSink.loadCheckpoint(runUID: request.runUID)
        guard checkpoint != nil else {
          throw SDKError(code: .storageFailure, message: "saved scan checkpoint is unavailable")
        }
      } else if let recovered = try await sqliteSink.loadLatestRecoverableCheckpoint(
        sourceUID: connection.sourceUID
      ) {
        activeRequest = recovered.request
        checkpoint = recovered
        isResume = true
        restoreProgress(from: recovered)
      }
      if !isResume {
        metadataRecoverySourceUID = nil
        activeRequest = try MediaScanRequest(
          runUID: UUID().uuidString.lowercased(),
          sourceUID: connection.sourceUID,
          mode: .full,
          roots: [try RemoteLocator(sourceUID: connection.sourceUID, path: RemotePath())]
        )
        resetScanProgress()
        mediaFileCount = 0
        matchedFileCount = 0
        failedFileCount = 0
      }
      guard let request = activeRequest else {
        throw SDKError(code: .invalidConfiguration, message: "scan request is unavailable")
      }
      guard request.sourceUID == connection.sourceUID else {
        throw SDKError(
          code: .invalidConfiguration,
          message: "SMB settings changed while the scan was paused"
        )
      }

      scanState = .preparing
      show(isResume ? "Restoring the saved scan checkpoint…" : "Connecting to the SMB share…")
      try await libraryStore.registerSource(connection.sourceDefinition)

      let relay = DemoScanProgressRelay(
        onBatch: { [weak self] latestFilePath, checkpoint in
          self?.record(latestFilePath: latestFilePath, checkpoint: checkpoint)
        },
        onEvent: { [weak self] event in
          self?.record(event: event)
        }
      )
      let sink = DemoScanSink(base: sqliteSink, relay: relay)
      scanState = .scanning
      show("Scanning SMB directories…")

      _ = try await MediaScanner().scan(
        request,
        using: connection.connector,
        sink: sink,
        resumeFrom: checkpoint,
        observer: DemoScanObserver(relay: relay)
      )

      flushScanProgress()
      scanState = .enriching
      show("Matching video files with the test media service…")
      try await enrichLibrary(
        sourceUID: request.sourceUID,
        libraryStore: libraryStore,
        metadataCacheStore: metadataCacheStore,
        mediaInfoClient: mediaInfoClient
      )
      try Task.checkCancellation()

      if try await libraryStore.hasOutstandingScanWork(
        sourceUID: request.sourceUID,
        stage: .parse
      ) {
        activeRequest = nil
        metadataRecoverySourceUID = request.sourceUID
        scanState = .paused
        updateCurrentFile(nil)
        show(
          "File scan completed. Metadata retries remain durable and can resume without rescanning."
        )
        await refreshPosterWall()
        return
      }

      scanState = .completed
      activeRequest = nil
      updateCurrentFile(nil)
      show(
        "Scan completed: \(mediaFileCount) video files, \(matchedFileCount) matched, "
          + "\(failedFileCount) skipped or failed."
      )
      await refreshPosterWall()
    } catch {
      flushScanProgress()
      if Task.isCancelled || Self.isCancellation(error) {
        scanState = .paused
        updateCurrentFile(nil)
        show("Paused. Resume continues from the last durable checkpoint.")
      } else {
        scanState = .failed
        activeRequest = nil
        updateCurrentFile(nil)
        show(error: error)
      }
    }
  }

  private func enrichLibrary(
    sourceUID: String,
    libraryStore: LibraryStore,
    metadataCacheStore: MetadataCacheStore,
    mediaInfoClient: TestMediaInfoClient
  ) async throws {
    let initialSummary = try await libraryStore.sourceMediaSummary(sourceUID: sourceUID)
    mediaFileCount = initialSummary.presentFileCount
    matchedFileCount = initialSummary.matchedFileCount
    failedFileCount = 0
    let policy = try MediaMatchScoringPolicy(automaticThreshold: 0.70, reviewThreshold: 0.55)
    let matcher = SQLiteMediaMatcher(
      libraryStore: libraryStore,
      metadataCacheStore: metadataCacheStore,
      scorer: MediaMetadataCandidateScorer(policy: policy)
    )
    await mediaInfoClient.resetProviderSuspension()
    var completedCount = 0
    let workerID = "stellar-oauth-demo-\(UUID().uuidString.lowercased())"
    let workerConcurrency = 4
    try await withThrowingTaskGroup(of: DemoMetadataWorkResult.self) { group in
      var activeWorkerCount = 0

      let initialLeases = try await libraryStore.claimScanFileWork(
        sourceUID: sourceUID,
        stage: .parse,
        workerID: workerID,
        limit: workerConcurrency,
        leaseDurationMilliseconds: 120_000
      )
      for lease in initialLeases {
        let workItem = DemoMetadataWorkItem(lease: lease)
        activeWorkerCount += 1
        group.addTask {
          try await Self.processMetadataWork(
            workItem,
            sourceUID: sourceUID,
            matcher: matcher,
            libraryStore: libraryStore,
            mediaInfoClient: mediaInfoClient
          )
        }
      }

      while activeWorkerCount > 0, let result = try await group.next() {
        activeWorkerCount -= 1
        completedCount += 1
        let path: String
        switch result {
        case .matched(let value, let wasAlreadyMatched):
          path = value
          if !wasAlreadyMatched {
            matchedFileCount += 1
          }
        case .preserved(let value):
          path = value
        case .skipped(let value), .retry(let value):
          path = value
          failedFileCount += 1
        }
        updateCurrentFile(path)
        show("Matched or classified \(completedCount) changed videos…")

        try Task.checkCancellation()
        if let replacementLease = try await libraryStore.claimScanFileWork(
          sourceUID: sourceUID,
          stage: .parse,
          workerID: workerID,
          limit: 1,
          leaseDurationMilliseconds: 120_000
        ).first {
          let workItem = DemoMetadataWorkItem(lease: replacementLease)
          activeWorkerCount += 1
          group.addTask {
            try await Self.processMetadataWork(
              workItem,
              sourceUID: sourceUID,
              matcher: matcher,
              libraryStore: libraryStore,
              mediaInfoClient: mediaInfoClient
            )
          }
        }
      }
    }

    let finalSummary = try await libraryStore.sourceMediaSummary(sourceUID: sourceUID)
    mediaFileCount = finalSummary.presentFileCount
    matchedFileCount = finalSummary.matchedFileCount
  }

  private nonisolated static func processMetadataWork(
    _ workItem: DemoMetadataWorkItem,
    sourceUID: String,
    matcher: SQLiteMediaMatcher,
    libraryStore: LibraryStore,
    mediaInfoClient: TestMediaInfoClient
  ) async throws -> DemoMetadataWorkResult {
    let path = workItem.file.relativePath
    let heartbeat = Task<Void, Never> {
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(30))
          guard !Task.isCancelled else { return }
          _ = try await libraryStore.renewScanWorkLease(
            workItem.lease,
            leaseDurationMilliseconds: 120_000
          )
        } catch {
          return
        }
      }
    }
    defer { heartbeat.cancel() }
    do {
      let resolution = try await mediaInfoClient.resolve(path: path)
      guard let resolved = try await mediaInfoClient.posterMetadata(from: resolution) else {
        throw SDKError(
          code: .metadataNotFound,
          message: "the media service returned no usable metadata"
        )
      }
      let query = try resolution.makeMatchQuery()
      let candidate = try resolved.makeCandidate(for: query)
      let result = try await matcher.evaluate(
        query: query,
        candidates: [candidate],
        sourceUID: sourceUID,
        mediaRelativePath: path
      )
      if result.state == .lockedBindingPreserved {
        try await libraryStore.completeScanWork(workItem.lease)
        return .preserved(path: path)
      }
      guard result.state == .automaticBound else {
        throw SDKError(
          code: .metadataNotFound,
          message: "the media file could not be matched automatically"
        )
      }

      let artwork: ResolvedArtworkVariant?
      if let artworkID = resolved.artworkID {
        artwork = try await mediaInfoClient.bestArtwork(artworkID: artworkID)
      } else {
        artwork = nil
      }
      let metadata = try LibraryRemoteMetadata(
        provider: ResolvedPosterMetadata.provider,
        providerID: resolved.rootObjectID,
        kind: resolved.kind == .movie ? .movie : .series,
        locale: "zh-CN",
        title: resolved.title,
        originalTitle: resolved.originalTitle,
        overview: resolved.overview,
        year: resolved.year,
        posterURL: artwork?.url.absoluteString,
        posterWidth: artwork?.width,
        posterHeight: artwork?.height
      )
      _ = try await libraryStore.commitRemoteMetadata(
        metadata,
        completing: workItem.lease
      )
      return .matched(path: path, wasAlreadyMatched: workItem.hasMatchingBinding)
    } catch {
      if Self.isCancellation(error) {
        try? await libraryStore.retryScanWork(
          workItem.lease,
          errorCode: .cancelled,
          retryAfterMilliseconds: 0
        )
        throw error
      }
      let code = (error as? SDKError)?.code ?? .unknown
      if code == .metadataNotFound {
        try await libraryStore.completeScanWork(workItem.lease)
        return .skipped(path: path)
      }
      let providerDelay = (error as? SDKError)?.retryAfterMilliseconds
      let retryDelay = max(
        providerDelay ?? 0,
        min(300_000, 5_000 * Int64(1 << min(workItem.lease.attempts, 5)))
      )
      try await libraryStore.retryScanWork(
        workItem.lease,
        errorCode: code,
        retryAfterMilliseconds: retryDelay
      )
      return .retry(path: path)
    }
  }

  private func record(latestFilePath: String?, checkpoint: MediaScanCheckpoint) {
    var next = pendingScanProgress ?? scanProgress
    next.discoveredEntryCount = checkpoint.discoveredEntryCount
    next.processedPageCount = checkpoint.processedPageCount
    next.pendingPageCount = checkpoint.pendingPageCount
    if let latestFilePath {
      next.currentFile = latestFilePath
    }
    queueScanProgress(next)
  }

  private func record(event: MediaScanEvent) {
    var next = pendingScanProgress ?? scanProgress
    next.discoveredEntryCount = event.discoveredEntryCount
    next.processedPageCount = event.processedPageCount
    next.pendingPageCount = event.pendingPageCount
    queueScanProgress(next)
  }

  private func queueScanProgress(_ progress: DemoScanProgress) {
    let currentTarget = pendingScanProgress ?? scanProgress
    guard progress != currentTarget else { return }
    pendingScanProgress = progress
    guard scanProgressPublishTask == nil else { return }
    scanProgressPublishTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
      self?.flushScanProgress()
    }
  }

  private func flushScanProgress() {
    scanProgressPublishTask?.cancel()
    scanProgressPublishTask = nil
    guard let pendingScanProgress else { return }
    self.pendingScanProgress = nil
    if pendingScanProgress != scanProgress {
      scanProgress = pendingScanProgress
    }
  }

  private func resetScanProgress() {
    scanProgressPublishTask?.cancel()
    scanProgressPublishTask = nil
    pendingScanProgress = nil
    scanProgress = DemoScanProgress()
  }

  private func restoreProgress(from checkpoint: MediaScanCheckpoint) {
    scanProgressPublishTask?.cancel()
    scanProgressPublishTask = nil
    pendingScanProgress = nil
    scanProgress = DemoScanProgress(
      discoveredEntryCount: checkpoint.discoveredEntryCount,
      processedPageCount: checkpoint.processedPageCount,
      pendingPageCount: checkpoint.pendingPageCount,
      currentFile: nil
    )
  }

  private func restoreDurableWorkIfAvailable() async throws {
    guard scanTask == nil, activeRequest == nil, scanState == .idle,
      let libraryStore, let sourceUID = sourceUIDForRecovery()
    else { return }
    let sink = SQLiteMediaScanSink(store: libraryStore)
    let summary = try await libraryStore.sourceMediaSummary(sourceUID: sourceUID)
    mediaFileCount = summary.presentFileCount
    matchedFileCount = summary.matchedFileCount
    if let checkpoint = try await sink.loadLatestRecoverableCheckpoint(sourceUID: sourceUID) {
      activeRequest = checkpoint.request
      restoreProgress(from: checkpoint)
      scanState = .paused
      show("Recovered an interrupted scan. Enter the SMB password to continue safely.")
    } else if try await libraryStore.hasOutstandingScanWork(
      sourceUID: sourceUID,
      stage: .parse
    ) {
      metadataRecoverySourceUID = sourceUID
      scanState = .paused
      show("Recovered pending metadata work. It can continue without rescanning the SMB source.")
    }
  }

  private func updateCurrentFile(_ path: String?) {
    guard scanProgress.currentFile != path else { return }
    var next = scanProgress
    next.currentFile = path
    scanProgress = next
  }

  private func makeConnection() throws -> DemoSMBConnection {
    let normalizedServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedShare = share.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedRoot = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let parsedPort: UInt16?
    if port.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      parsedPort = nil
    } else if let value = UInt16(port), value > 0 {
      parsedPort = value
    } else {
      throw SDKError(code: .invalidConfiguration, message: "SMB port is invalid")
    }
    guard !password.isEmpty else {
      throw SDKError(code: .credentialRequired, message: "SMB password is required")
    }

    let endpoint = try SMB2Endpoint(
      server: normalizedServer,
      port: parsedPort,
      share: normalizedShare,
      rootPath: normalizedRoot
    )
    let request = try SMB2ConnectionRequest(
      endpoint: endpoint,
      credential: SMB2Credential(username: username, password: password)
    )
    let sourceUID = Self.sourceUID(
      server: normalizedServer,
      port: parsedPort,
      share: normalizedShare,
      rootPath: normalizedRoot
    )
    let configuration = try SMB2MediaSourceConfiguration(
      sourceUID: sourceUID,
      connectionRequest: request,
      stableIDScope: .persistent,
      directoryConnectionCount: 2
    )
    let connector = SMB2MediaSourceConnector(
      transport: AppleSMB2Transport(),
      configuration: configuration
    )

    var components = URLComponents()
    components.scheme = "smb"
    components.host = normalizedServer.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    components.port = parsedPort.map(Int.init)
    components.path =
      "/"
      + ([normalizedShare] + normalizedRoot.split(separator: "/").map(String.init))
      .joined(separator: "/")
    guard let rootURI = components.string else {
      throw SDKError(code: .invalidConfiguration, message: "SMB source URL is invalid")
    }
    let definition = try LibrarySourceDefinition(
      uid: sourceUID,
      kind: .smb,
      displayName: normalizedShare,
      rootURI: rootURI
    )
    return DemoSMBConnection(
      sourceUID: sourceUID,
      connector: connector,
      sourceDefinition: definition
    )
  }

  private func sourceUIDForRecovery() -> String? {
    let normalizedServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedShare = share.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedRoot = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedServer.isEmpty, !normalizedShare.isEmpty else { return nil }
    let normalizedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
    let parsedPort: UInt16?
    if normalizedPort.isEmpty {
      parsedPort = nil
    } else if let value = UInt16(normalizedPort), value > 0 {
      parsedPort = value
    } else {
      return nil
    }
    return Self.sourceUID(
      server: normalizedServer,
      port: parsedPort,
      share: normalizedShare,
      rootPath: normalizedRoot
    )
  }

  private func applicationSupportFolder() throws -> URL {
    let root = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    return root.appendingPathComponent("StellarOAuthDemo", isDirectory: true)
  }

  private func show(_ message: String, isError: Bool = false) {
    notice = message
    noticeIsError = isError
  }

  private func show(error: Error) {
    show(Self.message(for: error), isError: true)
  }

  private static func sourceUID(
    server: String,
    port: UInt16?,
    share: String,
    rootPath: String
  ) -> String {
    let value =
      "\(server.lowercased())|\(port.map(String.init) ?? "445")|"
      + "\(share.lowercased())|\(rootPath)"
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return "demo-smb-" + String(hash, radix: 16)
  }

  private nonisolated static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    return (error as? SDKError)?.code == .cancelled
  }

  private nonisolated static func message(for error: Error) -> String {
    if let error = error as? SDKError {
      return "\(error.code.rawValue): \(error.message)"
    }
    if error is CancellationError {
      return "cancelled: The operation was cancelled"
    }
    return "unknown: The operation failed"
  }
}

private struct DemoSMBConnection {
  let sourceUID: String
  let connector: SMB2MediaSourceConnector
  let sourceDefinition: LibrarySourceDefinition
}

private actor DemoScanProgressRelay {
  typealias BatchHandler = @MainActor @Sendable (String?, MediaScanCheckpoint) -> Void
  typealias EventHandler = @MainActor @Sendable (MediaScanEvent) -> Void

  private let onBatch: BatchHandler
  private let onEvent: EventHandler

  init(onBatch: @escaping BatchHandler, onEvent: @escaping EventHandler) {
    self.onBatch = onBatch
    self.onEvent = onEvent
  }

  func batch(_ entries: [RemoteEntry], checkpoint: MediaScanCheckpoint) async {
    let latestFilePath = entries.last(where: { $0.kind == .file })?.locator.path.relativePath
    await onBatch(latestFilePath, checkpoint)
  }

  func event(_ event: MediaScanEvent) async {
    await onEvent(event)
  }
}

private struct DemoScanSink: MediaScanSink {
  let base: SQLiteMediaScanSink
  let relay: DemoScanProgressRelay

  var preferredPageCommitBatchSize: Int { base.preferredPageCommitBatchSize }

  func commit(_ batch: MediaScanBatch) async throws {
    let retainedEntries = batch.entries.filter(DemoScanFilePolicy.shouldPersist)
    let retainedBatch = MediaScanBatch(
      entries: retainedEntries,
      checkpoint: batch.checkpoint,
      completion: batch.completion,
      enumerationState: batch.enumerationState,
      pageTransitions: batch.pageTransitions
    )
    try await base.commit(retainedBatch)
    await relay.batch(retainedEntries, checkpoint: batch.checkpoint)
  }
}

private struct DemoScanObserver: MediaScanObserver {
  let relay: DemoScanProgressRelay

  func emit(_ event: MediaScanEvent) async {
    await relay.event(event)
  }
}

private actor TestMediaInfoClient {
  private static let baseURL = URL(string: "https://dev-api-st.2dland.cn/v1/media-info/")!
  private static let allowedHost = "dev-api-st.2dland.cn"
  private static let provider = ResolvedPosterMetadata.provider
  private static let resolveTTLMilliseconds: Int64 = 24 * 60 * 60 * 1_000
  private static let entityTTLMilliseconds: Int64 = 7 * 24 * 60 * 60 * 1_000
  private static let negativeTTLMilliseconds: Int64 = 60 * 60 * 1_000
  private static let minimumRequestIntervalMilliseconds: Int64 = 100
  private static let maximumAttempts = 3
  private static let maximumResponseBytes = 8 * 1_024 * 1_024

  private let cacheStore: MetadataCacheStore
  private let redirectBlocker: TestMediaInfoRedirectBlocker
  private let session: URLSession
  private var inFlight: [String: Task<Data, Error>] = [:]
  private var nextRequestAtMilliseconds: Int64 = 0
  private var suspendedError: SDKError?

  init(cacheStore: MetadataCacheStore) {
    self.cacheStore = cacheStore
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 45
    configuration.requestCachePolicy = .useProtocolCachePolicy
    configuration.urlCache = URLCache(
      memoryCapacity: 8 * 1_024 * 1_024,
      diskCapacity: 64 * 1_024 * 1_024
    )
    let redirectBlocker = TestMediaInfoRedirectBlocker()
    self.redirectBlocker = redirectBlocker
    session = URLSession(
      configuration: configuration,
      delegate: redirectBlocker,
      delegateQueue: nil
    )
  }

  func resetProviderSuspension() {
    suspendedError = nil
  }

  func resolve(path: String) async throws -> MediaInfoResolution {
    var request = URLRequest(url: Self.baseURL.appendingPathComponent("resolve"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(
      MediaInfoResolveRequest(path: path, locale: "zh-CN"))
    return try await send(
      request,
      endpoint: "resolve",
      locale: "zh-CN",
      ttlMilliseconds: Self.resolveTTLMilliseconds
    )
  }

  func posterMetadata(from resolution: MediaInfoResolution) async throws -> ResolvedPosterMetadata?
  {
    guard let selected = resolution.selected else { return nil }
    if selected.objectKind == "episode" {
      guard let seriesID = selected.seriesID else { return nil }
      let fallback = ResolvedPosterMetadata(
        rootObjectID: seriesID,
        kind: .series,
        title: resolution.primaryCandidate?.title ?? selected.title,
        originalTitle: nil,
        overview: nil,
        year: resolution.primaryCandidate?.year,
        artworkID: nil
      )
      do {
        async let entity: MediaInfoEntity = get(
          pathComponents: ["entities", seriesID],
          queryItems: [URLQueryItem(name: "locale", value: "zh-CN")],
          locale: "zh-CN"
        )
        async let artworkPage: MediaInfoArtworkPage = get(
          pathComponents: ["entities", seriesID, "artworks"],
          queryItems: [
            URLQueryItem(name: "locale", value: "zh-CN"),
            URLQueryItem(name: "limit", value: "100"),
          ],
          locale: "zh-CN"
        )
        let (resolvedEntity, resolvedArtworkPage) = try await (entity, artworkPage)
        return ResolvedPosterMetadata(
          rootObjectID: seriesID,
          kind: .series,
          title: resolvedEntity.title ?? fallback.title,
          originalTitle: resolvedEntity.originalTitle,
          overview: resolvedEntity.overview,
          year: Self.year(from: resolvedEntity.firstAirDate) ?? fallback.year,
          artworkID: resolvedArtworkPage.items.first(where: {
            $0.artworkKind == "poster"
          })?.artworkID
        )
      } catch {
        if Self.isCancellation(error) { throw error }
        return fallback
      }
    }

    return ResolvedPosterMetadata(
      rootObjectID: selected.objectID,
      kind: selected.objectKind == "series" ? .series : .movie,
      title: selected.title,
      originalTitle: selected.originalTitle,
      overview: selected.overview,
      year: selected.year,
      artworkID: selected.artworkID
    )
  }

  func bestArtwork(artworkID: String) async throws -> ResolvedArtworkVariant? {
    let page: MediaInfoArtworkVariantPage = try await get(
      pathComponents: ["artworks", artworkID, "variants"],
      queryItems: [URLQueryItem(name: "limit", value: "50")],
      locale: "und"
    )
    return page.items.compactMap { item -> ResolvedArtworkVariant? in
      guard let url = URL(string: item.url), url.scheme == "https" else { return nil }
      return ResolvedArtworkVariant(url: url, width: item.width, height: item.height)
    }.max { $0.pixelArea < $1.pixelArea }
  }

  private func get<Response: Decodable & Sendable>(
    pathComponents: [String],
    queryItems: [URLQueryItem],
    locale: String
  ) async throws -> Response {
    var url = Self.baseURL
    for component in pathComponents {
      url.appendPathComponent(component)
    }
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw SDKError(code: .invalidConfiguration, message: "media service URL is invalid")
    }
    components.queryItems = queryItems
    guard let requestURL = components.url else {
      throw SDKError(code: .invalidConfiguration, message: "media service URL is invalid")
    }
    return try await send(
      URLRequest(url: requestURL),
      endpoint: pathComponents.joined(separator: "/"),
      locale: locale,
      ttlMilliseconds: Self.entityTTLMilliseconds
    )
  }

  private func send<Response: Decodable & Sendable>(
    _ request: URLRequest,
    endpoint: String,
    locale: String,
    ttlMilliseconds: Int64
  ) async throws -> Response {
    do {
      guard request.url?.scheme == "https", request.url?.host == Self.allowedHost else {
        throw SDKError(
          code: .invalidConfiguration,
          message: "only the test media service origin is allowed"
        )
      }
      let fingerprint = Self.requestFingerprint(request)
      let requestKey = "\(Self.provider)-\(Self.fnv1a(fingerprint))"
      if let existing = inFlight[requestKey] {
        return try Self.decode(try await Self.awaitData(existing))
      }
      let task = Task {
        try await self.loadData(
          request,
          requestKey: requestKey,
          fingerprint: fingerprint,
          endpoint: endpoint,
          locale: locale,
          ttlMilliseconds: ttlMilliseconds
        )
      }
      inFlight[requestKey] = task
      defer { inFlight[requestKey] = nil }
      let data = try await Self.awaitData(task)
      try Task.checkCancellation()
      return try Self.decode(data)
    } catch let error as SDKError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw SDKError(code: .networkUnavailable, message: "test media service is unavailable")
    }
  }

  private func loadData(
    _ originalRequest: URLRequest,
    requestKey: String,
    fingerprint: String,
    endpoint: String,
    locale: String,
    ttlMilliseconds: Int64
  ) async throws -> Data {
    let now = Self.nowMilliseconds()
    let cached = try? await cacheStore.providerResponse(
      requestKey: requestKey,
      requestFingerprint: fingerprint
    )
    if let cached, cached.isFresh(at: now) {
      guard let responseJSON = cached.responseJSON else {
        throw SDKError(code: .metadataNotFound, message: "media service cached no match")
      }
      return Data(responseJSON.utf8)
    }
    if let suspendedError { throw suspendedError }

    var request = originalRequest
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if request.httpMethod == nil || request.httpMethod == "GET" {
      if let entityTag = cached?.entityTag {
        request.setValue(entityTag, forHTTPHeaderField: "If-None-Match")
      }
      if let lastModified = cached?.lastModified {
        request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
      }
    }

    var lastError = SDKError(
      code: .remoteUnavailable,
      message: "test media service is unavailable"
    )
    for attempt in 0..<Self.maximumAttempts {
      try Task.checkCancellation()
      try await waitForRequestSlot()
      do {
        let (data, rawResponse) = try await session.data(for: request)
        guard let response = rawResponse as? HTTPURLResponse else {
          throw SDKError(code: .remoteUnavailable, message: "media service response is invalid")
        }
        let status = response.statusCode
        if status == 304, let cached, let responseJSON = cached.responseJSON {
          let refreshed = try MetadataProviderResponseCacheEntry(
            requestKey: requestKey,
            provider: Self.provider,
            endpoint: endpoint,
            requestFingerprint: fingerprint,
            locale: locale,
            httpStatus: cached.httpStatus,
            entityTag: response.value(forHTTPHeaderField: "ETag") ?? cached.entityTag,
            lastModified: response.value(forHTTPHeaderField: "Last-Modified")
              ?? cached.lastModified,
            responseJSON: responseJSON,
            fetchedAtMilliseconds: now,
            expiresAtMilliseconds: now + ttlMilliseconds
          )
          try? await cacheStore.storeProviderResponse(refreshed)
          return Data(responseJSON.utf8)
        }
        if (200...299).contains(status) {
          guard data.count <= Self.maximumResponseBytes else {
            throw SDKError(
              code: .parseFailure,
              message: "media service response exceeds the size limit"
            )
          }
          guard let responseJSON = String(data: data, encoding: .utf8) else {
            throw SDKError(code: .parseFailure, message: "media service response is invalid")
          }
          let storedAt = Self.nowMilliseconds()
          let entry = try MetadataProviderResponseCacheEntry(
            requestKey: requestKey,
            provider: Self.provider,
            endpoint: endpoint,
            requestFingerprint: fingerprint,
            locale: locale,
            httpStatus: status,
            entityTag: response.value(forHTTPHeaderField: "ETag"),
            lastModified: response.value(forHTTPHeaderField: "Last-Modified"),
            responseJSON: responseJSON,
            fetchedAtMilliseconds: storedAt,
            expiresAtMilliseconds: storedAt + ttlMilliseconds
          )
          try? await cacheStore.storeProviderResponse(entry)
          return data
        }
        if status == 404 {
          let storedAt = Self.nowMilliseconds()
          let entry = try MetadataProviderResponseCacheEntry(
            requestKey: requestKey,
            provider: Self.provider,
            endpoint: endpoint,
            requestFingerprint: fingerprint,
            locale: locale,
            httpStatus: status,
            fetchedAtMilliseconds: storedAt,
            expiresAtMilliseconds: storedAt + Self.negativeTTLMilliseconds
          )
          try? await cacheStore.storeProviderResponse(entry)
          throw SDKError(code: .metadataNotFound, message: "media service returned no match")
        }
        if status == 401 || status == 403 {
          let error = SDKError(
            code: status == 401 ? .unauthorized : .forbidden,
            message: "test media service returned HTTP \(status)"
          )
          suspendedError = error
          throw error
        }

        let retryAfter = Self.retryAfterMilliseconds(response)
        let code: SDKErrorCode = status == 429 ? .rateLimited : .remoteUnavailable
        lastError = SDKError(
          code: code,
          message: "test media service returned HTTP \(status)",
          retryAfterMilliseconds: retryAfter
        )
        guard status == 429 || (500...599).contains(status),
          attempt + 1 < Self.maximumAttempts
        else { throw lastError }
        try await backOff(attempt: attempt, retryAfterMilliseconds: retryAfter)
      } catch let error as SDKError {
        if ![.networkUnavailable, .remoteUnavailable, .rateLimited].contains(error.code) {
          throw error
        }
        lastError = error
        guard attempt + 1 < Self.maximumAttempts else { throw error }
        try await backOff(
          attempt: attempt,
          retryAfterMilliseconds: error.retryAfterMilliseconds
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        lastError = SDKError(
          code: .networkUnavailable,
          message: "test media service is unavailable"
        )
        guard attempt + 1 < Self.maximumAttempts else { throw lastError }
        try await backOff(attempt: attempt, retryAfterMilliseconds: nil)
      }
    }
    throw lastError
  }

  private func waitForRequestSlot() async throws {
    let now = Self.nowMilliseconds()
    let scheduledAt = max(now, nextRequestAtMilliseconds)
    nextRequestAtMilliseconds = scheduledAt + Self.minimumRequestIntervalMilliseconds
    if scheduledAt > now {
      try await Task.sleep(for: .milliseconds(scheduledAt - now))
    }
  }

  private func backOff(attempt: Int, retryAfterMilliseconds: Int64?) async throws {
    let exponential = Int64(500 * (1 << attempt))
    let jitter = Int64.random(in: 0...250)
    let delay = max(retryAfterMilliseconds ?? 0, exponential + jitter)
    nextRequestAtMilliseconds = max(
      nextRequestAtMilliseconds,
      Self.nowMilliseconds() + delay
    )
    try await Task.sleep(for: .milliseconds(delay))
  }

  private static func decode<Response: Decodable & Sendable>(_ data: Data) throws -> Response {
    guard data.count <= maximumResponseBytes else {
      throw SDKError(
        code: .parseFailure,
        message: "media service response exceeds the size limit"
      )
    }
    do {
      return try JSONDecoder().decode(Response.self, from: data)
    } catch {
      throw SDKError(code: .parseFailure, message: "media service response is invalid")
    }
  }

  private static func awaitData(_ task: Task<Data, Error>) async throws -> Data {
    try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private static func requestFingerprint(_ request: URLRequest) -> String {
    let method = request.httpMethod ?? "GET"
    let url = request.url?.absoluteString ?? ""
    let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
    return "\(method)\n\(url)\n\(body)"
  }

  private static func fnv1a(_ value: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return String(hash, radix: 16)
  }

  private static func retryAfterMilliseconds(_ response: HTTPURLResponse) -> Int64? {
    guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
    if let seconds = Double(value), seconds >= 0 {
      return Int64((seconds * 1_000).rounded(.up))
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
    guard let date = formatter.date(from: value) else { return nil }
    return max(0, Int64((date.timeIntervalSinceNow * 1_000).rounded(.up)))
  }

  private static func nowMilliseconds() -> Int64 {
    Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
  }

  private static func year(from date: String?) -> Int? {
    guard let date, date.count >= 4 else { return nil }
    return Int(date.prefix(4))
  }

  private static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    return (error as? SDKError)?.code == .cancelled
  }
}

private final class TestMediaInfoRedirectBlocker: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable
{
  func urlSession(
    _: URLSession,
    task _: URLSessionTask,
    willPerformHTTPRedirection _: HTTPURLResponse,
    newRequest _: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

private struct MediaInfoResolveRequest: Encodable, Sendable {
  let path: String
  let locale: String
}

private struct MediaInfoResolution: Decodable, Sendable {
  let parsedCandidates: [MediaInfoParsedCandidate]
  let selected: MediaInfoSelectedMatch?

  var primaryCandidate: MediaInfoParsedCandidate? { parsedCandidates.first }

  func makeMatchQuery() throws -> MediaMatchQuery {
    guard let candidate = primaryCandidate else {
      throw SDKError(code: .metadataNotFound, message: "media service returned no parsed candidate")
    }
    if candidate.kind == "movie" {
      return try MediaMatchQuery(kind: .movie, title: candidate.title, year: candidate.year)
    }
    guard let season = candidate.season, let episode = candidate.episode else {
      throw SDKError(code: .metadataNotFound, message: "series file has no episode coordinate")
    }
    return try MediaMatchQuery(
      kind: .episode,
      title: candidate.title,
      year: candidate.year,
      season: season,
      episode: episode
    )
  }

  private enum CodingKeys: String, CodingKey {
    case parsedCandidates = "parsed_candidates"
    case selected
  }
}

private struct MediaInfoParsedCandidate: Decodable, Sendable {
  let kind: String
  let title: String
  let year: Int?
  let season: Int?
  let episode: Int?
}

private struct MediaInfoSelectedMatch: Decodable, Sendable {
  let objectID: String
  let objectKind: String
  let seriesID: String?
  let title: String
  let originalTitle: String?
  let year: Int?
  let overview: String?
  let artworkID: String?

  private enum CodingKeys: String, CodingKey {
    case objectID = "object_id"
    case objectKind = "object_kind"
    case seriesID = "series_id"
    case title
    case originalTitle = "original_title"
    case year
    case overview
    case artworkID = "artwork_id"
  }
}

private struct MediaInfoEntity: Decodable, Sendable {
  let title: String?
  let originalTitle: String?
  let overview: String?
  let firstAirDate: String?

  private enum CodingKeys: String, CodingKey {
    case title
    case originalTitle = "original_title"
    case overview
    case firstAirDate = "first_air_date"
  }
}

private struct MediaInfoArtworkPage: Decodable, Sendable {
  let items: [MediaInfoArtworkSummary]
}

private struct MediaInfoArtworkSummary: Decodable, Sendable {
  let artworkID: String
  let artworkKind: String

  private enum CodingKeys: String, CodingKey {
    case artworkID = "artwork_id"
    case artworkKind = "artwork_kind"
  }
}

private struct MediaInfoArtworkVariantPage: Decodable, Sendable {
  let items: [MediaInfoArtworkVariant]
}

private struct MediaInfoArtworkVariant: Decodable, Sendable {
  let url: String
  let width: Int?
  let height: Int?
}

private struct ResolvedArtworkVariant: Sendable {
  let url: URL
  let width: Int?
  let height: Int?

  var pixelArea: Int64 {
    Int64(width ?? 0) * Int64(height ?? 0)
  }
}

private struct ResolvedPosterMetadata: Sendable {
  static let provider = "stellar-media-info-test"

  let rootObjectID: String
  let kind: PosterWallMediaKind
  let title: String
  let originalTitle: String?
  let overview: String?
  let year: Int?
  let artworkID: String?

  func makeCandidate(for query: MediaMatchQuery) throws -> MediaMetadataCandidate {
    let parsedKind: ParsedMediaKind = kind == .movie ? .movie : .series
    let availableEpisodes: [MediaEpisodeCoordinate]
    if query.kind == .episode, let season = query.season, let episode = query.episode {
      availableEpisodes = [try MediaEpisodeCoordinate(season: season, episode: episode)]
    } else {
      availableEpisodes = []
    }
    return try MediaMetadataCandidate(
      provider: Self.provider,
      candidateID: rootObjectID,
      kind: parsedKind,
      title: query.title ?? title,
      originalTitle: originalTitle,
      aliases: title == query.title ? [] : [title],
      year: year,
      availableEpisodes: availableEpisodes,
      popularity: 1
    )
  }
}

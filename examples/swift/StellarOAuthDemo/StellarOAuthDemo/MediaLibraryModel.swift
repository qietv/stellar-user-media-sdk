import Combine
import CryptoKit
import Foundation
import StellarSMB2Apple
import StellarSMB2Core
import StellarUserMediaSDK

private struct DemoScanTraversalPolicy: MediaScanTraversalPolicy {
  // File containers advertised by Infuse plus STRM playlist pointers. Optical-disc directory
  // structures are admitted separately by OpticalDiscMediaScanClassifier below.
  private static let videoExtensions: Set<String> = [
    "3gp", "asf", "avi", "divx", "dvr-ms", "flv", "img", "iso", "m2ts", "m4v",
    "media", "mkv", "mov", "mp4", "mpeg", "mpg", "mts", "mxf", "ogm", "ogv", "strm",
    "ts", "vob", "vwtv", "webm", "wm", "wmv",
  ]
  private static let excludedNames: Set<String> = [
    "#recycle", "$recycle.bin", "@eadir", "@recycle", "lost+found",
    "system volume information",
  ]

  func shouldIndexFile(_ entry: RemoteEntry) -> Bool {
    Self.isSupportedMediaFileName(entry.locator.path.name)
  }

  static func isSupportedMediaFileName(_ name: String) -> Bool {
    guard let separator = name.utf8.lastIndex(of: 46), separator != name.startIndex else {
      return false
    }
    let extensionStart = name.index(after: separator)
    guard extensionStart != name.endIndex else { return false }
    return Self.videoExtensions.contains(name[extensionStart...].lowercased())
  }

  func shouldTraverseDirectory(_ entry: RemoteEntry) -> Bool {
    let name = entry.locator.path.name
    guard name.utf8.first != 46 else { return false }
    return !Self.excludedNames.contains(name.lowercased())
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

private struct DemoThumbnailWorkContext: Sendable {
  let session: any MediaSourceSession
  let cacheRoot: URL
  let generator: any MediaScreenshotGenerating
}

private struct DemoLocalMetadataLoad: Sendable {
  let batch: MediaMetadataIntakeBatch
  let preferredMetadata: LocalMetadataDocument?
}

/// Loads bounded local metadata beside a media item without making sidecars library files.
/// Directory pages are shared by concurrent workers and retained in a small LRU for the run.
private actor DemoLocalMetadataLoader {
  private static let directoryPageSize = 2_000
  private static let maximumCachedDirectories = 64
  private static let maximumMetadataDocumentBytes = 2 * 1_024 * 1_024

  private let session: any MediaSourceSession
  private let filenameParser = MediaFilenameParser()
  private let sidecarClassifier = MediaSidecarClassifier()
  private let nfoParser = NFOParser(maximumDocumentBytes: maximumMetadataDocumentBytes)
  private let jsonParser = LocalMetadataJSONParser(
    maximumDocumentBytes: maximumMetadataDocumentBytes
  )
  private var directoryCache: [RemoteLocator: [RemoteEntry]] = [:]
  private var directoryLRU: [RemoteLocator] = []
  private var directoryLoads: [RemoteLocator: Task<[RemoteEntry], Error>] = [:]

  init(session: any MediaSourceSession) {
    self.session = session
  }

  func load(for file: LibraryFileFact) async throws -> DemoLocalMetadataLoad {
    let mediaPath = try RemotePath(file.relativePath)
    let filename = try filenameParser.analyze(file.relativePath)
    let root = try RemotePath()
    var candidateDirectories: [RemotePath] = [mediaPath.parent ?? root]

    // A compound BDMV/DVD item is represented by its outer directory. Inspect that directory
    // for movie.nfo, artwork, and subtitles without indexing its internal transport files.
    if !DemoScanTraversalPolicy.isSupportedMediaFileName(mediaPath.name),
      let entry = try? await session.stat(
        RemoteLocator(sourceUID: file.sourceUID, path: mediaPath)
      ), entry.kind == .directory
    {
      candidateDirectories.insert(mediaPath, at: 0)
    }

    // Kodi-style tvshow.nfo and series artwork commonly live one level above Season NN.
    if let parent = mediaPath.parent, Self.isSeasonDirectory(parent.name),
      let seriesDirectory = parent.parent
    {
      candidateDirectories.append(seriesDirectory)
    }

    var sidecarsByPath: [String: MediaSidecarIntake] = [:]
    for directoryPath in candidateDirectories {
      let directory = try RemoteLocator(sourceUID: file.sourceUID, path: directoryPath)
      let classificationMediaPath = try directoryPath.appending(component: mediaPath.name)
      for entry in try await entries(in: directory) where entry.kind == .file {
        guard
          let descriptor = try sidecarClassifier.classify(
            mediaPath: classificationMediaPath.relativePath,
            candidatePath: entry.locator.path.relativePath
          )
        else { continue }
        sidecarsByPath[descriptor.relativePath] = try await intake(
          descriptor: descriptor,
          entry: entry
        )
      }
    }

    let sidecars = sidecarsByPath.values.sorted {
      $0.descriptor.relativePath < $1.descriptor.relativePath
    }
    let batch = try MediaMetadataIntakeBatch(
      sourceUID: file.sourceUID,
      mediaRelativePath: file.relativePath,
      filename: filename,
      sidecars: sidecars
    )
    return DemoLocalMetadataLoad(
      batch: batch,
      preferredMetadata: Self.preferredMetadata(
        in: sidecars,
        mediaStem: (mediaPath.name as NSString).deletingPathExtension
      )
    )
  }

  private func entries(in directory: RemoteLocator) async throws -> [RemoteEntry] {
    if let cached = directoryCache[directory] {
      touch(directory)
      return cached
    }
    let task: Task<[RemoteEntry], Error>
    if let active = directoryLoads[directory] {
      task = active
    } else {
      task = Task { [session] in
        try await Self.loadDirectory(directory, using: session)
      }
      directoryLoads[directory] = task
    }
    do {
      let loaded = try await task.value
      directoryLoads[directory] = nil
      directoryCache[directory] = loaded
      touch(directory)
      while directoryLRU.count > Self.maximumCachedDirectories {
        directoryCache[directoryLRU.removeFirst()] = nil
      }
      return loaded
    } catch {
      directoryLoads[directory] = nil
      throw error
    }
  }

  private nonisolated static func loadDirectory(
    _ directory: RemoteLocator,
    using session: any MediaSourceSession
  ) async throws -> [RemoteEntry] {
    var entries: [RemoteEntry] = []
    var cursor: String?
    repeat {
      let page = try await session.listDirectory(
        RemoteDirectoryPageRequest(
          directory: directory,
          cursor: cursor,
          limit: Self.directoryPageSize
        )
      )
      entries.append(contentsOf: page.items)
      cursor = page.nextCursor
    } while cursor != nil
    return entries
  }

  private func touch(_ directory: RemoteLocator) {
    directoryLRU.removeAll { $0 == directory }
    directoryLRU.append(directory)
  }

  private func intake(
    descriptor: MediaSidecarDescriptor,
    entry: RemoteEntry
  ) async throws -> MediaSidecarIntake {
    guard descriptor.kind == .nfo || descriptor.kind == .metadataJSON else {
      return try MediaSidecarIntake(
        descriptor: descriptor,
        modifiedAtMilliseconds: entry.modifiedAtMilliseconds
      )
    }
    guard entry.size != 0,
      entry.size.map({ $0 <= Int64(Self.maximumMetadataDocumentBytes) }) ?? true
    else {
      return try MediaSidecarIntake(
        descriptor: descriptor,
        modifiedAtMilliseconds: entry.modifiedAtMilliseconds
      )
    }

    let requestedLength = entry.size.flatMap(Int.init) ?? Self.maximumMetadataDocumentBytes + 1
    let data = try await session.read(
      at: entry.locator,
      range: RemoteByteRange(
        offset: 0,
        length: min(requestedLength, Self.maximumMetadataDocumentBytes + 1)
      )
    )
    guard !data.isEmpty, data.count <= Self.maximumMetadataDocumentBytes else {
      return try MediaSidecarIntake(
        descriptor: descriptor,
        modifiedAtMilliseconds: entry.modifiedAtMilliseconds
      )
    }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let metadata: LocalMetadataDocument?
    do {
      metadata =
        descriptor.kind == .nfo
        ? try nfoParser.parse(data)
        : try jsonParser.parse(data)
    } catch let error as SDKError where error.code == .parseFailure {
      // A malformed optional sidecar remains visible for diagnostics but cannot block the
      // filename/online fallback for an otherwise playable media item.
      metadata = nil
    }
    return try MediaSidecarIntake(
      descriptor: descriptor,
      modifiedAtMilliseconds: entry.modifiedAtMilliseconds,
      sha256: digest,
      metadata: metadata
    )
  }

  private static func preferredMetadata(
    in sidecars: [MediaSidecarIntake],
    mediaStem: String
  ) -> LocalMetadataDocument? {
    sidecars
      .filter { $0.metadata != nil }
      .max { lhs, rhs in
        metadataPriority(lhs, mediaStem: mediaStem)
          < metadataPriority(rhs, mediaStem: mediaStem)
      }?
      .metadata
  }

  private static func metadataPriority(
    _ intake: MediaSidecarIntake,
    mediaStem: String
  ) -> Int {
    let sidecarStem = (intake.descriptor.relativePath as NSString)
      .lastPathComponent as NSString
    let isMediaSpecific = sidecarStem.deletingPathExtension.caseInsensitiveCompare(mediaStem)
      == .orderedSame
    let hasExplicitID = intake.metadata?.externalIDs.isEmpty == false
    return (hasExplicitID ? 100 : 0) + (isMediaSpecific ? 20 : 0)
      + (intake.descriptor.kind == .nfo ? 2 : 1)
  }

  private static func isSeasonDirectory(_ name: String) -> Bool {
    name.range(
      of: #"^(?:season|series|s)[\s._-]*\d{1,3}$"#,
      options: [.regularExpression, .caseInsensitive]
    ) != nil
  }
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
  @Published var prefetchVideoThumbnailsWhenIdle = false
  @Published var enableTechnicalProbe = false

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

  var canRepair: Bool {
    scanTask == nil && libraryStore != nil && sourceUIDForRecovery() != nil
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

  func repairFailedMetadata() {
    guard canRepair else { return }
    scanTask = Task { [weak self] in
      await self?.runRepair()
    }
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

      let supportFolder = try applicationSupportFolder()
      posterItems = allItems.map { item in
        return DemoPosterItem(
          mediaUID: item.mediaUID,
          kind: item.kind,
          title: item.title,
          originalTitle: nil,
          overview: nil,
          year: item.year,
          artworkURL: Self.artworkURL(item.poster, supportFolder: supportFolder),
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
      let wall = try PosterWallStore(database: libraryDatabase)
      var details = try await wall.details(
        mediaUID: item.mediaUID,
        locale: "zh-CN"
      )
      if details.item.poster == nil {
        try? await generateOnDemandThumbnail(from: details)
        details = try await wall.details(mediaUID: item.mediaUID, locale: "zh-CN")
      }
      let supportFolder = try applicationSupportFolder()
      return DemoPosterItem(
        mediaUID: item.mediaUID,
        kind: item.kind,
        title: details.item.title,
        originalTitle: details.originalTitle,
        overview: details.overview,
        year: details.item.year,
        artworkURL: Self.artworkURL(details.item.poster, supportFolder: supportFolder),
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
        let connection = try makeConnection()
        guard connection.sourceUID == sourceUID else {
          throw SDKError(code: .invalidConfiguration, message: "metadata recovery source changed")
        }
        let metadataSession = try await connection.connector.connect()
        let localMetadataLoader = DemoLocalMetadataLoader(session: metadataSession)
        scanState = .enriching
        show("Continuing durable metadata work without rescanning the SMB source…")
        do {
          try await enrichLibrary(
            sourceUID: sourceUID,
            libraryStore: libraryStore,
            metadataCacheStore: metadataCacheStore,
            mediaInfoClient: mediaInfoClient,
            localMetadataLoader: localMetadataLoader
          )
        } catch {
          await metadataSession.disconnect()
          throw error
        }
        await metadataSession.disconnect()
        if prefetchVideoThumbnailsWhenIdle || enableTechnicalProbe {
          await runConfiguredOptionalWorkIfPossible(
            sourceUID: sourceUID,
            libraryStore: libraryStore,
            mediaInfoClient: mediaInfoClient
          )
        }
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
            "Metadata completed: \(mediaFileCount) media items, \(matchedFileCount) matched, "
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
        observer: DemoScanObserver(relay: relay),
        traversalPolicy: DemoScanTraversalPolicy(),
        directoryClassifier: try OpticalDiscMediaScanClassifier()
      )

      flushScanProgress()
      scanState = .enriching
      show("Reading local metadata and matching media with the test service…")
      let metadataSession = try await connection.connector.connect()
      let localMetadataLoader = DemoLocalMetadataLoader(session: metadataSession)
      do {
        try await enrichLibrary(
          sourceUID: request.sourceUID,
          libraryStore: libraryStore,
          metadataCacheStore: metadataCacheStore,
          mediaInfoClient: mediaInfoClient,
          localMetadataLoader: localMetadataLoader
        )
      } catch {
        await metadataSession.disconnect()
        throw error
      }
      await metadataSession.disconnect()
      if prefetchVideoThumbnailsWhenIdle || enableTechnicalProbe {
        await runConfiguredOptionalWorkIfPossible(
          sourceUID: request.sourceUID,
          libraryStore: libraryStore,
          mediaInfoClient: mediaInfoClient
        )
      }
      try Task.checkCancellation()
      _ = try await libraryStore.runGarbageCollection()

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
        "Scan completed: \(mediaFileCount) media items, \(matchedFileCount) matched, "
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
    mediaInfoClient: TestMediaInfoClient,
    localMetadataLoader: DemoLocalMetadataLoader,
    thumbnailContext: DemoThumbnailWorkContext? = nil
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
    let metadataStore = SQLiteMediaMetadataStore(store: libraryStore)
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
            mediaInfoClient: mediaInfoClient,
            localMetadataLoader: localMetadataLoader,
            metadataStore: metadataStore
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
        show("Matched or classified \(completedCount) changed media items…")

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
              mediaInfoClient: mediaInfoClient,
              localMetadataLoader: localMetadataLoader,
              metadataStore: metadataStore
            )
          }
        }
      }
    }

    let finalSummary = try await libraryStore.sourceMediaSummary(sourceUID: sourceUID)
    mediaFileCount = finalSummary.presentFileCount
    matchedFileCount = finalSummary.matchedFileCount
    await refreshPosterWall()
    try Task.checkCancellation()
    show("Fetching optional posters…")
    try await enrichArtwork(
      sourceUID: sourceUID,
      libraryStore: libraryStore,
      mediaInfoClient: mediaInfoClient,
      thumbnailContext: thumbnailContext
    )
  }

  private func enrichArtwork(
    sourceUID: String,
    libraryStore: LibraryStore,
    mediaInfoClient: TestMediaInfoClient,
    thumbnailContext: DemoThumbnailWorkContext? = nil,
    maximumItems: Int? = nil
  ) async throws {
    let workerID = "stellar-oauth-demo-artwork-\(UUID().uuidString.lowercased())"
    let workerConcurrency = thumbnailContext == nil ? 2 : 1
    try await withThrowingTaskGroup(of: String.self) { group in
      var activeWorkerCount = 0
      var startedCount = 0
      let initialLimit = min(workerConcurrency, maximumItems ?? workerConcurrency)
      let initialLeases = try await libraryStore.claimScanFileWork(
        sourceUID: sourceUID,
        stage: .artwork,
        workerID: workerID,
        limit: initialLimit,
        leaseDurationMilliseconds: 120_000
      )
      for lease in initialLeases {
        activeWorkerCount += 1
        startedCount += 1
        group.addTask {
          try await Self.processArtworkWork(
            DemoMetadataWorkItem(lease: lease),
            libraryStore: libraryStore,
            mediaInfoClient: mediaInfoClient,
            thumbnailContext: thumbnailContext
          )
        }
      }

      var completedCount = 0
      while activeWorkerCount > 0, let path = try await group.next() {
        activeWorkerCount -= 1
        completedCount += 1
        updateCurrentFile(path)
        show("Fetched or classified \(completedCount) posters…")

        try Task.checkCancellation()
        if maximumItems.map({ startedCount < $0 }) ?? true,
          let replacementLease = try await libraryStore.claimScanFileWork(
            sourceUID: sourceUID,
            stage: .artwork,
            workerID: workerID,
            limit: 1,
            leaseDurationMilliseconds: 120_000
          ).first
        {
          activeWorkerCount += 1
          startedCount += 1
          group.addTask {
            try await Self.processArtworkWork(
              DemoMetadataWorkItem(lease: replacementLease),
              libraryStore: libraryStore,
              mediaInfoClient: mediaInfoClient,
              thumbnailContext: thumbnailContext
            )
          }
        }
      }
    }
  }

  private nonisolated static func processMetadataWork(
    _ workItem: DemoMetadataWorkItem,
    sourceUID: String,
    matcher: SQLiteMediaMatcher,
    libraryStore: LibraryStore,
    mediaInfoClient: TestMediaInfoClient,
    localMetadataLoader: DemoLocalMetadataLoader,
    metadataStore: SQLiteMediaMetadataStore
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
      let local = try await localMetadataLoader.load(for: workItem.file)
      try await metadataStore.persist(local.batch)
      let localQuery = try? MediaMatchQueryBuilder().build(
        filename: local.batch.filename.parsed,
        localMetadata: local.preferredMetadata
      )
      let resolution = try await mediaInfoClient.resolve(path: path)
      guard let resolved = try await mediaInfoClient.primaryMetadata(from: resolution) else {
        throw SDKError(
          code: .metadataNotFound,
          message: "the media service returned no usable metadata"
        )
      }
      let query: MediaMatchQuery
      if let localQuery {
        query = localQuery
      } else {
        query = try resolution.makeMatchQuery()
      }
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

      let metadata = try LibraryRemoteMetadata(
        provider: ResolvedPosterMetadata.provider,
        providerID: resolved.rootObjectID,
        kind: resolved.kind == .movie ? .movie : .series,
        locale: "zh-CN",
        title: resolved.title,
        originalTitle: resolved.originalTitle,
        overview: resolved.overview,
        year: resolved.year
      )
      _ = try await libraryStore.commitRemoteMetadata(
        metadata,
        completing: workItem.lease,
        enqueueArtwork: true
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
      if workItem.lease.attempts + 1 >= 3 {
        try await libraryStore.failScanWork(workItem.lease, errorCode: code)
      } else {
        try await libraryStore.retryScanWork(
          workItem.lease,
          errorCode: code,
          retryAfterMilliseconds: retryDelay
        )
      }
      return .retry(path: path)
    }
  }

  private nonisolated static func processArtworkWork(
    _ workItem: DemoMetadataWorkItem,
    libraryStore: LibraryStore,
    mediaInfoClient: TestMediaInfoClient,
    thumbnailContext: DemoThumbnailWorkContext?
  ) async throws -> String {
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
    var failure: Error?
    do {
      let target = try await libraryStore.remoteArtworkTarget(
        for: workItem.lease,
        provider: ResolvedPosterMetadata.provider
      )
      guard let variant = try await mediaInfoClient.bestArtwork(for: target, path: path) else {
        throw SDKError(code: .metadataNotFound, message: "the provider has no poster")
      }
      let artwork = try LibraryRemoteArtwork(
        target: target,
        locale: "zh-CN",
        remoteURL: variant.url.absoluteString,
        width: variant.width,
        height: variant.height
      )
      _ = try await libraryStore.storeRemoteArtwork(artwork, for: workItem.lease)
    } catch {
      if Self.isCancellation(error) {
        try? await libraryStore.retryScanWork(
          workItem.lease,
          errorCode: .cancelled,
          retryAfterMilliseconds: 0
        )
        throw error
      }
      // A missing provider poster is not a failure when this run can still produce a local
      // thumbnail. Other errors remain durable so repair can retry them independently later.
      if (error as? SDKError)?.code != .metadataNotFound || thumbnailContext == nil {
        failure = error
      }
    }

    var completedByThumbnail = false
    if let thumbnailContext {
      do {
        let locator = try RemoteLocator(
          sourceUID: workItem.file.sourceUID,
          path: RemotePath(path)
        )
        let result = try await thumbnailContext.generator.capture(
          locator,
          using: thumbnailContext.session,
          request: MediaScreenshotRequest(
            timestampMilliseconds: 0,
            format: .jpeg,
            maximumPixelDimension: 1_280,
            jpegQuality: 0.82
          )
        )
        let thumbnail = try storeThumbnail(result, cacheRoot: thumbnailContext.cacheRoot)
        if failure == nil {
          _ = try await libraryStore.commitGeneratedThumbnail(thumbnail, for: workItem.lease)
          completedByThumbnail = true
        } else {
          _ = try await libraryStore.storeGeneratedThumbnail(thumbnail, for: workItem.lease)
        }
      } catch {
        if Self.isCancellation(error) {
          try? await libraryStore.retryScanWork(
            workItem.lease,
            errorCode: .cancelled,
            retryAfterMilliseconds: 0
          )
          throw error
        }
        if failure == nil { failure = error }
      }
    }

    guard let failure else {
      if !completedByThumbnail {
        try await libraryStore.completeScanWork(workItem.lease)
      }
      return path
    }
    let code = (failure as? SDKError)?.code ?? .unknown
    if code == .metadataNotFound || code == .parseFailure || workItem.lease.attempts + 1 >= 3 {
      try await libraryStore.failScanWork(workItem.lease, errorCode: code)
      return path
    }
    let providerDelay = (failure as? SDKError)?.retryAfterMilliseconds
    let retryDelay = max(
      providerDelay ?? 0,
      min(300_000, 5_000 * Int64(1 << min(workItem.lease.attempts, 5)))
    )
    try await libraryStore.retryScanWork(
      workItem.lease,
      errorCode: code,
      retryAfterMilliseconds: retryDelay
    )
    return path
  }

  private nonisolated static func storeThumbnail(
    _ result: MediaScreenshotResult,
    cacheRoot: URL
  ) throws -> LibraryGeneratedThumbnail {
    let digest = SHA256.hash(data: result.data).map { String(format: "%02x", $0) }.joined()
    let fileExtension = result.format == .png ? "png" : "jpg"
    let relativePath = "thumbnails/\(digest).\(fileExtension)"
    let folder = cacheRoot.appendingPathComponent("thumbnails", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let destination = cacheRoot.appendingPathComponent(relativePath)
    if !FileManager.default.fileExists(atPath: destination.path) {
      try result.data.write(to: destination, options: .atomic)
    }
    return try LibraryGeneratedThumbnail(
      localRelativePath: relativePath,
      sha256: digest,
      mimeType: result.mimeType,
      width: result.width,
      height: result.height
    )
  }

  private func runConfiguredOptionalWorkIfPossible(
    sourceUID: String,
    libraryStore: LibraryStore,
    mediaInfoClient: TestMediaInfoClient
  ) async {
    guard !password.isEmpty else {
      show("Optional thumbnail/probe work is waiting for the SMB password.")
      return
    }
    do {
      let connection = try makeConnection()
      guard connection.sourceUID == sourceUID else {
        throw SDKError(code: .invalidConfiguration, message: "optional work source changed")
      }
      let session = try await connection.connector.connect()
      do {
        let context = DemoThumbnailWorkContext(
          session: session,
          cacheRoot: try applicationSupportFolder(),
          generator: FFmpegMediaScreenshotGenerator()
        )
        if prefetchVideoThumbnailsWhenIdle {
          var scheduled: Int
          repeat {
            scheduled = try await libraryStore.enqueueMissingThumbnailWork(
              sourceUID: sourceUID,
              priority: -100,
              limit: 200
            )
            if scheduled > 0 {
              show("Generating optional video thumbnails…")
              try await enrichArtwork(
                sourceUID: sourceUID,
                libraryStore: libraryStore,
                mediaInfoClient: mediaInfoClient,
                thumbnailContext: context
              )
            }
          } while scheduled == 200
        }
        if enableTechnicalProbe {
          var scheduled: Int
          repeat {
            scheduled = try await libraryStore.enqueueMissingProbeWork(
              sourceUID: sourceUID,
              probeVersion: FFmpegMediaTechnicalProbe.version,
              priority: -200,
              limit: 200
            )
            if scheduled > 0 {
              show("Inspecting optional technical metadata…")
              try await enrichProbeWork(
                sourceUID: sourceUID,
                libraryStore: libraryStore,
                session: session
              )
            }
          } while scheduled == 200
        }
      } catch {
        await session.disconnect()
        throw error
      }
      await session.disconnect()
    } catch {
      show("Optional work deferred: \(Self.message(for: error))")
    }
  }

  private func enrichProbeWork(
    sourceUID: String,
    libraryStore: LibraryStore,
    session: any MediaSourceSession
  ) async throws {
    let workerID = "stellar-oauth-demo-probe-\(UUID().uuidString.lowercased())"
    let metadataStore = SQLiteMediaMetadataStore(store: libraryStore)
    while let lease = try await libraryStore.claimScanFileWork(
      sourceUID: sourceUID,
      stage: .probe,
      workerID: workerID,
      limit: 1,
      leaseDurationMilliseconds: 120_000
    ).first {
      updateCurrentFile(lease.file.relativePath)
      try await Self.processProbeWork(
        DemoMetadataWorkItem(lease: lease),
        libraryStore: libraryStore,
        metadataStore: metadataStore,
        session: session
      )
    }
  }

  private nonisolated static func processProbeWork(
    _ workItem: DemoMetadataWorkItem,
    libraryStore: LibraryStore,
    metadataStore: SQLiteMediaMetadataStore,
    session: any MediaSourceSession
  ) async throws {
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
      let request = try MediaTechnicalProbeRequest(
        locator: RemoteLocator(
          sourceUID: workItem.file.sourceUID,
          path: RemotePath(workItem.file.relativePath)
        ),
        sizeBytes: workItem.file.sizeBytes,
        modifiedAtMilliseconds: workItem.file.modifiedAtMilliseconds,
        entityTag: workItem.file.entityTag
      )
      let result = try await FFmpegMediaTechnicalProbe().probe(request, using: session)
      try await metadataStore.persistTechnicalProbe(result, completing: workItem.lease)
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
      if code == .parseFailure || code == .metadataNotFound || workItem.lease.attempts + 1 >= 3 {
        try await libraryStore.failScanWork(workItem.lease, errorCode: code)
      } else {
        let retryDelay = min(300_000, 5_000 * Int64(1 << min(workItem.lease.attempts, 5)))
        try await libraryStore.retryScanWork(
          workItem.lease,
          errorCode: code,
          retryAfterMilliseconds: retryDelay
        )
      }
    }
  }

  private func generateOnDemandThumbnail(from details: PosterWallDetails) async throws {
    guard scanTask == nil, let libraryStore, let mediaInfoClient, !password.isEmpty else { return }
    let files =
      details.playableFiles
      + details.seasons.flatMap { season in
        season.episodes.flatMap(\.files)
      }
    guard let file = files.first(where: { $0.availability == "present" }) else { return }
    let connection = try makeConnection()
    guard connection.sourceUID == file.sourceUID else { return }
    try await libraryStore.enqueueOptionalScanWork(
      sourceUID: file.sourceUID,
      relativePath: file.relativePath,
      stage: .artwork,
      priority: 1_000
    )
    let session = try await connection.connector.connect()
    do {
      let context = DemoThumbnailWorkContext(
        session: session,
        cacheRoot: try applicationSupportFolder(),
        generator: FFmpegMediaScreenshotGenerator()
      )
      try await enrichArtwork(
        sourceUID: file.sourceUID,
        libraryStore: libraryStore,
        mediaInfoClient: mediaInfoClient,
        thumbnailContext: context,
        maximumItems: 1
      )
    } catch {
      await session.disconnect()
      throw error
    }
    await session.disconnect()
  }

  private func runRepair() async {
    defer { scanTask = nil }
    await prepareIfNeeded()
    guard let libraryStore, let metadataCacheStore, let mediaInfoClient,
      let sourceUID = sourceUIDForRecovery()
    else { return }
    do {
      let connection = try makeConnection()
      guard connection.sourceUID == sourceUID else {
        throw SDKError(code: .invalidConfiguration, message: "repair source changed")
      }
      scanState = .enriching
      let repaired = try await libraryStore.resetFailedScanWork(
        sourceUID: sourceUID,
        stages: [.parse, .artwork, .probe]
      )
      guard repaired > 0 else {
        scanState = .completed
        show("There is no failed metadata work to repair.")
        return
      }
      let session = try await connection.connector.connect()
      do {
        let context = DemoThumbnailWorkContext(
          session: session,
          cacheRoot: try applicationSupportFolder(),
          generator: FFmpegMediaScreenshotGenerator()
        )
        try await enrichLibrary(
          sourceUID: sourceUID,
          libraryStore: libraryStore,
          metadataCacheStore: metadataCacheStore,
          mediaInfoClient: mediaInfoClient,
          localMetadataLoader: DemoLocalMetadataLoader(session: session),
          thumbnailContext: context
        )
        try await enrichProbeWork(
          sourceUID: sourceUID,
          libraryStore: libraryStore,
          session: session
        )
      } catch {
        await session.disconnect()
        throw error
      }
      await session.disconnect()
      scanState = .completed
      updateCurrentFile(nil)
      show("Repair processed \(repaired) failed metadata tasks.")
      await refreshPosterWall()
    } catch {
      scanState = .failed
      updateCurrentFile(nil)
      show(error: error)
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
    } else {
      let hasPrimaryWork = try await libraryStore.hasOutstandingScanWork(
        sourceUID: sourceUID,
        stage: .parse
      )
      let hasArtworkWork = try await libraryStore.hasOutstandingScanWork(
        sourceUID: sourceUID,
        stage: .artwork
      )
      guard hasPrimaryWork || hasArtworkWork else { return }
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
      directoryConnectionCount: 4
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

  private static func artworkURL(
    _ artwork: PosterWallArtwork?,
    supportFolder: URL
  ) -> URL? {
    if let remoteReference = artwork?.remoteReference,
      let url = URL(string: remoteReference)
    {
      return url
    }
    guard let localPath = artwork?.localRelativePath,
      let path = try? RemotePath(localPath), !path.isRoot
    else { return nil }
    return supportFolder.appendingPathComponent(path.relativePath)
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
    try await base.commit(batch)
    await relay.batch(batch.entries, checkpoint: batch.checkpoint)
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
    let request = try Self.resolveRequest(path: path)
    return try await send(
      request,
      endpoint: "resolve",
      locale: "zh-CN",
      ttlMilliseconds: Self.resolveTTLMilliseconds
    )
  }

  func primaryMetadata(from resolution: MediaInfoResolution) async throws -> ResolvedPosterMetadata?
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
        year: resolution.primaryCandidate?.year
      )
      do {
        let resolvedEntity: MediaInfoEntity = try await get(
          pathComponents: ["entities", seriesID],
          queryItems: [URLQueryItem(name: "locale", value: "zh-CN")],
          locale: "zh-CN"
        )
        return ResolvedPosterMetadata(
          rootObjectID: seriesID,
          kind: .series,
          title: resolvedEntity.title ?? fallback.title,
          originalTitle: resolvedEntity.originalTitle,
          overview: resolvedEntity.overview,
          year: Self.year(from: resolvedEntity.firstAirDate) ?? fallback.year
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
      year: selected.year
    )
  }

  func bestArtwork(for target: LibraryRemoteArtworkTarget, path: String) async throws
    -> ResolvedArtworkVariant?
  {
    guard target.provider == Self.provider else {
      throw SDKError(code: .invalidConfiguration, message: "artwork provider is unsupported")
    }
    if let artworkID = await cachedArtworkID(path: path, target: target) {
      return try await bestArtwork(artworkID: artworkID)
    }
    let artworkPage: MediaInfoArtworkPage = try await get(
      pathComponents: ["entities", target.providerID, "artworks"],
      queryItems: [
        URLQueryItem(name: "locale", value: "zh-CN"),
        URLQueryItem(name: "limit", value: "100"),
      ],
      locale: "zh-CN"
    )
    guard
      let artworkID = artworkPage.items.first(where: {
        $0.artworkKind == "poster"
      })?.artworkID
    else { return nil }
    return try await bestArtwork(artworkID: artworkID)
  }

  private func cachedArtworkID(
    path: String,
    target: LibraryRemoteArtworkTarget
  ) async -> String? {
    guard let request = try? Self.resolveRequest(path: path) else { return nil }
    let fingerprint = Self.requestFingerprint(request)
    let requestKey = "\(Self.provider)-\(Self.fnv1a(fingerprint))"
    guard
      let cached = try? await cacheStore.providerResponse(
        requestKey: requestKey,
        requestFingerprint: fingerprint
      ),
      let responseJSON = cached.responseJSON,
      let resolution: MediaInfoResolution = try? Self.decode(Data(responseJSON.utf8)),
      let selected = resolution.selected,
      selected.artworkID != nil
    else { return nil }
    switch target.kind {
    case .movie:
      guard selected.objectKind == "movie", selected.objectID == target.providerID else {
        return nil
      }
    case .series:
      guard selected.objectKind == "series", selected.objectID == target.providerID else {
        return nil
      }
    }
    return selected.artworkID
  }

  private func bestArtwork(artworkID: String) async throws -> ResolvedArtworkVariant? {
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

  private static func resolveRequest(path: String) throws -> URLRequest {
    var request = URLRequest(url: baseURL.appendingPathComponent("resolve"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(
      MediaInfoResolveRequest(path: path, locale: "zh-CN")
    )
    return request
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

import Combine
import CryptoKit
import Foundation
import StellarDiscMedia
import StellarSMB2Apple
import StellarSMB2Core
import StellarUserMediaSDK

private enum DemoMediaAdmission {
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

  static func isSupportedMediaFileName(_ name: String) -> Bool {
    guard let separator = name.utf8.lastIndex(of: 46), separator != name.startIndex else {
      return false
    }
    let extensionStart = name.index(after: separator)
    guard extensionStart != name.endIndex else { return false }
    return Self.videoExtensions.contains(name[extensionStart...].lowercased())
  }

  static func traversalPolicy(for request: MediaScanRequest) throws -> MediaScanPathFilter {
    try MediaScanPathFilter(
      pathSemantics: MediaLibraryModel.smbPathSemantics,
      includedRoots: request.mode == .incremental ? request.roots.map(\.path) : [],
      allowedFileExtensions: videoExtensions,
      excludedDirectoryNames: excludedNames,
      ignoresHiddenDirectories: true,
      exclusionMarkerFileNames: [".nomedia"]
    )
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
  let discDetails: DemoDiscDetails?

  var id: String { mediaUID }
}

struct DemoDiscPlaylist: Identifiable, Equatable, Sendable {
  let identifier: String
  let durationMilliseconds: Int64
  let sizeBytes: Int64
  let segmentCount: Int
  let isDefault: Bool

  var id: String { identifier }
}

struct DemoDiscDetails: Equatable, Sendable {
  let kind: String
  let playlists: [DemoDiscPlaylist]
  let listRequestCount: Int
  let rangeRequestCount: Int
  let bytesRead: Int64
  let elapsedMilliseconds: Int64
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
    if !DemoMediaAdmission.isSupportedMediaFileName(mediaPath.name),
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
    let sidecarStem =
      (intake.descriptor.relativePath as NSString)
      .lastPathComponent as NSString
    let isMediaSpecific =
      sidecarStem.deletingPathExtension.caseInsensitiveCompare(mediaStem)
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
  nonisolated static let smbPathSemantics = RemotePathSemantics(
    caseSensitivity: .insensitive,
    unicodeNormalization: .preserve
  )
  private static let automaticScanInterval = Duration.seconds(15 * 60)

  @Published var server = "172.31.36.200"
  @Published var port = ""
  @Published var share = "video"
  @Published var rootPath = ""
  @Published var username = "coldlake"
  @Published var password = ""
  @Published var scansIncrementalScope = false
  @Published var incrementalScope = ""
  @Published var automaticScanning = false {
    didSet { restartAutomaticScanTimerIfNeeded() }
  }
  @Published var prefetchVideoThumbnailsWhenIdle = false
  @Published var enableTechnicalProbe = false
  @Published var enableDiscProbe = true

  @Published private(set) var scanState: DemoScanState = .idle
  @Published private(set) var isEditingSource = false
  @Published private(set) var notice = "Enter the SMB password, then start a full scan."
  @Published private(set) var noticeIsError = false
  @Published private var scanProgress = DemoScanProgress()
  @Published private(set) var mediaFileCount = 0
  @Published private(set) var matchedFileCount = 0
  @Published private(set) var failedFileCount = 0
  @Published private(set) var posterItems: [DemoPosterItem] = []
  @Published private(set) var isPosterWallLoading = false
  @Published private(set) var posterWallNotice = "Scan an SMB source to build the poster wall."

  @Published private var scanTask: Task<Void, Never>?
  private var automaticScanTask: Task<Void, Never>?
  private var sceneIsActive = false
  private var scanProgressPublishTask: Task<Void, Never>?
  private var pendingScanProgress: DemoScanProgress?
  private var activeRequest: MediaScanRequest?
  private var metadataRecoverySourceUID: String?
  private var libraryDatabase: StorageDatabase?
  private var libraryStore: LibraryStore?
  private var metadataCacheStore: MetadataCacheStore?
  private var mediaInfoClient: TestMediaInfoClient?
  private let scanScheduler = MediaScanScheduler()

  var discoveredEntryCount: Int64 { scanProgress.discoveredEntryCount }
  var processedPageCount: Int64 { scanProgress.processedPageCount }
  var pendingPageCount: Int { scanProgress.pendingPageCount }
  var currentFile: String? { scanProgress.currentFile }

  var canStartOrResume: Bool {
    guard scanTask == nil, [.idle, .paused, .completed, .failed].contains(scanState) else {
      return false
    }
    return scanState == .paused
      || !scansIncrementalScope
      || !incrementalScope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

  var canEditSource: Bool {
    scanTask == nil && scanState == .paused
  }

  func editSource() {
    guard canEditSource else { return }
    // Release only the selected in-memory recovery context. Checkpoints and queued work stay
    // in the library; starting the same source can recover them through the normal scan path.
    isEditingSource = true
    activeRequest = nil
    metadataRecoverySourceUID = nil
    resetScanProgress()
    mediaFileCount = 0
    matchedFileCount = 0
    failedFileCount = 0
    scanState = .idle
    show("Edit the connection, then start scanning. Saved progress for each source is kept.")
  }

  var primaryActionTitle: String {
    if scanState == .paused, metadataRecoverySourceUID != nil {
      return "Resume metadata"
    }
    return switch scanState {
    case .paused: "Resume scan"
    case .completed: scansIncrementalScope ? "Scan scope" : "Scan again"
    default: scansIncrementalScope ? "Scan scope" : "Start scan"
    }
  }

  func setSceneActive(_ isActive: Bool) {
    guard sceneIsActive != isActive else { return }
    sceneIsActive = isActive
    restartAutomaticScanTimerIfNeeded()
  }

  func prepareIfNeeded() async {
    do {
      if libraryStore == nil || metadataCacheStore == nil {
        let databaseStartedAt = ProcessInfo.processInfo.systemUptime
        demoLaunchLogger.notice("phase=media-databases-open-started")
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
        let databaseElapsed = ProcessInfo.processInfo.systemUptime - databaseStartedAt
        demoLaunchLogger.notice(
          "phase=media-databases-open-finished elapsed-seconds=\(databaseElapsed, privacy: .public)"
        )
      }
      let recoveryStartedAt = ProcessInfo.processInfo.systemUptime
      demoLaunchLogger.notice("phase=media-durable-recovery-started")
      try await restoreDurableWorkIfAvailable()
      let recoveryElapsed = ProcessInfo.processInfo.systemUptime - recoveryStartedAt
      demoLaunchLogger.notice(
        "phase=media-durable-recovery-finished elapsed-seconds=\(recoveryElapsed, privacy: .public)"
      )
    } catch {
      demoLaunchLogger.error("phase=media-library-prepare-failed")
      scanState = .failed
      show(error: error)
      posterWallNotice = "The local media library could not be opened."
    }
  }

  func startOrResume() {
    guard canStartOrResume else { return }
    isEditingSource = false
    let requestedMode: MediaScanMode = scansIncrementalScope ? .incremental : .full
    let requestedScope = incrementalScope
    scanTask = Task { [weak self] in
      await self?.runScan(
        origin: .manual,
        requestedMode: requestedMode,
        requestedScope: requestedScope
      )
    }
  }

  private func restartAutomaticScanTimerIfNeeded() {
    automaticScanTask?.cancel()
    automaticScanTask = nil
    guard automaticScanning, sceneIsActive else { return }
    automaticScanTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.automaticScanInterval)
        guard !Task.isCancelled, let self else { return }
        startAutomaticScanIfIdle()
      }
    }
  }

  private func startAutomaticScanIfIdle() {
    guard scanTask == nil, !isEditingSource, !password.isEmpty,
      [.idle, .completed].contains(scanState),
      activeRequest == nil, metadataRecoverySourceUID == nil
    else { return }
    scanTask = Task { [weak self] in
      await self?.runScan(
        origin: .scheduled,
        requestedMode: .full,
        requestedScope: ""
      )
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
    isEditingSource = false
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
          availability: item.availability,
          discDetails: nil
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

  func detailsClient() async throws -> TestMediaInfoClient {
    if mediaInfoClient == nil { await prepareIfNeeded() }
    guard let mediaInfoClient else {
      throw SDKError(code: .storageFailure, message: "The local metadata cache could not be opened.")
    }
    return mediaInfoClient
  }

  func localMediaUID(objectID: String, kind: String) async throws -> String? {
    if libraryDatabase == nil { await prepareIfNeeded() }
    guard let libraryDatabase else { return nil }
    return try await PosterWallStore(database: libraryDatabase).mediaUID(
      provider: ResolvedPosterMetadata.provider, namespace: kind, value: objectID)
  }

  func localDetails(mediaUID: String) async throws -> PosterWallDetails {
    if libraryDatabase == nil { await prepareIfNeeded() }
    guard let libraryDatabase else {
      throw SDKError(code: .storageFailure, message: "The local media library could not be opened.")
    }
    return try await PosterWallStore(database: libraryDatabase).details(mediaUID: mediaUID, locale: "zh-CN")
  }

  func localArtworkURL(_ artwork: PosterWallArtwork?) -> URL? {
    guard let folder = try? applicationSupportFolder() else { return nil }
    return Self.artworkURL(artwork, supportFolder: folder)
  }

  func discDetails(for file: PosterWallPlayableFile) async throws -> DemoDiscDetails? {
    guard let store = libraryStore else { return nil }
    if case .confirmed(let result)? = try await DiscMediaLibrary(store: store).cachedState(
      sourceUID: file.sourceUID, relativePath: file.relativePath
    ) {
      return Self.demoDiscDetails(result)
    }
    return nil
  }

  func requestPosterThumbnail(for details: PosterWallDetails) async -> URL? {
    guard details.item.poster == nil else { return localArtworkURL(details.item.poster) }
    do {
      try await generateOnDemandThumbnail(from: details)
      let updated = try await localDetails(mediaUID: details.item.mediaUID)
      return localArtworkURL(updated.item.poster)
    } catch { return nil }
  }

  private func runScan(
    origin: MediaScanTriggerOrigin,
    requestedMode: MediaScanMode,
    requestedScope: String
  ) async {
    var claimedScheduledRunUID: String?
    defer {
      Task { @MainActor [weak self] in
        if let claimedScheduledRunUID {
          try? await self?.scanScheduler.finish(runUID: claimedScheduledRunUID)
        }
        self?.scanTask = nil
      }
    }
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
        if prefetchVideoThumbnailsWhenIdle || enableTechnicalProbe || enableDiscProbe {
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
        if checkpoint == nil {
          activeRequest = nil
          isResume = false
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
        let roots: [RemoteLocator]
        switch requestedMode {
        case .full:
          roots = [try RemoteLocator(sourceUID: connection.sourceUID, path: RemotePath())]
        case .incremental:
          let scope = requestedScope.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !scope.isEmpty else {
            throw SDKError(
              code: .invalidConfiguration,
              message: "incremental scan scope is required"
            )
          }
          roots = [
            try RemoteLocator(sourceUID: connection.sourceUID, path: RemotePath(scope))
          ]
        case .repair:
          throw SDKError(
            code: .invalidConfiguration,
            message: "repair does not enumerate SMB directories"
          )
        }
        let trigger = try MediaScanTrigger(
          sourceUID: connection.sourceUID,
          mode: requestedMode,
          roots: roots,
          origin: origin,
          submittedAtMilliseconds: Self.nowMilliseconds()
        )
        try await scanScheduler.submit(
          trigger,
          pathSemantics: Self.smbPathSemantics
        )
        guard let scheduled = try await scanScheduler.nextReady(
          atMilliseconds: Self.nowMilliseconds()
        ) else {
          throw SDKError(code: .conflict, message: "SMB source already has active scan work")
        }
        activeRequest = scheduled.request
        claimedScheduledRunUID = scheduled.request.runUID
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
        traversalPolicy: try DemoMediaAdmission.traversalPolicy(for: request),
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
      if prefetchVideoThumbnailsWhenIdle || enableTechnicalProbe || enableDiscProbe {
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
        if enableDiscProbe {
          let discLibrary = DiscMediaLibrary(store: libraryStore)
          var scheduled: Int
          repeat {
            scheduled = try await discLibrary.enqueueMissingProbeWork(
              sourceUID: sourceUID,
              priority: -150,
              limit: 200
            )
            if scheduled > 0 {
              show("Inspecting optical-disc playlists…")
              try await enrichProbeWork(
                sourceUID: sourceUID,
                libraryStore: libraryStore,
                session: session
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
    let discLibrary = DiscMediaLibrary(store: libraryStore)
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
        discLibrary: discLibrary,
        session: session
      )
    }
  }

  private nonisolated static func processProbeWork(
    _ workItem: DemoMetadataWorkItem,
    libraryStore: LibraryStore,
    metadataStore: SQLiteMediaMetadataStore,
    discLibrary: DiscMediaLibrary,
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
      switch try await discLibrary.process(workItem.lease, using: session) {
      case .notCompositeMedia:
        break
      case .cacheHit(_), .probed(_), .failed(_):
        return
      }
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
    var claimedScheduledRunUID: String?
    defer {
      Task { @MainActor [weak self] in
        if let claimedScheduledRunUID {
          try? await self?.scanScheduler.finish(runUID: claimedScheduledRunUID)
        }
        self?.scanTask = nil
      }
    }
    await prepareIfNeeded()
    guard let libraryStore, let metadataCacheStore, let mediaInfoClient,
      let sourceUID = sourceUIDForRecovery()
    else { return }
    do {
      try await scanScheduler.submit(
        MediaScanTrigger(
          sourceUID: sourceUID,
          mode: .repair,
          roots: [],
          origin: .manual,
          submittedAtMilliseconds: Self.nowMilliseconds()
        ),
        pathSemantics: Self.smbPathSemantics
      )
      guard let scheduled = try await scanScheduler.nextReady(
        atMilliseconds: Self.nowMilliseconds()
      ), scheduled.request.mode == .repair
      else {
        throw SDKError(code: .conflict, message: "SMB source already has active scan work")
      }
      claimedScheduledRunUID = scheduled.request.runUID
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
    guard scanTask == nil, !isEditingSource, activeRequest == nil, scanState == .idle,
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
      let hasProbeWork = try await libraryStore.hasOutstandingScanWork(
        sourceUID: sourceUID,
        stage: .probe
      )
      guard hasPrimaryWork || hasArtworkWork || hasProbeWork else { return }
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
      // AMSMB2 exposes an inode-like value, but an arbitrary SMB server does not guarantee that
      // it survives reconnects or cannot be reused. Prefer path identity unless a product has
      // explicitly validated a server and opts into persistent IDs.
      stableIDScope: .none,
      pathSemantics: Self.smbPathSemantics,
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

  private static func demoDiscDetails(_ result: DiscMediaProbeResult) -> DemoDiscDetails {
    DemoDiscDetails(
      kind: result.descriptor.kind.rawValue,
      playlists: result.playlists.map { playlist in
        DemoDiscPlaylist(
          identifier: playlist.identifier,
          durationMilliseconds: playlist.durationMilliseconds,
          sizeBytes: playlist.sizeBytes,
          segmentCount: playlist.segments.count,
          isDefault: playlist.isSelected
        )
      },
      listRequestCount: result.metrics.directoryListRequestCount,
      rangeRequestCount: result.metrics.rangeReadRequestCount,
      bytesRead: result.metrics.rangeBytesRead,
      elapsedMilliseconds: result.metrics.elapsedMilliseconds
    )
  }

  private nonisolated static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    return (error as? SDKError)?.code == .cancelled
  }

  private nonisolated static func nowMilliseconds() -> Int64 {
    Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
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

  func loadEnumerationState(runUID: String) async throws -> MediaScanEnumerationState? {
    try await base.loadEnumerationState(runUID: runUID)
  }
}

private struct DemoScanObserver: MediaScanObserver {
  let relay: DemoScanProgressRelay

  func emit(_ event: MediaScanEvent) async {
    await relay.event(event)
  }
}

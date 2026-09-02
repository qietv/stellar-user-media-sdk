import Foundation
import GRDB
import StellarCore
import StellarRemoteMedia

/// A media-source category accepted by the library database contract.
public enum LibrarySourceKind: String, Codable, Sendable {
  case localFolder = "local_folder"
  case deviceMedia = "device_media"
  case smb
  case nfs
  case webdav
  case ftp
  case cloudDrive = "cloud_drive"
  case plex
  case emby
  case jellyfin
}

/// Non-secret source metadata required before a scanner can persist file facts.
public struct LibrarySourceDefinition: Equatable, Sendable {
  public let uid: String
  public let kind: LibrarySourceKind
  public let displayName: String
  public let rootURI: String

  public init(uid: String, kind: LibrarySourceKind, displayName: String, rootURI: String) throws {
    let components = URLComponents(string: rootURI)
    guard !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !uid.contains("\0"),
      !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !rootURI.contains("\0"), components?.scheme?.isEmpty == false,
      components?.user == nil, components?.password == nil,
      components?.query == nil, components?.fragment == nil
    else {
      throw SDKError(code: .invalidConfiguration, message: "library source is invalid")
    }
    self.uid = uid
    self.kind = kind
    self.displayName = displayName
    self.rootURI = rootURI
  }
}

/// One storage command derived from an atomic source-independent scanner batch.
public struct LibraryScanPersistenceBatch: Sendable {
  public let runUID: String
  public let sourceUID: String
  public let mode: String
  public let state: String
  public let checkpointJSON: String
  public let coverageJSON: String
  public let entries: [RemoteEntry]
  public let capabilities: MediaSourceCapabilities?
  public let coveredRoots: [RemoteLocator]
  public let reconcileMissingEligible: Bool
  public let discoveredEntryCount: Int64
  public let pendingPageCount: Int?
  public let processedPageCount: Int64?
  public let errorCode: String?
  public let enumerationState: LibraryScanEnumerationState?
  package let pageTransitions: [LibraryScanPageTransition]
  public let pageTransition: LibraryScanPageTransition?

  public init(
    runUID: String,
    sourceUID: String,
    mode: String,
    state: String,
    checkpointJSON: String,
    coverageJSON: String,
    entries: [RemoteEntry],
    capabilities: MediaSourceCapabilities?,
    coveredRoots: [RemoteLocator] = [],
    reconcileMissingEligible: Bool = false,
    discoveredEntryCount: Int64,
    errorCode: String? = nil
  ) throws {
    try self.init(
      runUID: runUID,
      sourceUID: sourceUID,
      mode: mode,
      state: state,
      checkpointJSON: checkpointJSON,
      coverageJSON: coverageJSON,
      entries: entries,
      capabilities: capabilities,
      coveredRoots: coveredRoots,
      reconcileMissingEligible: reconcileMissingEligible,
      discoveredEntryCount: discoveredEntryCount,
      pendingPageCount: nil,
      processedPageCount: nil,
      errorCode: errorCode,
      enumerationState: nil,
      pageTransition: nil
    )
  }

  public init(
    runUID: String,
    sourceUID: String,
    mode: String,
    state: String,
    checkpointJSON: String,
    coverageJSON: String,
    entries: [RemoteEntry],
    capabilities: MediaSourceCapabilities?,
    coveredRoots: [RemoteLocator] = [],
    reconcileMissingEligible: Bool = false,
    discoveredEntryCount: Int64,
    pendingPageCount: Int?,
    processedPageCount: Int64?,
    errorCode: String? = nil,
    enumerationState: LibraryScanEnumerationState?,
    pageTransition: LibraryScanPageTransition?
  ) throws {
    try self.init(
      runUID: runUID,
      sourceUID: sourceUID,
      mode: mode,
      state: state,
      checkpointJSON: checkpointJSON,
      coverageJSON: coverageJSON,
      entries: entries,
      capabilities: capabilities,
      coveredRoots: coveredRoots,
      reconcileMissingEligible: reconcileMissingEligible,
      discoveredEntryCount: discoveredEntryCount,
      pendingPageCount: pendingPageCount,
      processedPageCount: processedPageCount,
      errorCode: errorCode,
      enumerationState: enumerationState,
      pageTransitions: pageTransition.map { [$0] } ?? []
    )
  }

  package init(
    runUID: String,
    sourceUID: String,
    mode: String,
    state: String,
    checkpointJSON: String,
    coverageJSON: String,
    entries: [RemoteEntry],
    capabilities: MediaSourceCapabilities?,
    coveredRoots: [RemoteLocator] = [],
    reconcileMissingEligible: Bool = false,
    discoveredEntryCount: Int64,
    pendingPageCount: Int?,
    processedPageCount: Int64?,
    errorCode: String? = nil,
    enumerationState: LibraryScanEnumerationState?,
    pageTransitions: [LibraryScanPageTransition]
  ) throws {
    let modes = ["full", "incremental", "repair"]
    let states = ["queued", "enumerating", "finalizing", "completed", "failed", "cancelled"]
    guard !runUID.isEmpty, !sourceUID.isEmpty, modes.contains(mode), states.contains(state),
      !checkpointJSON.isEmpty, !coverageJSON.isEmpty, discoveredEntryCount >= 0,
      pendingPageCount.map({ $0 >= 0 }) ?? true,
      processedPageCount.map({ $0 >= 0 }) ?? true,
      entries.allSatisfy({ $0.locator.sourceUID == sourceUID }),
      coveredRoots.allSatisfy({ $0.sourceUID == sourceUID }),
      enumerationState.map({ state in
        (state.pendingPages + state.completedPages).allSatisfy {
          $0.directory.sourceUID == sourceUID
        }
      }) ?? true,
      pageTransitions.flatMap({ [$0.completedPage] + $0.enqueuedPages }).allSatisfy({
        $0.directory.sourceUID == sourceUID
      }),
      enumerationState == nil || pageTransitions.isEmpty,
      !reconcileMissingEligible || state == "completed",
      !reconcileMissingEligible || capabilities != nil
    else {
      throw SDKError(code: .invalidConfiguration, message: "scan persistence batch is invalid")
    }
    self.runUID = runUID
    self.sourceUID = sourceUID
    self.mode = mode
    self.state = state
    self.checkpointJSON = checkpointJSON
    self.coverageJSON = coverageJSON
    self.entries = entries
    self.capabilities = capabilities
    self.coveredRoots = coveredRoots
    self.reconcileMissingEligible = reconcileMissingEligible
    self.discoveredEntryCount = discoveredEntryCount
    self.pendingPageCount = pendingPageCount
    self.processedPageCount = processedPageCount
    self.errorCode = errorCode
    self.enumerationState = enumerationState
    self.pageTransitions = pageTransitions
    pageTransition = pageTransitions.count == 1 ? pageTransitions[0] : nil
  }
}

/// One page in the durable directory frontier.
public struct LibraryScanFrontierPage: Equatable, Hashable, Sendable {
  public let directory: RemoteLocator
  public let cursor: String?

  public init(directory: RemoteLocator, cursor: String? = nil) throws {
    guard cursor?.isEmpty != true else {
      throw SDKError(code: .invalidConfiguration, message: "scan frontier cursor is invalid")
    }
    self.directory = directory
    self.cursor = cursor
  }
}

/// A complete durable frontier snapshot, used when a scan run is created.
public struct LibraryScanEnumerationState: Equatable, Sendable {
  public let pendingPages: [LibraryScanFrontierPage]
  public let completedPages: [LibraryScanFrontierPage]
  public let seenEntryIdentityKeys: [String]
  public let seenDirectoryIdentityKeys: [String]

  public init(
    pendingPages: [LibraryScanFrontierPage],
    completedPages: [LibraryScanFrontierPage],
    seenEntryIdentityKeys: [String],
    seenDirectoryIdentityKeys: [String]
  ) throws {
    guard Set(pendingPages).count == pendingPages.count,
      Set(completedPages).count == completedPages.count,
      Set(pendingPages).isDisjoint(with: completedPages),
      Set(seenEntryIdentityKeys).count == seenEntryIdentityKeys.count,
      Set(seenDirectoryIdentityKeys).count == seenDirectoryIdentityKeys.count,
      Set(seenDirectoryIdentityKeys).isSubset(of: seenEntryIdentityKeys)
    else {
      throw SDKError(code: .invalidConfiguration, message: "scan enumeration state is invalid")
    }
    self.pendingPages = pendingPages
    self.completedPages = completedPages
    self.seenEntryIdentityKeys = seenEntryIdentityKeys
    self.seenDirectoryIdentityKeys = seenDirectoryIdentityKeys
  }
}

/// Incremental durable frontier changes committed with one scanner page.
public struct LibraryScanPageTransition: Equatable, Sendable {
  public let completedPage: LibraryScanFrontierPage
  public let enqueuedPages: [LibraryScanFrontierPage]
  public let seenEntryIdentityKeys: [String]
  public let seenDirectoryIdentityKeys: [String]

  public init(
    completedPage: LibraryScanFrontierPage,
    enqueuedPages: [LibraryScanFrontierPage],
    seenEntryIdentityKeys: [String],
    seenDirectoryIdentityKeys: [String]
  ) {
    self.completedPage = completedPage
    self.enqueuedPages = enqueuedPages
    self.seenEntryIdentityKeys = seenEntryIdentityKeys
    self.seenDirectoryIdentityKeys = seenDirectoryIdentityKeys
  }
}

/// A normalized file fact suitable for CLI inspection and cross-platform snapshots.
public struct LibraryFileFact: Codable, Equatable, Sendable {
  public let sourceUID: String
  public let stableKey: String
  public let relativePath: String
  public let sizeBytes: Int64?
  public let modifiedAtMilliseconds: Int64?
  public let entityTag: String?
  public let availability: String
  public let missingScanCount: Int

  private enum CodingKeys: String, CodingKey {
    case sourceUID = "source_uid"
    case stableKey = "stable_key"
    case relativePath = "relative_path"
    case sizeBytes = "size_bytes"
    case modifiedAtMilliseconds = "modified_at_ms"
    case entityTag = "etag"
    case availability
    case missingScanCount = "missing_scan_count"
  }
}

/// A stable database projection that excludes local integer IDs and generated UUIDs.
public struct LibrarySnapshot: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let sources: [String]
  public let files: [LibraryFileFact]

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case sources
    case files
  }
}

/// One durable processing stage created when a scanned file is new or changes.
public enum LibraryScanQueueStage: String, CaseIterable, Sendable {
  case parse
  case probe
  case localMetadata = "local_metadata"
  case match
  case materialize
  case artwork
  case searchIndex = "search_index"
}

/// One pending or retryable file-stage pair from the durable scan queue.
public struct LibraryScanWorkItem: Equatable, Sendable {
  public let relativePath: String
  public let attempts: Int

  public init(relativePath: String, attempts: Int) throws {
    let path = try RemotePath(relativePath)
    guard !path.isRoot, attempts >= 0 else {
      throw SDKError(code: .invalidConfiguration, message: "scan work item is invalid")
    }
    self.relativePath = path.relativePath
    self.attempts = attempts
  }
}

/// One pending file-stage pair joined with the durable file fact needed by a worker.
public struct LibraryScanFileWorkItem: Equatable, Sendable {
  public let file: LibraryFileFact
  public let attempts: Int
  public let hasMatchingBinding: Bool

  public init(
    file: LibraryFileFact,
    attempts: Int,
    hasMatchingBinding: Bool
  ) throws {
    guard attempts >= 0 else {
      throw SDKError(code: .invalidConfiguration, message: "scan file work item is invalid")
    }
    self.file = file
    self.attempts = attempts
    self.hasMatchingBinding = hasMatchingBinding
  }
}

/// Exclusive, time-bounded ownership of one file-stage task.
///
/// Workers must use the lease-aware completion APIs so results are committed only
/// while the claim is current and the file's material input revision still matches.
public struct LibraryScanWorkLease: Equatable, Sendable {
  package let queueID: Int64
  public let file: LibraryFileFact
  public let stage: LibraryScanQueueStage
  public let attempts: Int
  public let hasMatchingBinding: Bool
  public let inputRevision: Int64
  public let workerID: String
  public let claimToken: String
  public let leaseUntilMilliseconds: Int64

  package init(
    queueID: Int64,
    file: LibraryFileFact,
    stage: LibraryScanQueueStage,
    attempts: Int,
    hasMatchingBinding: Bool,
    inputRevision: Int64,
    workerID: String,
    claimToken: String,
    leaseUntilMilliseconds: Int64
  ) throws {
    guard queueID > 0, attempts >= 0, inputRevision > 0,
      !workerID.isEmpty, !workerID.contains("\0"),
      !claimToken.isEmpty, !claimToken.contains("\0"), leaseUntilMilliseconds > 0
    else {
      throw SDKError(code: .invalidConfiguration, message: "scan work lease is invalid")
    }
    self.queueID = queueID
    self.file = file
    self.stage = stage
    self.attempts = attempts
    self.hasMatchingBinding = hasMatchingBinding
    self.inputRevision = inputRevision
    self.workerID = workerID
    self.claimToken = claimToken
    self.leaseUntilMilliseconds = leaseUntilMilliseconds
  }

  package func renewed(until leaseUntilMilliseconds: Int64) throws -> Self {
    try Self(
      queueID: queueID,
      file: file,
      stage: stage,
      attempts: attempts,
      hasMatchingBinding: hasMatchingBinding,
      inputRevision: inputRevision,
      workerID: workerID,
      claimToken: claimToken,
      leaseUntilMilliseconds: leaseUntilMilliseconds
    )
  }
}

/// A keyset-paginated view of durable scan work.
public struct LibraryScanFileWorkPage: Equatable, Sendable {
  public let items: [LibraryScanFileWorkItem]
  public let nextCursor: String?

  public init(items: [LibraryScanFileWorkItem], nextCursor: String?) {
    self.items = items
    self.nextCursor = nextCursor
  }
}

/// Aggregate counts for present files in one source.
public struct LibrarySourceMediaSummary: Equatable, Sendable {
  public let presentFileCount: Int
  public let matchedFileCount: Int

  public init(presentFileCount: Int, matchedFileCount: Int) throws {
    guard presentFileCount >= 0, matchedFileCount >= 0, matchedFileCount <= presentFileCount else {
      throw SDKError(code: .invalidConfiguration, message: "library source summary is invalid")
    }
    self.presentFileCount = presentFileCount
    self.matchedFileCount = matchedFileCount
  }
}

private struct LibraryScanFileWorkCursor: Codable {
  let schemaVersion: Int
  let sourceUID: String
  let stage: String
  let pathCompareKey: String
  let fileID: Int64

  init(sourceUID: String, stage: LibraryScanQueueStage, pathCompareKey: String, fileID: Int64) {
    schemaVersion = 1
    self.sourceUID = sourceUID
    self.stage = stage.rawValue
    self.pathCompareKey = pathCompareKey
    self.fileID = fileID
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case sourceUID = "source_uid"
    case stage
    case pathCompareKey = "path_compare_key"
    case fileID = "file_id"
  }
}

/// Root media kind addressed by one provider metadata response.
public enum LibraryRemoteMetadataKind: String, Sendable {
  case movie
  case series
}

/// Provider metadata and selected remote poster ready for materialization.
public struct LibraryRemoteMetadata: Equatable, Sendable {
  public let provider: String
  public let providerID: String
  public let kind: LibraryRemoteMetadataKind
  public let locale: String
  public let title: String
  public let originalTitle: String?
  public let overview: String?
  public let year: Int?
  public let posterURL: String?
  public let posterWidth: Int?
  public let posterHeight: Int?

  public init(
    provider: String,
    providerID: String,
    kind: LibraryRemoteMetadataKind,
    locale: String = "und",
    title: String,
    originalTitle: String? = nil,
    overview: String? = nil,
    year: Int? = nil,
    posterURL: String? = nil,
    posterWidth: Int? = nil,
    posterHeight: Int? = nil
  ) throws {
    let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let posterComponents = posterURL.flatMap { URLComponents(string: $0) }
    guard !provider.isEmpty, !providerID.isEmpty, !locale.isEmpty,
      !provider.contains("\0"), !providerID.contains("\0"), !locale.contains("\0"),
      !normalizedTitle.isEmpty, !normalizedTitle.contains("\0"),
      originalTitle?.contains("\0") != true, overview?.contains("\0") != true,
      year.map({ (1000...9999).contains($0) }) ?? true,
      posterURL?.contains("\0") != true,
      posterURL == nil
        || (posterComponents?.scheme?.lowercased() == "https"
          && posterComponents?.host?.isEmpty == false),
      posterWidth.map({ $0 > 0 }) ?? true, posterHeight.map({ $0 > 0 }) ?? true
    else {
      throw SDKError(code: .invalidConfiguration, message: "remote metadata is invalid")
    }
    self.provider = provider
    self.providerID = providerID
    self.kind = kind
    self.locale = locale
    self.title = normalizedTitle
    self.originalTitle = originalTitle
    self.overview = overview
    self.year = year
    self.posterURL = posterURL
    self.posterWidth = posterWidth
    self.posterHeight = posterHeight
  }
}

/// A normalized filename parse result ready for the library database.
package struct LibraryFilenameParseRecord: Equatable, Sendable {
  public let mediaKind: String
  public let cleanTitle: String?
  public let sortTitle: String?
  public let hintYear: Int?
  public let seasonNumber: Int?
  public let episodeStart: Int?
  public let episodeEnd: Int?
  public let edition: String?
  public let releaseGroup: String?
  public let languageHint: String?
  public let providerHintsJSON: String?
  public let rawTokensJSON: String?
  public let confidence: Double
  public let parserVersion: Int

  public init(
    mediaKind: String,
    cleanTitle: String? = nil,
    sortTitle: String? = nil,
    hintYear: Int? = nil,
    seasonNumber: Int? = nil,
    episodeStart: Int? = nil,
    episodeEnd: Int? = nil,
    edition: String? = nil,
    releaseGroup: String? = nil,
    languageHint: String? = nil,
    providerHintsJSON: String? = nil,
    rawTokensJSON: String? = nil,
    confidence: Double,
    parserVersion: Int
  ) throws {
    let kinds = ["movie", "episode", "extra", "unknown"]
    let strings = [
      cleanTitle, sortTitle, edition, releaseGroup, languageHint, providerHintsJSON, rawTokensJSON,
    ]
    guard kinds.contains(mediaKind), strings.allSatisfy({ $0?.contains("\0") != true }),
      hintYear.map({ (1000...9999).contains($0) }) ?? true,
      seasonNumber.map({ $0 >= 0 }) ?? true,
      episodeStart.map({ $0 >= 0 }) ?? true,
      episodeEnd.map({ $0 >= 0 }) ?? true,
      episodeEnd == nil || episodeStart != nil,
      episodeEnd.map({ $0 >= (episodeStart ?? 0) }) ?? true,
      confidence.isFinite, (0...1).contains(confidence), parserVersion > 0
    else {
      throw SDKError(code: .invalidConfiguration, message: "filename parse record is invalid")
    }
    self.mediaKind = mediaKind
    self.cleanTitle = cleanTitle
    self.sortTitle = sortTitle
    self.hintYear = hintYear
    self.seasonNumber = seasonNumber
    self.episodeStart = episodeStart
    self.episodeEnd = episodeEnd
    self.edition = edition
    self.releaseGroup = releaseGroup
    self.languageHint = languageHint
    self.providerHintsJSON = providerHintsJSON
    self.rawTokensJSON = rawTokensJSON
    self.confidence = confidence
    self.parserVersion = parserVersion
  }
}

/// One sidecar row to associate with a scanned media file.
package struct LibrarySidecarRecord: Equatable, Sendable {
  public let kind: String
  public let relativePath: String
  public let language: String
  public let isForced: Bool
  public let modifiedAtMilliseconds: Int64?
  public let sha256: String?
  public let parsedJSON: String?

  public init(
    kind: String,
    relativePath: String,
    language: String = "und",
    isForced: Bool = false,
    modifiedAtMilliseconds: Int64? = nil,
    sha256: String? = nil,
    parsedJSON: String? = nil
  ) throws {
    let kinds = [
      "nfo", "metadata_json", "poster", "backdrop", "logo", "subtitle", "chapters", "other",
    ]
    let sha256Pattern = #"^[0-9a-f]{64}$"#
    guard kinds.contains(kind), !relativePath.isEmpty, !relativePath.contains("\0"),
      !language.isEmpty, !language.contains("\0"),
      sha256.map({ $0.range(of: sha256Pattern, options: .regularExpression) != nil }) ?? true,
      parsedJSON?.contains("\0") != true
    else {
      throw SDKError(code: .invalidConfiguration, message: "sidecar record is invalid")
    }
    self.kind = kind
    self.relativePath = relativePath
    self.language = language
    self.isForced = isForced
    self.modifiedAtMilliseconds = modifiedAtMilliseconds
    self.sha256 = sha256
    self.parsedJSON = parsedJSON
  }
}

/// The storage projection of one successful technical probe.
package struct LibraryTechnicalProbeRecord: Equatable, Sendable {
  public let summary: LibraryTechnicalSummaryRecord
  public let streams: [LibraryTechnicalStreamRecord]
  public let probeProvider: String
  public let probeVersion: Int

  public init(
    summary: LibraryTechnicalSummaryRecord,
    streams: [LibraryTechnicalStreamRecord],
    probeProvider: String,
    probeVersion: Int
  ) throws {
    guard !probeProvider.isEmpty, !probeProvider.contains("\0"), probeVersion > 0,
      Set(streams.map(\.streamIndex)).count == streams.count
    else {
      throw SDKError(code: .invalidConfiguration, message: "technical probe record is invalid")
    }
    self.summary = summary
    self.streams = streams.sorted { $0.streamIndex < $1.streamIndex }
    self.probeProvider = probeProvider
    self.probeVersion = probeVersion
  }
}

/// Compact technical columns stored for one media file.
package struct LibraryTechnicalSummaryRecord: Equatable, Sendable {
  public let container: String?
  public let durationMilliseconds: Int64?
  public let overallBitrate: Int64?
  public let videoCodec: String?
  public let width: Int?
  public let height: Int?
  public let frameRate: Double?
  public let hdrProfile: String?
  public let audioCodec: String?
  public let audioChannels: Double?
  public let hasEmbeddedCover: Bool

  public init(
    container: String? = nil,
    durationMilliseconds: Int64? = nil,
    overallBitrate: Int64? = nil,
    videoCodec: String? = nil,
    width: Int? = nil,
    height: Int? = nil,
    frameRate: Double? = nil,
    hdrProfile: String? = nil,
    audioCodec: String? = nil,
    audioChannels: Double? = nil,
    hasEmbeddedCover: Bool = false
  ) {
    self.container = container
    self.durationMilliseconds = durationMilliseconds
    self.overallBitrate = overallBitrate
    self.videoCodec = videoCodec
    self.width = width
    self.height = height
    self.frameRate = frameRate
    self.hdrProfile = hdrProfile
    self.audioCodec = audioCodec
    self.audioChannels = audioChannels
    self.hasEmbeddedCover = hasEmbeddedCover
  }
}

/// Technical columns stored for one media stream.
package struct LibraryTechnicalStreamRecord: Equatable, Sendable {
  public let streamIndex: Int
  public let kind: String
  public let codec: String?
  public let language: String
  public let title: String?
  public let bitrate: Int64?
  public let width: Int?
  public let height: Int?
  public let frameRate: Double?
  public let hdrProfile: String?
  public let channelCount: Double?
  public let channelLayout: String?
  public let sampleRate: Int?
  public let isDefault: Bool
  public let isForced: Bool

  public init(
    streamIndex: Int,
    kind: String,
    codec: String? = nil,
    language: String = "und",
    title: String? = nil,
    bitrate: Int64? = nil,
    width: Int? = nil,
    height: Int? = nil,
    frameRate: Double? = nil,
    hdrProfile: String? = nil,
    channelCount: Double? = nil,
    channelLayout: String? = nil,
    sampleRate: Int? = nil,
    isDefault: Bool = false,
    isForced: Bool = false
  ) throws {
    let kinds = ["video", "audio", "subtitle", "attachment"]
    guard streamIndex >= 0, kinds.contains(kind), !language.isEmpty, !language.contains("\0") else {
      throw SDKError(code: .invalidConfiguration, message: "technical stream record is invalid")
    }
    self.streamIndex = streamIndex
    self.kind = kind
    self.codec = codec
    self.language = language
    self.title = title
    self.bitrate = bitrate
    self.width = width
    self.height = height
    self.frameRate = frameRate
    self.hdrProfile = hdrProfile
    self.channelCount = channelCount
    self.channelLayout = channelLayout
    self.sampleRate = sampleRate
    self.isDefault = isDefault
    self.isForced = isForced
  }
}

/// A complete local-metadata transaction for one scanned media file.
package struct LibraryMetadataIntakeBatch: Sendable {
  public let sourceUID: String
  public let mediaRelativePath: String
  public let parseResult: LibraryFilenameParseRecord
  public let sidecars: [LibrarySidecarRecord]
  public let technicalProbe: LibraryTechnicalProbeRecord?

  public init(
    sourceUID: String,
    mediaRelativePath: String,
    parseResult: LibraryFilenameParseRecord,
    sidecars: [LibrarySidecarRecord],
    technicalProbe: LibraryTechnicalProbeRecord? = nil
  ) throws {
    guard !sourceUID.isEmpty, !sourceUID.contains("\0"), !mediaRelativePath.isEmpty,
      !mediaRelativePath.contains("\0"), Set(sidecars.map(\.relativePath)).count == sidecars.count
    else {
      throw SDKError(code: .invalidConfiguration, message: "metadata intake batch is invalid")
    }
    self.sourceUID = sourceUID
    self.mediaRelativePath = mediaRelativePath
    self.parseResult = parseResult
    self.sidecars = sidecars.sorted { $0.relativePath < $1.relativePath }
    self.technicalProbe = technicalProbe
  }
}

/// A deterministic read-back projection for metadata intake verification.
package struct LibraryMetadataIntakeSnapshot: Equatable, Sendable {
  public let parseResult: LibraryFilenameParseRecord
  public let sidecars: [LibrarySidecarRecord]
  public let technicalProbe: LibraryTechnicalProbeRecord?
}

/// Scanner-oriented repository over a migrated `library.sqlite` database.
public struct LibraryStore: Sendable {
  public let database: StorageDatabase
  package let clock: any SDKClock
  package let uuidGenerator: any SDKUUIDGenerating

  public init(
    database: StorageDatabase,
    clock: any SDKClock = SystemSDKClock(),
    uuidGenerator: any SDKUUIDGenerating = SystemSDKUUIDGenerator()
  ) throws {
    guard database.kind == .library else {
      throw SDKError(code: .invalidConfiguration, message: "LibraryStore requires library.sqlite")
    }
    self.database = database
    self.clock = clock
    self.uuidGenerator = uuidGenerator
  }

  /// Inserts or updates non-secret media-source metadata.
  public func registerSource(_ source: LibrarySourceDefinition) async throws {
    let now = clock.nowMilliseconds()
    do {
      try await database.write { database in
        try database.execute(
          sql: """
            INSERT INTO library_source(
              uid, kind, display_name, root_uri, scan_policy, enabled,
              created_at_ms, updated_at_ms
            ) VALUES (?, ?, ?, ?, 'incremental', 1, ?, ?)
            ON CONFLICT(uid) DO UPDATE SET
              kind = excluded.kind,
              display_name = excluded.display_name,
              root_uri = excluded.root_uri,
              updated_at_ms = excluded.updated_at_ms,
              deleted_at_ms = NULL
            """,
          arguments: [
            source.uid, source.kind.rawValue, source.displayName, source.rootURI, now, now,
          ]
        )
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "library source write failed")
    }
  }

  /// Atomically writes entries, the checkpoint that acknowledges them, and optional completion.
  public func commit(_ batch: LibraryScanPersistenceBatch) async throws {
    let now = clock.nowMilliseconds()
    do {
      try await database.write { database in
        guard
          let sourceID = try Int64.fetchOne(
            database,
            sql: "SELECT id FROM library_source WHERE uid = ? AND deleted_at_ms IS NULL",
            arguments: [batch.sourceUID]
          )
        else {
          throw SDKError(code: .invalidConfiguration, message: "library source is not registered")
        }

        let existingRun = try Row.fetchOne(
          database,
          sql: """
            SELECT id, source_id, mode, state, checkpoint_json, discovered_count
            FROM scan_run
            WHERE uid = ?
            """,
          arguments: [batch.runUID]
        )
        let runID: Int64
        let previousEnumerationProgress: StoredCheckpointProgress?
        let previousDiscoveredCount: Int64
        if let existingRun {
          let storedSourceID: Int64 = existingRun["source_id"]
          let storedMode: String = existingRun["mode"]
          let storedState: String = existingRun["state"]
          let storedCheckpoint: String = existingRun["checkpoint_json"]
          guard storedSourceID == sourceID, storedMode == batch.mode else {
            throw SDKError(code: .storageFailure, message: "scan run identity mismatch")
          }
          if storedState == "completed" {
            guard storedCheckpoint == batch.checkpointJSON, batch.state == "completed" else {
              throw SDKError(code: .storageFailure, message: "completed scan run is immutable")
            }
            return
          }
          runID = existingRun["id"]
          previousDiscoveredCount = existingRun["discovered_count"]
          previousEnumerationProgress =
            batch.pageTransitions.isEmpty
            ? nil : try Self.decodeStoredCheckpointProgress(storedCheckpoint)
        } else {
          try Self.requireNoOtherActiveRun(
            sourceID: sourceID,
            excludingRunID: nil,
            requestedState: batch.state,
            database: database
          )
          try database.execute(
            sql: """
              INSERT INTO scan_run(
                uid, source_id, mode, state, checkpoint_json, coverage_json,
                reconcile_missing, started_at_ms, discovered_count
              ) VALUES (?, ?, ?, ?, ?, ?, 0, ?, 0)
              """,
            arguments: [
              batch.runUID, sourceID, batch.mode, batch.state, batch.checkpointJSON,
              batch.coverageJSON, now,
            ]
          )
          runID = database.lastInsertedRowID
          previousEnumerationProgress = nil
          previousDiscoveredCount = 0
        }

        try Self.requireNoOtherActiveRun(
          sourceID: sourceID,
          excludingRunID: runID,
          requestedState: batch.state,
          database: database
        )
        try Self.requireRunIsNotSuperseded(
          sourceID: sourceID,
          runID: runID,
          requestedState: batch.state,
          database: database
        )

        let hasEnumerationMutation =
          batch.enumerationState != nil || !batch.pageTransitions.isEmpty
        if let state = batch.enumerationState {
          try Self.validateEnumerationSnapshot(
            state,
            pendingPageCount: batch.pendingPageCount,
            processedPageCount: batch.processedPageCount,
            discoveredEntryCount: batch.discoveredEntryCount
          )
          try Self.replaceEnumerationState(
            state,
            runID: runID,
            now: now,
            database: database
          )
        }
        if !batch.pageTransitions.isEmpty {
          guard let previousEnumerationProgress else {
            throw SDKError(code: .storageFailure, message: "scan frontier progress is missing")
          }
          var insertedPageCount = 0
          var insertedSeenCount: Int64 = 0
          for transition in batch.pageTransitions {
            let applied = try Self.applyEnumerationTransition(
              transition,
              runID: runID,
              now: now,
              database: database
            )
            insertedPageCount += applied.insertedPageCount
            insertedSeenCount += applied.insertedSeenCount
          }
          try Self.validateEnumerationTransitions(
            previous: previousEnumerationProgress,
            previousDiscoveredCount: previousDiscoveredCount,
            completedPageCount: batch.pageTransitions.count,
            insertedPageCount: insertedPageCount,
            insertedSeenCount: insertedSeenCount,
            pendingPageCount: batch.pendingPageCount,
            processedPageCount: batch.processedPageCount,
            discoveredEntryCount: batch.discoveredEntryCount
          )
        }
        if hasEnumerationMutation,
          batch.pendingPageCount == nil || batch.processedPageCount == nil
        {
          throw SDKError(code: .storageFailure, message: "scan frontier counters are missing")
        }

        var changedCount = 0
        if let capabilities = batch.capabilities {
          try Self.stage(
            entries: batch.entries,
            runID: runID,
            capabilities: capabilities,
            database: database
          )
        } else if batch.entries.contains(where: { $0.kind == .file }) {
          throw SDKError(code: .storageFailure, message: "file batch has no source capabilities")
        }

        if batch.state == "completed" {
          changedCount = try Self.publishStagedFiles(
            sourceID: sourceID,
            runID: runID,
            now: now,
            database: database
          )
          if batch.reconcileMissingEligible {
            guard let capabilities = batch.capabilities else {
              throw SDKError(
                code: .storageFailure,
                message: "missing reconciliation has no source capabilities"
              )
            }
            try Self.reconcileMissing(
              sourceID: sourceID,
              runID: runID,
              roots: batch.coveredRoots,
              semantics: capabilities.pathSemantics,
              now: now,
              database: database
            )
          }
        }

        let terminal = ["completed", "failed", "cancelled"].contains(batch.state)
        try database.execute(
          sql: """
            UPDATE scan_run SET
              state = ?,
              checkpoint_json = ?,
              coverage_json = ?,
              reconcile_missing = ?,
              finished_at_ms = ?,
              discovered_count = ?,
              changed_count = changed_count + ?,
              error_count = CASE WHEN ? IS NULL THEN error_count ELSE error_count + 1 END,
              error_code = ?
            WHERE id = ?
            """,
          arguments: [
            batch.state, batch.checkpointJSON, batch.coverageJSON,
            batch.reconcileMissingEligible ? 1 : 0, terminal ? now : nil,
            batch.discoveredEntryCount, changedCount, batch.errorCode, batch.errorCode, runID,
          ]
        )
        if batch.state == "completed" {
          try database.execute(
            sql: "UPDATE library_source SET last_scan_at_ms = ?, updated_at_ms = ? WHERE id = ?",
            arguments: [now, now, sourceID]
          )
          try database.execute(
            sql: "DELETE FROM scan_frontier WHERE run_id = ?",
            arguments: [runID]
          )
          try database.execute(sql: "DELETE FROM scan_seen WHERE run_id = ?", arguments: [runID])
          try database.execute(
            sql: "DELETE FROM scan_discovery WHERE run_id = ?",
            arguments: [runID]
          )
        }
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "scan batch transaction failed")
    }
  }

  /// Loads a durable scanner checkpoint for crash recovery.
  public func checkpointJSON(runUID: String) async throws -> String? {
    do {
      return try await database.read { database in
        try String.fetchOne(
          database,
          sql: "SELECT checkpoint_json FROM scan_run WHERE uid = ?",
          arguments: [runUID]
        )
      }
    } catch {
      throw SDKError(code: .storageFailure, message: "scan checkpoint read failed")
    }
  }

  /// Returns the latest run checkpoint only when the source's newest run can be resumed.
  ///
  /// Selecting the newest run before filtering its state prevents an older failed run
  /// from being revived after a newer run has already completed successfully.
  package func latestRecoverableCheckpointJSON(sourceUID: String) async throws -> String? {
    guard !sourceUID.isEmpty, !sourceUID.contains("\0") else {
      throw SDKError(code: .invalidConfiguration, message: "scan recovery source is invalid")
    }
    do {
      return try await database.read { database in
        try String.fetchOne(
          database,
          sql: """
            SELECT run.checkpoint_json
            FROM scan_run run
            JOIN library_source source ON source.id = run.source_id
            WHERE source.uid = ?
              AND source.deleted_at_ms IS NULL
              AND run.id = (
                SELECT MAX(latest.id)
                FROM scan_run latest
                WHERE latest.source_id = source.id
              )
              AND run.state IN (
                'queued', 'enumerating', 'processing', 'finalizing', 'cancelled', 'failed'
              )
            """,
          arguments: [sourceUID]
        )
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "recoverable scan checkpoint read failed")
    }
  }

  /// Loads the durable directory frontier and seen identities for a resumable run.
  public func scanEnumerationState(
    runUID: String
  ) async throws -> LibraryScanEnumerationState? {
    guard !runUID.isEmpty, !runUID.contains("\0") else {
      throw SDKError(code: .invalidConfiguration, message: "scan run identity is invalid")
    }
    do {
      return try await database.read { database in
        guard
          let runID = try Int64.fetchOne(
            database,
            sql: "SELECT id FROM scan_run WHERE uid = ?",
            arguments: [runUID]
          )
        else { return nil }
        let frontierRows = try Row.fetchAll(
          database,
          sql: """
            SELECT directory_json, cursor_token, state
            FROM scan_frontier
            WHERE run_id = ?
            ORDER BY directory_json, cursor_token
            """,
          arguments: [runID]
        )
        let decoder = JSONDecoder()
        var pending: [LibraryScanFrontierPage] = []
        var completed: [LibraryScanFrontierPage] = []
        for row in frontierRows {
          let directoryJSON: String = row["directory_json"]
          let locator = try decoder.decode(RemoteLocator.self, from: Data(directoryJSON.utf8))
          let cursorToken: String = row["cursor_token"]
          let page = try LibraryScanFrontierPage(
            directory: locator,
            cursor: cursorToken.isEmpty ? nil : cursorToken
          )
          let state: String = row["state"]
          if state == "pending" { pending.append(page) } else { completed.append(page) }
        }
        let seenRows = try Row.fetchAll(
          database,
          sql: """
            SELECT identity_key, is_directory
            FROM scan_seen
            WHERE run_id = ?
            ORDER BY identity_key
            """,
          arguments: [runID]
        )
        let seenEntries: [String] = seenRows.map { $0["identity_key"] }
        let seenDirectories: [String] = seenRows.compactMap { row in
          (row["is_directory"] as Int) == 1 ? row["identity_key"] : nil
        }
        return try LibraryScanEnumerationState(
          pendingPages: pending,
          completedPages: completed,
          seenEntryIdentityKeys: seenEntries,
          seenDirectoryIdentityKeys: seenDirectories
        )
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "scan frontier read failed")
    }
  }

  /// Returns new, changed, or previously failed files awaiting one processing stage.
  public func pendingScanWork(
    sourceUID: String,
    stage: LibraryScanQueueStage
  ) async throws -> [LibraryScanWorkItem] {
    guard !sourceUID.isEmpty, !sourceUID.contains("\0") else {
      throw SDKError(code: .invalidConfiguration, message: "scan work source is invalid")
    }
    let now = clock.nowMilliseconds()
    do {
      return try await database.read { database in
        let rows = try Row.fetchAll(
          database,
          sql: """
            SELECT f.relative_path, MAX(q.attempts) AS attempts
            FROM scan_queue q
            JOIN media_file f ON f.id = q.media_file_id
            JOIN library_source s ON s.id = f.source_id
            WHERE s.uid = ?
              AND s.deleted_at_ms IS NULL
              AND f.deleted_at_ms IS NULL
              AND f.availability = 'present'
              AND q.stage = ?
              AND q.state IN ('queued', 'retry', 'failed')
              AND q.input_revision = f.material_revision
              AND (q.next_attempt_at_ms IS NULL OR q.next_attempt_at_ms <= ?)
            GROUP BY f.id, f.relative_path, f.path_compare_key
            ORDER BY f.path_compare_key, f.id
            """,
          arguments: [sourceUID, stage.rawValue, now]
        )
        return try rows.map { row in
          try LibraryScanWorkItem(
            relativePath: row["relative_path"],
            attempts: row["attempts"]
          )
        }
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "pending scan work read failed")
    }
  }

  /// Reports whether current file revisions still have durable work in a stage.
  ///
  /// Unlike ready-work queries, this includes deferred retries and unexpired leases,
  /// allowing schedulers to recover work after process termination without rescanning
  /// the source merely to rediscover the queue.
  public func hasOutstandingScanWork(
    sourceUID: String,
    stage: LibraryScanQueueStage
  ) async throws -> Bool {
    guard !sourceUID.isEmpty, !sourceUID.contains("\0") else {
      throw SDKError(code: .invalidConfiguration, message: "scan work source is invalid")
    }
    do {
      return try await database.read { database in
        try Bool.fetchOne(
          database,
          sql: """
            SELECT EXISTS(
              SELECT 1
              FROM scan_queue q
              JOIN media_file f ON f.id = q.media_file_id
              JOIN library_source s ON s.id = f.source_id
              WHERE s.uid = ?
                AND s.deleted_at_ms IS NULL
                AND f.deleted_at_ms IS NULL
                AND f.availability = 'present'
                AND q.stage = ?
                AND q.state IN ('queued', 'running', 'retry', 'failed')
                AND q.input_revision = f.material_revision
            )
            """,
          arguments: [sourceUID, stage.rawValue]
        ) ?? false
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "outstanding scan work query failed")
    }
  }

  /// Atomically claims a bounded batch of ready work for one worker.
  ///
  /// Expired leases are reclaimable. Work created for an older material revision is
  /// never returned, so a slow worker cannot later overwrite newer scan input.
  public func claimScanFileWork(
    sourceUID: String,
    stage: LibraryScanQueueStage,
    workerID: String,
    limit: Int = 50,
    leaseDurationMilliseconds: Int64 = 120_000
  ) async throws -> [LibraryScanWorkLease] {
    let normalizedWorkerID = workerID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sourceUID.isEmpty, !sourceUID.contains("\0"),
      !normalizedWorkerID.isEmpty, normalizedWorkerID.count <= 256,
      !normalizedWorkerID.contains("\0"), (1...500).contains(limit),
      (1_000...86_400_000).contains(leaseDurationMilliseconds)
    else {
      throw SDKError(code: .invalidConfiguration, message: "scan work claim is invalid")
    }
    let now = clock.nowMilliseconds()
    let leaseUntil = now + leaseDurationMilliseconds
    let uuidGenerator = self.uuidGenerator
    do {
      return try await database.write { database in
        let rows = try Row.fetchAll(
          database,
          sql: """
            SELECT q.id AS queue_id, q.attempts, q.input_revision,
                   f.id AS file_id, s.uid AS source_uid, f.stable_key,
                   f.relative_path, f.path_compare_key, f.size_bytes,
                   f.modified_at_ms, f.etag, f.availability, f.missing_scan_count,
                   EXISTS(
                     SELECT 1
                     FROM file_binding b
                     WHERE b.media_file_id = f.id
                       AND b.binding_role IN ('primary', 'version')
                   ) AS has_matching_binding
            FROM scan_queue q
            JOIN media_file f ON f.id = q.media_file_id
            JOIN library_source s ON s.id = f.source_id
            WHERE s.uid = ?
              AND s.deleted_at_ms IS NULL
              AND f.deleted_at_ms IS NULL
              AND f.availability = 'present'
              AND q.stage = ?
              AND q.state IN ('queued', 'running', 'retry', 'failed')
              AND q.input_revision = f.material_revision
              AND (
                (q.state IN ('queued', 'retry', 'failed')
                  AND (q.next_attempt_at_ms IS NULL OR q.next_attempt_at_ms <= ?))
                OR (q.state = 'running' AND q.lease_until_ms IS NOT NULL
                  AND q.lease_until_ms <= ?)
              )
            ORDER BY q.priority DESC, q.id
            LIMIT ?
            """,
          arguments: [sourceUID, stage.rawValue, now, now, limit]
        )
        var leases: [LibraryScanWorkLease] = []
        leases.reserveCapacity(rows.count)
        for row in rows {
          let queueID: Int64 = row["queue_id"]
          let inputRevision: Int64 = row["input_revision"]
          let claimToken =
            uuidGenerator.makeUUID().uuidString.lowercased() + ":" + String(queueID)
          try database.execute(
            sql: """
              UPDATE scan_queue
              SET state = 'running', claimed_by = ?, claim_token = ?,
                  lease_until_ms = ?, heartbeat_at_ms = ?,
                  error_code = NULL, error_message = NULL, updated_at_ms = ?
              WHERE id = ? AND input_revision = ?
                AND (
                  (state IN ('queued', 'retry', 'failed')
                    AND (next_attempt_at_ms IS NULL OR next_attempt_at_ms <= ?))
                  OR (state = 'running' AND lease_until_ms IS NOT NULL
                    AND lease_until_ms <= ?)
                )
              """,
            arguments: [
              normalizedWorkerID, claimToken, leaseUntil, now, now,
              queueID, inputRevision, now, now,
            ]
          )
          guard database.changesCount == 1 else {
            throw SDKError(code: .conflict, message: "scan work claim became stale")
          }
          let file = LibraryFileFact(
            sourceUID: row["source_uid"],
            stableKey: row["stable_key"],
            relativePath: row["relative_path"],
            sizeBytes: row["size_bytes"],
            modifiedAtMilliseconds: row["modified_at_ms"],
            entityTag: row["etag"],
            availability: row["availability"],
            missingScanCount: row["missing_scan_count"]
          )
          leases.append(
            try LibraryScanWorkLease(
              queueID: queueID,
              file: file,
              stage: stage,
              attempts: row["attempts"],
              hasMatchingBinding: (row["has_matching_binding"] as Int) != 0,
              inputRevision: inputRevision,
              workerID: normalizedWorkerID,
              claimToken: claimToken,
              leaseUntilMilliseconds: leaseUntil
            )
          )
        }
        return leases
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "scan work claim failed")
    }
  }

  /// Extends an unexpired lease while preserving the same ownership token.
  public func renewScanWorkLease(
    _ lease: LibraryScanWorkLease,
    leaseDurationMilliseconds: Int64 = 120_000
  ) async throws -> LibraryScanWorkLease {
    guard (1_000...86_400_000).contains(leaseDurationMilliseconds) else {
      throw SDKError(code: .invalidConfiguration, message: "scan work lease duration is invalid")
    }
    let now = clock.nowMilliseconds()
    let leaseUntil = now + leaseDurationMilliseconds
    do {
      return try await database.write { database in
        try database.execute(
          sql: """
            UPDATE scan_queue
            SET lease_until_ms = ?, heartbeat_at_ms = ?, updated_at_ms = ?
            WHERE id = ? AND stage = ? AND state = 'running'
              AND claimed_by = ? AND claim_token = ? AND input_revision = ?
              AND lease_until_ms > ?
              AND EXISTS(
                SELECT 1 FROM media_file f
                WHERE f.id = scan_queue.media_file_id
                  AND f.material_revision = scan_queue.input_revision
                  AND f.availability = 'present' AND f.deleted_at_ms IS NULL
              )
            """,
          arguments: [
            leaseUntil, now, now, lease.queueID, lease.stage.rawValue,
            lease.workerID, lease.claimToken, lease.inputRevision, now,
          ]
        )
        guard database.changesCount == 1 else {
          throw SDKError(code: .conflict, message: "scan work lease is expired or stale")
        }
        return try lease.renewed(until: leaseUntil)
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "scan work lease renewal failed")
    }
  }

  /// Returns one stable keyset page of pending work with all file facts needed by a worker.
  public func pendingScanFileWorkPage(
    sourceUID: String,
    stage: LibraryScanQueueStage,
    pageSize: Int = 200,
    cursor: String? = nil
  ) async throws -> LibraryScanFileWorkPage {
    guard !sourceUID.isEmpty, !sourceUID.contains("\0"), (1...500).contains(pageSize) else {
      throw SDKError(code: .invalidConfiguration, message: "scan file work query is invalid")
    }
    let decodedCursor: LibraryScanFileWorkCursor?
    if let cursor {
      decodedCursor = try Self.decodeScanFileWorkCursor(cursor)
      guard decodedCursor?.schemaVersion == 1,
        decodedCursor?.sourceUID == sourceUID,
        decodedCursor?.stage == stage.rawValue,
        decodedCursor.map({ $0.fileID > 0 && !$0.pathCompareKey.contains("\0") }) == true
      else {
        throw SDKError(code: .conflict, message: "scan file work cursor is incompatible")
      }
    } else {
      decodedCursor = nil
    }

    let now = clock.nowMilliseconds()
    do {
      return try await database.read { database in
        let cursorPredicate: String
        let arguments: StatementArguments
        if let decodedCursor {
          cursorPredicate = """
              AND (f.path_compare_key > ?
                OR (f.path_compare_key = ? AND f.id > ?))
            """
          arguments = [
            stage.rawValue, now, sourceUID,
            decodedCursor.pathCompareKey, decodedCursor.pathCompareKey, decodedCursor.fileID,
            pageSize + 1,
          ]
        } else {
          cursorPredicate = ""
          arguments = [stage.rawValue, now, sourceUID, pageSize + 1]
        }
        let rows = try Row.fetchAll(
          database,
          sql: """
            WITH pending AS (
              SELECT q.media_file_id, MAX(q.attempts) AS attempts
              FROM scan_queue q
              JOIN media_file current_file ON current_file.id = q.media_file_id
              WHERE q.stage = ? AND q.state IN ('queued', 'retry', 'failed')
                AND q.input_revision = current_file.material_revision
                AND (q.next_attempt_at_ms IS NULL OR q.next_attempt_at_ms <= ?)
              GROUP BY q.media_file_id
            )
            SELECT f.id AS file_id, s.uid AS source_uid, f.stable_key,
                   f.relative_path, f.path_compare_key, f.size_bytes,
                   f.modified_at_ms, f.etag, f.availability, f.missing_scan_count,
                   pending.attempts,
                   EXISTS(
                     SELECT 1
                     FROM file_binding b
                     WHERE b.media_file_id = f.id
                       AND b.binding_role IN ('primary', 'version')
                   ) AS has_matching_binding
            FROM pending
            JOIN media_file f ON f.id = pending.media_file_id
            JOIN library_source s ON s.id = f.source_id
            WHERE s.uid = ?
              AND s.deleted_at_ms IS NULL
              AND f.deleted_at_ms IS NULL
              AND f.availability = 'present'
            \(cursorPredicate)
            ORDER BY f.path_compare_key, f.id
            LIMIT ?
            """,
          arguments: arguments
        )
        let selectedRows = rows.prefix(pageSize)
        let items = try selectedRows.map { row in
          let file = LibraryFileFact(
            sourceUID: row["source_uid"],
            stableKey: row["stable_key"],
            relativePath: row["relative_path"],
            sizeBytes: row["size_bytes"],
            modifiedAtMilliseconds: row["modified_at_ms"],
            entityTag: row["etag"],
            availability: row["availability"],
            missingScanCount: row["missing_scan_count"]
          )
          let hasMatchingBinding = (row["has_matching_binding"] as Int) != 0
          return try LibraryScanFileWorkItem(
            file: file,
            attempts: row["attempts"],
            hasMatchingBinding: hasMatchingBinding
          )
        }
        let nextCursor: String?
        if rows.count > pageSize, let last = selectedRows.last {
          nextCursor = try Self.encodeScanFileWorkCursor(
            LibraryScanFileWorkCursor(
              sourceUID: sourceUID,
              stage: stage,
              pathCompareKey: last["path_compare_key"],
              fileID: last["file_id"]
            )
          )
        } else {
          nextCursor = nil
        }
        return LibraryScanFileWorkPage(items: items, nextCursor: nextCursor)
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "pending scan file work read failed")
    }
  }

  /// Returns present and matched file counts without materializing a full library snapshot.
  public func sourceMediaSummary(sourceUID: String) async throws -> LibrarySourceMediaSummary {
    guard !sourceUID.isEmpty, !sourceUID.contains("\0") else {
      throw SDKError(
        code: .invalidConfiguration,
        message: "library source summary query is invalid"
      )
    }
    do {
      return try await database.read { database in
        let row = try Row.fetchOne(
          database,
          sql: """
            SELECT COUNT(*) AS present_file_count,
                   COALESCE(SUM(
                     CASE WHEN EXISTS(
                       SELECT 1
                       FROM file_binding b
                       WHERE b.media_file_id = f.id
                         AND b.binding_role IN ('primary', 'version')
                     ) THEN 1 ELSE 0 END
                   ), 0) AS matched_file_count
            FROM media_file f
            JOIN library_source s ON s.id = f.source_id
            WHERE s.uid = ?
              AND s.deleted_at_ms IS NULL
              AND f.deleted_at_ms IS NULL
              AND f.availability = 'present'
            """,
          arguments: [sourceUID]
        )
        return try LibrarySourceMediaSummary(
          presentFileCount: row?["present_file_count"] ?? 0,
          matchedFileCount: row?["matched_file_count"] ?? 0
        )
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "library source summary read failed")
    }
  }

  /// Returns present file paths that already have a primary or version metadata binding.
  public func matchedMediaRelativePaths(sourceUID: String) async throws -> [String] {
    guard !sourceUID.isEmpty, !sourceUID.contains("\0") else {
      throw SDKError(code: .invalidConfiguration, message: "matched media source is invalid")
    }
    do {
      return try await database.read { database in
        try String.fetchAll(
          database,
          sql: """
            SELECT DISTINCT f.relative_path
            FROM media_file f
            JOIN library_source s ON s.id = f.source_id
            JOIN file_binding b ON b.media_file_id = f.id
            WHERE s.uid = ?
              AND s.deleted_at_ms IS NULL
              AND f.deleted_at_ms IS NULL
              AND f.availability = 'present'
              AND b.binding_role IN ('primary', 'version')
            ORDER BY f.path_compare_key, f.id
            """,
          arguments: [sourceUID]
        )
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "matched media paths read failed")
    }
  }

  /// Marks every outstanding copy of one file-stage task as successfully processed.
  public func completeScanWork(_ lease: LibraryScanWorkLease) async throws {
    let now = clock.nowMilliseconds()
    do {
      try await database.write { database in
        try Self.requireActiveScanWorkLease(lease, now: now, database: database)
        try database.execute(
          sql: """
            UPDATE scan_queue
            SET state = 'done', next_attempt_at_ms = NULL, lease_until_ms = NULL,
                claimed_by = NULL, claim_token = NULL, heartbeat_at_ms = NULL,
                error_code = NULL, error_message = NULL, updated_at_ms = ?
            WHERE id = ? AND stage = ? AND state = 'running'
              AND claimed_by = ? AND claim_token = ? AND input_revision = ?
            """,
          arguments: [
            now, lease.queueID, lease.stage.rawValue, lease.workerID,
            lease.claimToken, lease.inputRevision,
          ]
        )
        guard database.changesCount == 1 else {
          throw SDKError(code: .conflict, message: "scan work completion lost its lease")
        }
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "scan work completion failed")
    }
  }

  /// Marks every outstanding copy of one file-stage task as successfully processed.
  @available(*, deprecated, message: "Claim work and complete it with LibraryScanWorkLease")
  public func completeScanWork(
    sourceUID: String,
    relativePath: String,
    stage: LibraryScanQueueStage
  ) async throws {
    let path = try RemotePath(relativePath)
    guard !sourceUID.isEmpty, !sourceUID.contains("\0"), !path.isRoot else {
      throw SDKError(code: .invalidConfiguration, message: "scan work identity is invalid")
    }
    let now = clock.nowMilliseconds()
    do {
      try await database.write { database in
        try database.execute(
          sql: """
            UPDATE scan_queue
            SET state = 'done', next_attempt_at_ms = NULL, lease_until_ms = NULL,
                claimed_by = NULL, claim_token = NULL, heartbeat_at_ms = NULL,
                error_code = NULL, error_message = NULL, updated_at_ms = ?
            WHERE stage = ?
              AND state IN ('queued', 'retry', 'failed')
              AND media_file_id = (
                SELECT f.id
                FROM media_file f
                JOIN library_source s ON s.id = f.source_id
                WHERE s.uid = ? AND f.relative_path = ?
                  AND s.deleted_at_ms IS NULL AND f.deleted_at_ms IS NULL
              )
            """,
          arguments: [now, stage.rawValue, sourceUID, path.relativePath]
        )
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "scan work completion failed")
    }
  }

  /// Materializes provider metadata and completes its claimed work item atomically.
  @discardableResult
  public func commitRemoteMetadata(
    _ metadata: LibraryRemoteMetadata,
    completing lease: LibraryScanWorkLease
  ) async throws -> String {
    try await commitRemoteMetadata(
      metadata,
      sourceUID: lease.file.sourceUID,
      relativePath: lease.file.relativePath,
      completing: lease.stage,
      lease: lease
    )
  }

  /// Materializes provider metadata and completes the corresponding work item atomically.
  @discardableResult
  @available(*, deprecated, message: "Claim work and commit it with LibraryScanWorkLease")
  public func commitRemoteMetadata(
    _ metadata: LibraryRemoteMetadata,
    sourceUID: String,
    relativePath: String,
    completing stage: LibraryScanQueueStage
  ) async throws -> String {
    try await commitRemoteMetadata(
      metadata,
      sourceUID: sourceUID,
      relativePath: relativePath,
      completing: stage,
      lease: nil
    )
  }

  private func commitRemoteMetadata(
    _ metadata: LibraryRemoteMetadata,
    sourceUID: String,
    relativePath: String,
    completing stage: LibraryScanQueueStage,
    lease: LibraryScanWorkLease?
  ) async throws -> String {
    let path = try RemotePath(relativePath)
    guard !sourceUID.isEmpty, !sourceUID.contains("\0"), !path.isRoot else {
      throw SDKError(code: .invalidConfiguration, message: "remote metadata target is invalid")
    }
    let now = clock.nowMilliseconds()
    let artworkUID = uuidGenerator.makeUUID().uuidString.lowercased()
    do {
      return try await database.write { database in
        guard
          let file = try Row.fetchOne(
            database,
            sql: """
              SELECT f.id
              FROM media_file f
              JOIN library_source s ON s.id = f.source_id
              WHERE s.uid = ? AND f.relative_path = ?
                AND s.deleted_at_ms IS NULL AND f.deleted_at_ms IS NULL
              """,
            arguments: [sourceUID, path.relativePath]
          )
        else {
          throw SDKError(code: .metadataNotFound, message: "remote metadata file was not found")
        }
        let mediaFileID: Int64 = file["id"]
        if let lease {
          guard lease.file.sourceUID == sourceUID,
            lease.file.relativePath == path.relativePath,
            lease.stage == stage
          else {
            throw SDKError(code: .conflict, message: "scan work lease target changed")
          }
          try Self.requireActiveScanWorkLease(
            lease,
            expectedMediaFileID: mediaFileID,
            now: now,
            database: database
          )
        }
        guard
          let entity = try Row.fetchOne(
            database,
            sql: """
              WITH RECURSIVE ancestors(id, uid, kind, parent_id) AS (
                SELECT e.id, e.uid, e.kind, e.parent_id
                FROM file_binding b
                JOIN media_entity e ON e.id = b.entity_id
                WHERE b.media_file_id = ? AND b.binding_role IN ('primary', 'version')
                UNION ALL
                SELECT parent.id, parent.uid, parent.kind, parent.parent_id
                FROM media_entity parent
                JOIN ancestors child ON child.parent_id = parent.id
              )
              SELECT a.id, a.uid, root.metadata_state, root.locked_fields_json
              FROM ancestors a
              JOIN media_entity root ON root.id = a.id
              JOIN external_id external
                ON external.entity_id = a.id
               AND external.provider = ?
               AND external.namespace = ?
               AND external.external_value = ?
              WHERE a.kind = ? AND a.parent_id IS NULL
              LIMIT 1
              """,
            arguments: [
              mediaFileID, metadata.provider, metadata.kind.rawValue,
              metadata.providerID, metadata.kind.rawValue,
            ]
          )
        else {
          throw SDKError(
            code: .conflict,
            message: "provider metadata does not match the file's bound root entity"
          )
        }
        let entityID: Int64 = entity["id"]
        let entityUID: String = entity["uid"]
        let metadataState: String = entity["metadata_state"]
        let lockedFieldsJSON: String? = entity["locked_fields_json"]
        let hasLockedBinding =
          (try Int.fetchOne(
            database,
            sql: """
              WITH RECURSIVE descendants(id) AS (
                SELECT ?
                UNION ALL
                SELECT child.id
                FROM media_entity child
                JOIN descendants parent ON child.parent_id = parent.id
              )
              SELECT COUNT(*)
              FROM file_binding
              WHERE entity_id IN descendants AND locked = 1
              """,
            arguments: [entityID]
          ) ?? 0) > 0
        let preservesUserMetadata =
          metadataState == "manual" || lockedFieldsJSON != nil || hasLockedBinding

        if !preservesUserMetadata {
          try database.execute(
            sql: """
              UPDATE media_entity SET
                canonical_title = ?, original_title = ?, sort_title = ?,
                year = COALESCE(?, year), metadata_state = 'complete', updated_at_ms = ?
              WHERE id = ?
              """,
            arguments: [
              metadata.title, metadata.originalTitle, metadata.title, metadata.year, now, entityID,
            ]
          )
          try database.execute(
            sql: """
              INSERT INTO localized_metadata(
                entity_id, locale, title, sort_title, overview, provider,
                provider_updated_at_ms, materialized_at_ms
              ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
              ON CONFLICT(entity_id, locale) DO UPDATE SET
                title = excluded.title,
                sort_title = excluded.sort_title,
                overview = excluded.overview,
                provider = excluded.provider,
                provider_updated_at_ms = excluded.provider_updated_at_ms,
                materialized_at_ms = excluded.materialized_at_ms
              """,
            arguments: [
              entityID, metadata.locale, metadata.title, metadata.title, metadata.overview,
              metadata.provider, now, now,
            ]
          )

          if let posterURL = metadata.posterURL {
            try database.execute(
              sql: """
                UPDATE artwork SET is_selected = 0, updated_at_ms = ?
                WHERE entity_id = ? AND kind = 'poster' AND locale = ? AND is_selected = 1
                """,
              arguments: [now, entityID, metadata.locale]
            )
            try database.execute(
              sql: """
                INSERT INTO artwork(
                  uid, entity_id, kind, locale, provider, remote_url, width, height,
                  score, is_selected, fetched_at_ms, updated_at_ms
                ) VALUES (?, ?, 'poster', ?, ?, ?, ?, ?, 1, 1, ?, ?)
                ON CONFLICT(entity_id, kind, provider, remote_url)
                  WHERE remote_url IS NOT NULL
                DO UPDATE SET
                  locale = excluded.locale,
                  width = excluded.width,
                  height = excluded.height,
                  score = excluded.score,
                  is_selected = 1,
                  fetched_at_ms = excluded.fetched_at_ms,
                  updated_at_ms = excluded.updated_at_ms
                """,
              arguments: [
                artworkUID, entityID, metadata.locale, metadata.provider, posterURL,
                metadata.posterWidth, metadata.posterHeight, now, now,
              ]
            )
          }
        }

        try Self.upsertSearchDocument(
          entityID: entityID,
          updatedAtMilliseconds: now,
          database: database
        )

        if let lease {
          try database.execute(
            sql: """
              UPDATE scan_queue
              SET state = 'done', next_attempt_at_ms = NULL, lease_until_ms = NULL,
                  claimed_by = NULL, claim_token = NULL, heartbeat_at_ms = NULL,
                  error_code = NULL, error_message = NULL, updated_at_ms = ?
              WHERE id = ? AND stage = ? AND state = 'running'
                AND claimed_by = ? AND claim_token = ? AND input_revision = ?
              """,
            arguments: [
              now, lease.queueID, stage.rawValue, lease.workerID,
              lease.claimToken, lease.inputRevision,
            ]
          )
          guard database.changesCount == 1 else {
            throw SDKError(code: .conflict, message: "remote metadata commit lost its lease")
          }
        } else {
          try database.execute(
            sql: """
              UPDATE scan_queue
              SET state = 'done', next_attempt_at_ms = NULL, lease_until_ms = NULL,
                  claimed_by = NULL, claim_token = NULL, heartbeat_at_ms = NULL,
                  error_code = NULL, error_message = NULL, updated_at_ms = ?
              WHERE stage = ? AND media_file_id = ?
                AND state IN ('queued', 'retry', 'failed')
              """,
            arguments: [now, stage.rawValue, mediaFileID]
          )
        }
        return entityUID
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "remote metadata commit failed")
    }
  }

  /// Releases claimed work for a later retry if the lease and input revision are current.
  public func retryScanWork(
    _ lease: LibraryScanWorkLease,
    errorCode: SDKErrorCode,
    retryAfterMilliseconds: Int64? = nil
  ) async throws {
    guard retryAfterMilliseconds.map({ (0...604_800_000).contains($0) }) ?? true else {
      throw SDKError(code: .invalidConfiguration, message: "scan work retry delay is invalid")
    }
    let now = clock.nowMilliseconds()
    let nextAttempt = retryAfterMilliseconds.map { now + $0 }
    do {
      try await database.write { database in
        try Self.requireActiveScanWorkLease(lease, now: now, database: database)
        try database.execute(
          sql: """
            UPDATE scan_queue
            SET state = 'retry', attempts = attempts + 1,
                next_attempt_at_ms = ?, lease_until_ms = NULL,
                claimed_by = NULL, claim_token = NULL, heartbeat_at_ms = NULL,
                error_code = ?, error_message = NULL, updated_at_ms = ?
            WHERE id = ? AND stage = ? AND state = 'running'
              AND claimed_by = ? AND claim_token = ? AND input_revision = ?
            """,
          arguments: [
            nextAttempt, errorCode.rawValue, now, lease.queueID, lease.stage.rawValue,
            lease.workerID, lease.claimToken, lease.inputRevision,
          ]
        )
        guard database.changesCount == 1 else {
          throw SDKError(code: .conflict, message: "scan work retry lost its lease")
        }
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "scan work retry update failed")
    }
  }

  /// Keeps one file-stage task durable so a later manual or repair scan can retry it.
  @available(*, deprecated, message: "Claim work and retry it with LibraryScanWorkLease")
  public func retryScanWork(
    sourceUID: String,
    relativePath: String,
    stage: LibraryScanQueueStage,
    errorCode: SDKErrorCode
  ) async throws {
    let path = try RemotePath(relativePath)
    guard !sourceUID.isEmpty, !sourceUID.contains("\0"), !path.isRoot else {
      throw SDKError(code: .invalidConfiguration, message: "scan work identity is invalid")
    }
    let now = clock.nowMilliseconds()
    do {
      try await database.write { database in
        guard
          let row = try Row.fetchOne(
            database,
            sql: """
              SELECT f.id AS media_file_id, f.material_revision, r.id AS run_id
              FROM media_file f
              JOIN library_source s ON s.id = f.source_id
              JOIN scan_run r ON r.source_id = s.id
              WHERE s.uid = ? AND f.relative_path = ?
                AND s.deleted_at_ms IS NULL AND f.deleted_at_ms IS NULL
              ORDER BY r.id DESC
              LIMIT 1
              """,
            arguments: [sourceUID, path.relativePath]
          )
        else {
          throw SDKError(code: .metadataNotFound, message: "scan work file was not found")
        }
        let mediaFileID: Int64 = row["media_file_id"]
        let inputRevision: Int64 = row["material_revision"]
        let runID: Int64 = row["run_id"]
        try database.execute(
          sql: """
            INSERT INTO scan_queue(
              run_id, media_file_id, stage, state, attempts,
              next_attempt_at_ms, lease_until_ms, error_code, error_message,
              input_revision, updated_at_ms
            ) VALUES (?, ?, ?, 'retry', 1, NULL, NULL, ?, NULL, ?, ?)
            ON CONFLICT(run_id, media_file_id, stage) DO UPDATE SET
              state = 'retry',
              attempts = scan_queue.attempts + 1,
              next_attempt_at_ms = NULL,
              lease_until_ms = NULL,
              claimed_by = NULL,
              claim_token = NULL,
              heartbeat_at_ms = NULL,
              error_code = excluded.error_code,
              error_message = NULL,
              input_revision = excluded.input_revision,
              updated_at_ms = excluded.updated_at_ms
            WHERE scan_queue.state <> 'running'
            """,
          arguments: [
            runID, mediaFileID, stage.rawValue, errorCode.rawValue, inputRevision, now,
          ]
        )
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "scan work retry update failed")
    }
  }

  /// Returns a deterministic projection for fixtures, inspection, and cross-platform comparison.
  public func snapshot() async throws -> LibrarySnapshot {
    do {
      return try await database.read { database in
        let sources = try String.fetchAll(
          database,
          sql: "SELECT uid FROM library_source WHERE deleted_at_ms IS NULL ORDER BY uid"
        )
        let rows = try Row.fetchAll(
          database,
          sql: """
            SELECT s.uid AS source_uid, f.stable_key, f.relative_path, f.size_bytes,
                   f.modified_at_ms, f.etag, f.availability, f.missing_scan_count
            FROM media_file f
            JOIN library_source s ON s.id = f.source_id
            ORDER BY s.uid, f.path_compare_key, f.stable_key
            """
        )
        let files = rows.map { row in
          LibraryFileFact(
            sourceUID: row["source_uid"],
            stableKey: row["stable_key"],
            relativePath: row["relative_path"],
            sizeBytes: row["size_bytes"],
            modifiedAtMilliseconds: row["modified_at_ms"],
            entityTag: row["etag"],
            availability: row["availability"],
            missingScanCount: row["missing_scan_count"]
          )
        }
        return LibrarySnapshot(schemaVersion: 1, sources: sources, files: files)
      }
    } catch {
      throw SDKError(code: .storageFailure, message: "library snapshot read failed")
    }
  }

  /// Atomically replaces filename, sidecar, and any newly successful probe results.
  package func commitMetadataIntake(_ batch: LibraryMetadataIntakeBatch) async throws {
    let now = clock.nowMilliseconds()
    let generatedUIDs = batch.sidecars.map { _ in uuidGenerator.makeUUID().uuidString.lowercased() }
    do {
      try await database.write { database in
        guard
          let mediaFileID = try Int64.fetchOne(
            database,
            sql: """
              SELECT f.id
              FROM media_file f
              JOIN library_source s ON s.id = f.source_id
              WHERE s.uid = ? AND f.relative_path = ? AND f.deleted_at_ms IS NULL
              """,
            arguments: [batch.sourceUID, batch.mediaRelativePath]
          )
        else {
          throw SDKError(code: .metadataNotFound, message: "scanned media file was not found")
        }

        let parse = batch.parseResult
        try database.execute(
          sql: """
            INSERT INTO parse_result(
              media_file_id, media_kind, clean_title, sort_title, hint_year, season_number,
              episode_start, episode_end, edition, release_group, language_hint,
              provider_hints_json, raw_tokens_json, confidence, parser_version, updated_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(media_file_id) DO UPDATE SET
              media_kind = excluded.media_kind,
              clean_title = excluded.clean_title,
              sort_title = excluded.sort_title,
              hint_year = excluded.hint_year,
              season_number = excluded.season_number,
              episode_start = excluded.episode_start,
              episode_end = excluded.episode_end,
              edition = excluded.edition,
              release_group = excluded.release_group,
              language_hint = excluded.language_hint,
              provider_hints_json = excluded.provider_hints_json,
              raw_tokens_json = excluded.raw_tokens_json,
              confidence = excluded.confidence,
              parser_version = excluded.parser_version,
              updated_at_ms = excluded.updated_at_ms
            """,
          arguments: [
            mediaFileID, parse.mediaKind, parse.cleanTitle, parse.sortTitle, parse.hintYear,
            parse.seasonNumber, parse.episodeStart, parse.episodeEnd, parse.edition,
            parse.releaseGroup, parse.languageHint, parse.providerHintsJSON, parse.rawTokensJSON,
            parse.confidence, parse.parserVersion, now,
          ]
        )

        if batch.sidecars.isEmpty {
          try database.execute(
            sql: "DELETE FROM sidecar WHERE media_file_id = ?",
            arguments: [mediaFileID]
          )
        } else {
          let retainedPaths = Set(batch.sidecars.map(\.relativePath))
          let existingPaths = try String.fetchAll(
            database,
            sql: "SELECT relative_path FROM sidecar WHERE media_file_id = ?",
            arguments: [mediaFileID]
          )
          for path in existingPaths where !retainedPaths.contains(path) {
            try database.execute(
              sql: "DELETE FROM sidecar WHERE media_file_id = ? AND relative_path = ?",
              arguments: [mediaFileID, path]
            )
          }
          for (sidecar, generatedUID) in zip(batch.sidecars, generatedUIDs) {
            try database.execute(
              sql: """
                INSERT INTO sidecar(
                  uid, media_file_id, kind, relative_path, language, forced,
                  modified_at_ms, sha256, parsed_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(media_file_id, relative_path) DO UPDATE SET
                  kind = excluded.kind,
                  language = excluded.language,
                  forced = excluded.forced,
                  modified_at_ms = excluded.modified_at_ms,
                  sha256 = excluded.sha256,
                  parsed_json = excluded.parsed_json
                """,
              arguments: [
                generatedUID, mediaFileID, sidecar.kind, sidecar.relativePath, sidecar.language,
                sidecar.isForced ? 1 : 0, sidecar.modifiedAtMilliseconds, sidecar.sha256,
                sidecar.parsedJSON,
              ]
            )
          }
        }

        if let probe = batch.technicalProbe {
          let summary = probe.summary
          try database.execute(
            sql: """
              INSERT INTO technical_summary(
                media_file_id, container, duration_ms, overall_bitrate, video_codec,
                width, height, frame_rate, hdr_profile, audio_codec, audio_channels,
                embedded_cover, probe_provider, probe_version, probed_at_ms
              ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
              ON CONFLICT(media_file_id) DO UPDATE SET
                container = excluded.container,
                duration_ms = excluded.duration_ms,
                overall_bitrate = excluded.overall_bitrate,
                video_codec = excluded.video_codec,
                width = excluded.width,
                height = excluded.height,
                frame_rate = excluded.frame_rate,
                hdr_profile = excluded.hdr_profile,
                audio_codec = excluded.audio_codec,
                audio_channels = excluded.audio_channels,
                embedded_cover = excluded.embedded_cover,
                probe_provider = excluded.probe_provider,
                probe_version = excluded.probe_version,
                probed_at_ms = excluded.probed_at_ms
              """,
            arguments: [
              mediaFileID, summary.container, summary.durationMilliseconds, summary.overallBitrate,
              summary.videoCodec, summary.width, summary.height, summary.frameRate,
              summary.hdrProfile, summary.audioCodec, summary.audioChannels,
              summary.hasEmbeddedCover ? 1 : 0, probe.probeProvider, probe.probeVersion, now,
            ]
          )
          try database.execute(
            sql: "DELETE FROM media_stream WHERE media_file_id = ?",
            arguments: [mediaFileID]
          )
          for stream in probe.streams {
            try database.execute(
              sql: """
                INSERT INTO media_stream(
                  media_file_id, stream_index, kind, codec, language, title, bit_rate,
                  width, height, frame_rate, hdr_profile, channel_count, channel_layout,
                  sample_rate, is_default, is_forced
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
              arguments: [
                mediaFileID, stream.streamIndex, stream.kind, stream.codec, stream.language,
                stream.title, stream.bitrate, stream.width, stream.height, stream.frameRate,
                stream.hdrProfile, stream.channelCount, stream.channelLayout, stream.sampleRate,
                stream.isDefault ? 1 : 0, stream.isForced ? 1 : 0,
              ]
            )
          }
        }

        try database.execute(
          sql: """
            UPDATE media_file SET
              parser_version = ?,
              probe_version = CASE WHEN ? IS NULL THEN probe_version ELSE ? END,
              updated_at_ms = ?
            WHERE id = ?
            """,
          arguments: [
            parse.parserVersion, batch.technicalProbe?.probeVersion,
            batch.technicalProbe?.probeVersion, now, mediaFileID,
          ]
        )
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "metadata intake transaction failed")
    }
  }

  /// Reads normalized local metadata for one scanned media file.
  package func metadataIntakeSnapshot(
    sourceUID: String,
    mediaRelativePath: String
  ) async throws -> LibraryMetadataIntakeSnapshot? {
    do {
      return try await database.read { database in
        guard
          let file = try Row.fetchOne(
            database,
            sql: """
              SELECT f.id
              FROM media_file f
              JOIN library_source s ON s.id = f.source_id
              WHERE s.uid = ? AND f.relative_path = ? AND f.deleted_at_ms IS NULL
              """,
            arguments: [sourceUID, mediaRelativePath]
          )
        else { return nil }
        let mediaFileID: Int64 = file["id"]
        guard
          let parseRow = try Row.fetchOne(
            database,
            sql: "SELECT * FROM parse_result WHERE media_file_id = ?",
            arguments: [mediaFileID]
          )
        else { return nil }
        let parse = try LibraryFilenameParseRecord(
          mediaKind: parseRow["media_kind"],
          cleanTitle: parseRow["clean_title"],
          sortTitle: parseRow["sort_title"],
          hintYear: parseRow["hint_year"],
          seasonNumber: parseRow["season_number"],
          episodeStart: parseRow["episode_start"],
          episodeEnd: parseRow["episode_end"],
          edition: parseRow["edition"],
          releaseGroup: parseRow["release_group"],
          languageHint: parseRow["language_hint"],
          providerHintsJSON: parseRow["provider_hints_json"],
          rawTokensJSON: parseRow["raw_tokens_json"],
          confidence: parseRow["confidence"],
          parserVersion: parseRow["parser_version"]
        )
        let sidecars = try Row.fetchAll(
          database,
          sql: "SELECT * FROM sidecar WHERE media_file_id = ? ORDER BY relative_path",
          arguments: [mediaFileID]
        ).map { row in
          try LibrarySidecarRecord(
            kind: row["kind"],
            relativePath: row["relative_path"],
            language: row["language"],
            isForced: (row["forced"] as Int) == 1,
            modifiedAtMilliseconds: row["modified_at_ms"],
            sha256: row["sha256"],
            parsedJSON: row["parsed_json"]
          )
        }
        let technical = try Self.readTechnicalProbe(mediaFileID: mediaFileID, database: database)
        return LibraryMetadataIntakeSnapshot(
          parseResult: parse,
          sidecars: sidecars,
          technicalProbe: technical
        )
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "metadata intake read failed")
    }
  }

  private static func readTechnicalProbe(
    mediaFileID: Int64,
    database: Database
  ) throws -> LibraryTechnicalProbeRecord? {
    guard
      let row = try Row.fetchOne(
        database,
        sql: "SELECT * FROM technical_summary WHERE media_file_id = ?",
        arguments: [mediaFileID]
      )
    else { return nil }
    let summary = LibraryTechnicalSummaryRecord(
      container: row["container"],
      durationMilliseconds: row["duration_ms"],
      overallBitrate: row["overall_bitrate"],
      videoCodec: row["video_codec"],
      width: row["width"],
      height: row["height"],
      frameRate: row["frame_rate"],
      hdrProfile: row["hdr_profile"],
      audioCodec: row["audio_codec"],
      audioChannels: row["audio_channels"],
      hasEmbeddedCover: (row["embedded_cover"] as Int) == 1
    )
    let streams = try Row.fetchAll(
      database,
      sql: "SELECT * FROM media_stream WHERE media_file_id = ? ORDER BY stream_index",
      arguments: [mediaFileID]
    ).map { stream in
      try LibraryTechnicalStreamRecord(
        streamIndex: stream["stream_index"],
        kind: stream["kind"],
        codec: stream["codec"],
        language: stream["language"],
        title: stream["title"],
        bitrate: stream["bit_rate"],
        width: stream["width"],
        height: stream["height"],
        frameRate: stream["frame_rate"],
        hdrProfile: stream["hdr_profile"],
        channelCount: stream["channel_count"],
        channelLayout: stream["channel_layout"],
        sampleRate: stream["sample_rate"],
        isDefault: (stream["is_default"] as Int) == 1,
        isForced: (stream["is_forced"] as Int) == 1
      )
    }
    return try LibraryTechnicalProbeRecord(
      summary: summary,
      streams: streams,
      probeProvider: row["probe_provider"],
      probeVersion: row["probe_version"]
    )
  }

  private static func replaceEnumerationState(
    _ state: LibraryScanEnumerationState,
    runID: Int64,
    now: Int64,
    database: Database
  ) throws {
    try database.execute(sql: "DELETE FROM scan_frontier WHERE run_id = ?", arguments: [runID])
    try database.execute(sql: "DELETE FROM scan_seen WHERE run_id = ?", arguments: [runID])
    for page in state.pendingPages {
      try insertFrontierPage(page, state: "pending", runID: runID, now: now, database: database)
    }
    for page in state.completedPages {
      try insertFrontierPage(page, state: "completed", runID: runID, now: now, database: database)
    }
    _ = try insertSeenIdentities(
      state.seenEntryIdentityKeys,
      directoryKeys: Set(state.seenDirectoryIdentityKeys),
      runID: runID,
      database: database
    )
  }

  private static func applyEnumerationTransition(
    _ transition: LibraryScanPageTransition,
    runID: Int64,
    now: Int64,
    database: Database
  ) throws -> AppliedEnumerationTransition {
    let completed = try encodedFrontierPage(transition.completedPage)
    try database.execute(
      sql: """
        UPDATE scan_frontier
        SET state = 'completed', updated_at_ms = ?
        WHERE run_id = ? AND directory_json = ? AND cursor_token = ? AND state = 'pending'
        """,
      arguments: [now, runID, completed.directoryJSON, completed.cursorToken]
    )
    guard database.changesCount == 1 else {
      throw SDKError(code: .storageFailure, message: "scan frontier transition is stale")
    }
    var insertedPageCount = 0
    for page in transition.enqueuedPages {
      try insertFrontierPage(
        page,
        state: "pending",
        runID: runID,
        now: now,
        database: database,
        ignoresConflict: true
      )
      insertedPageCount += database.changesCount
    }
    let insertedSeenCount = try insertSeenIdentities(
      transition.seenEntryIdentityKeys,
      directoryKeys: Set(transition.seenDirectoryIdentityKeys),
      runID: runID,
      database: database
    )
    return AppliedEnumerationTransition(
      insertedPageCount: insertedPageCount,
      insertedSeenCount: insertedSeenCount
    )
  }

  private static func insertFrontierPage(
    _ page: LibraryScanFrontierPage,
    state: String,
    runID: Int64,
    now: Int64,
    database: Database,
    ignoresConflict: Bool = false
  ) throws {
    let encoded = try encodedFrontierPage(page)
    try database.execute(
      sql: """
        INSERT \(ignoresConflict ? "OR IGNORE " : "")INTO scan_frontier(
          run_id, directory_json, cursor_token, state, updated_at_ms
        ) VALUES (?, ?, ?, ?, ?)
        """,
      arguments: [runID, encoded.directoryJSON, encoded.cursorToken, state, now]
    )
  }

  private static func encodedFrontierPage(
    _ page: LibraryScanFrontierPage
  ) throws -> (directoryJSON: String, cursorToken: String) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return (
      String(decoding: try encoder.encode(page.directory), as: UTF8.self),
      page.cursor ?? ""
    )
  }

  private static func insertSeenIdentities(
    _ identityKeys: [String],
    directoryKeys: Set<String>,
    runID: Int64,
    database: Database
  ) throws -> Int64 {
    let identityKeySet = Set(identityKeys)
    guard identityKeySet.count == identityKeys.count else {
      throw SDKError(code: .storageFailure, message: "scan seen transition is duplicated")
    }
    let statement = try database.makeStatement(
      sql: """
        INSERT OR IGNORE INTO scan_seen(run_id, identity_key, is_directory)
        VALUES (?, ?, ?)
        """
    )
    var insertedCount: Int64 = 0
    var directoryKeysToPromote = directoryKeys.subtracting(identityKeySet)
    for identityKey in identityKeys {
      try statement.execute(arguments: [
        runID, identityKey, directoryKeys.contains(identityKey) ? 1 : 0,
      ])
      let inserted = database.changesCount
      insertedCount += Int64(inserted)
      if inserted == 0, directoryKeys.contains(identityKey) {
        directoryKeysToPromote.insert(identityKey)
      }
    }
    let markDirectory = try database.makeStatement(
      sql: "UPDATE scan_seen SET is_directory = 1 WHERE run_id = ? AND identity_key = ?"
    )
    for identityKey in directoryKeysToPromote {
      try markDirectory.execute(arguments: [runID, identityKey])
      guard database.changesCount == 1 else {
        throw SDKError(code: .storageFailure, message: "scan directory identity is missing")
      }
    }
    return insertedCount
  }

  private static func validateEnumerationSnapshot(
    _ state: LibraryScanEnumerationState,
    pendingPageCount: Int?,
    processedPageCount: Int64?,
    discoveredEntryCount: Int64
  ) throws {
    guard pendingPageCount == state.pendingPages.count,
      processedPageCount == Int64(state.completedPages.count),
      discoveredEntryCount == Int64(state.seenEntryIdentityKeys.count)
    else {
      throw SDKError(code: .storageFailure, message: "scan frontier counters are inconsistent")
    }
  }

  private static func validateEnumerationTransitions(
    previous: StoredCheckpointProgress,
    previousDiscoveredCount: Int64,
    completedPageCount: Int,
    insertedPageCount: Int,
    insertedSeenCount: Int64,
    pendingPageCount: Int?,
    processedPageCount: Int64?,
    discoveredEntryCount: Int64
  ) throws {
    guard
      pendingPageCount == previous.pendingPageCount - completedPageCount + insertedPageCount,
      processedPageCount == previous.processedPageCount + Int64(completedPageCount),
      discoveredEntryCount == previousDiscoveredCount + insertedSeenCount
    else {
      throw SDKError(code: .storageFailure, message: "scan frontier counters are inconsistent")
    }
  }

  private static func decodeStoredCheckpointProgress(
    _ checkpointJSON: String
  ) throws -> StoredCheckpointProgress {
    do {
      return try JSONDecoder().decode(
        StoredCheckpointProgress.self,
        from: Data(checkpointJSON.utf8)
      )
    } catch {
      throw SDKError(code: .storageFailure, message: "stored scan progress is invalid")
    }
  }

  private struct AppliedEnumerationTransition {
    let insertedPageCount: Int
    let insertedSeenCount: Int64
  }

  private struct StoredCheckpointProgress: Decodable {
    let pendingPageCount: Int
    let processedPageCount: Int64

    private enum CodingKeys: String, CodingKey {
      case pendingPageCount = "pending_page_count"
      case processedPageCount = "processed_page_count"
    }
  }

  private static func requireNoOtherActiveRun(
    sourceID: Int64,
    excludingRunID: Int64?,
    requestedState: String,
    database: Database
  ) throws {
    let activeStates = ["queued", "enumerating", "processing", "finalizing"]
    guard activeStates.contains(requestedState) || requestedState == "completed" else { return }
    let conflictingRunID = try Int64.fetchOne(
      database,
      sql: """
        SELECT id
        FROM scan_run
        WHERE source_id = ?
          AND state IN ('queued', 'enumerating', 'processing', 'finalizing')
          AND (? IS NULL OR id <> ?)
        LIMIT 1
        """,
      arguments: [sourceID, excludingRunID, excludingRunID]
    )
    guard conflictingRunID == nil else {
      throw SDKError(code: .conflict, message: "library source already has an active scan run")
    }
  }

  private static func requireRunIsNotSuperseded(
    sourceID: Int64,
    runID: Int64,
    requestedState: String,
    database: Database
  ) throws {
    let publishingStates = ["queued", "enumerating", "processing", "finalizing", "completed"]
    guard publishingStates.contains(requestedState) else { return }
    let hasNewerRun =
      try Bool.fetchOne(
        database,
        sql: "SELECT EXISTS(SELECT 1 FROM scan_run WHERE source_id = ? AND id > ?)",
        arguments: [sourceID, runID]
      ) ?? false
    guard !hasNewerRun else {
      throw SDKError(code: .conflict, message: "scan run has been superseded by a newer run")
    }
  }

  private static func stage(
    entries: [RemoteEntry],
    runID: Int64,
    capabilities: MediaSourceCapabilities,
    database: Database
  ) throws {
    let files = entries.compactMap { entry in
      entry.kind == .file
        ? PreparedScanFile(
          entry: entry,
          capabilities: capabilities
        ) : nil
    }
    guard !files.isEmpty else { return }
    // Keep the staging row lightweight. A durable UID is generated only after publish confirms
    // that no media_file already owns this stable key.
    let insert = try database.makeStatement(
      sql: """
        INSERT INTO scan_discovery(
          run_id, stable_key, generated_uid, stable_id, parent_stable_key,
          relative_path, path_compare_key, display_name, extension, size_bytes,
          modified_at_ms, etag
        ) VALUES (?, ?, '', ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(run_id, stable_key) DO UPDATE SET
          stable_id = excluded.stable_id,
          parent_stable_key = excluded.parent_stable_key,
          relative_path = excluded.relative_path,
          path_compare_key = excluded.path_compare_key,
          display_name = excluded.display_name,
          extension = excluded.extension,
          size_bytes = excluded.size_bytes,
          modified_at_ms = excluded.modified_at_ms,
          etag = excluded.etag
        """
    )
    for file in files {
      try insert.execute(
        arguments: [
          runID, file.stableKey, file.stableID, file.parentStableKey,
          file.relativePath, file.pathCompareKey, file.displayName, file.fileExtension,
          file.sizeBytes, file.modifiedAtMilliseconds, file.entityTag,
        ]
      )
    }
  }

  private static func publishStagedFiles(
    sourceID: Int64,
    runID: Int64,
    now: Int64,
    database: Database
  ) throws -> Int {
    try database.execute(
      sql: """
        CREATE TEMP TABLE IF NOT EXISTS stellar_scan_publish_file (
          stable_key TEXT PRIMARY KEY,
          media_file_id INTEGER,
          material_changed INTEGER NOT NULL
        ) WITHOUT ROWID
        """
    )
    try database.execute(sql: "DELETE FROM stellar_scan_publish_file")
    try database.execute(
      sql: """
        INSERT INTO stellar_scan_publish_file(stable_key, media_file_id, material_changed)
        SELECT discovery.stable_key, file.id, CASE WHEN
            file.id IS NULL
            OR file.relative_path IS NOT discovery.relative_path
            OR file.path_compare_key IS NOT discovery.path_compare_key
            OR file.size_bytes IS NOT discovery.size_bytes
            OR file.modified_at_ms IS NOT discovery.modified_at_ms
            OR file.etag IS NOT discovery.etag
            OR file.availability <> 'present'
          THEN 1 ELSE 0 END
        FROM scan_discovery AS discovery
        LEFT JOIN media_file AS file
          ON file.source_id = ? AND file.stable_key = discovery.stable_key
        WHERE discovery.run_id = ?
        """,
      arguments: [sourceID, runID]
    )
    let changedCount =
      try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM stellar_scan_publish_file WHERE material_changed = 1"
      ) ?? 0
    if changedCount > 0 {
      try database.execute(
        sql: """
          UPDATE media_file AS file SET
            stable_id = discovery.stable_id,
            parent_stable_key = discovery.parent_stable_key,
            relative_path = discovery.relative_path,
            path_compare_key = discovery.path_compare_key,
            display_name = discovery.display_name,
            extension = discovery.extension,
            size_bytes = discovery.size_bytes,
            modified_at_ms = discovery.modified_at_ms,
            etag = discovery.etag,
            availability = 'present',
            last_seen_run_id = ?,
            missing_since_ms = NULL,
            missing_scan_count = 0,
            deleted_at_ms = NULL,
            material_revision = material_revision + 1,
            updated_at_ms = ?
          FROM scan_discovery AS discovery
          JOIN stellar_scan_publish_file AS publish
            ON publish.stable_key = discovery.stable_key
          WHERE discovery.run_id = ?
            AND file.id = publish.media_file_id
            AND publish.material_changed = 1
          """,
        arguments: [runID, now, runID]
      )
    }
    try database.execute(
      sql: """
        UPDATE media_file AS file SET
          stable_id = discovery.stable_id,
          parent_stable_key = discovery.parent_stable_key,
          last_seen_run_id = ?,
          missing_since_ms = NULL,
          missing_scan_count = 0,
          deleted_at_ms = NULL
        FROM scan_discovery AS discovery
        JOIN stellar_scan_publish_file AS publish
          ON publish.stable_key = discovery.stable_key
        WHERE discovery.run_id = ?
          AND file.id = publish.media_file_id
          AND publish.material_changed = 0
          AND (file.last_seen_run_id IS NULL OR file.last_seen_run_id <> ?
               OR file.stable_id IS NOT discovery.stable_id)
        """,
      arguments: [runID, runID, runID]
    )
    if changedCount > 0 {
      try database.execute(
        sql: """
          -- Materializing the random bytes once keeps every UUID segment from evaluating a
          -- different randomblob expression while preserving a set-based insert.
          WITH new_file AS MATERIALIZED (
            SELECT discovery.*, lower(hex(randomblob(16))) AS uid_hex
            FROM scan_discovery AS discovery
            JOIN stellar_scan_publish_file AS publish
              ON publish.stable_key = discovery.stable_key
            WHERE discovery.run_id = ? AND publish.media_file_id IS NULL
          )
          INSERT INTO media_file(
            uid, source_id, stable_key, stable_id, parent_stable_key, relative_path,
            path_compare_key, display_name, extension, size_bytes, modified_at_ms, etag,
            availability, last_seen_run_id, updated_at_ms
          )
          SELECT substr(uid_hex, 1, 8) || '-' || substr(uid_hex, 9, 4) || '-4'
                   || substr(uid_hex, 14, 3) || '-8' || substr(uid_hex, 18, 3) || '-'
                   || substr(uid_hex, 21, 12),
                 ?, stable_key, stable_id, parent_stable_key, relative_path,
                 path_compare_key, display_name, extension, size_bytes, modified_at_ms, etag,
                 'present', ?, ?
          FROM new_file
          """,
        arguments: [runID, sourceID, runID, now]
      )
    }
    if changedCount > 0 {
      try database.execute(
        sql: """
          UPDATE scan_queue AS queue
          SET state = 'done', next_attempt_at_ms = NULL, lease_until_ms = NULL,
              claimed_by = NULL, claim_token = NULL, heartbeat_at_ms = NULL,
              error_code = 'conflict', error_message = 'Superseded by a newer file revision.',
              updated_at_ms = ?
          WHERE queue.state IN ('queued', 'running', 'retry', 'failed')
            AND EXISTS(
              SELECT 1
              FROM stellar_scan_publish_file AS publish
              JOIN media_file AS file
                ON file.source_id = ? AND file.stable_key = publish.stable_key
              WHERE publish.material_changed = 1
                AND queue.media_file_id = file.id
                AND queue.input_revision <> file.material_revision
            )
          """,
        arguments: [now, sourceID]
      )
      try database.execute(
        sql: """
          INSERT INTO scan_queue(
            run_id, media_file_id, stage, state, input_revision, updated_at_ms
          )
          SELECT ?, file.id, 'parse', 'queued', file.material_revision, ?
          FROM stellar_scan_publish_file AS publish
          JOIN media_file AS file ON file.source_id = ? AND file.stable_key = publish.stable_key
          WHERE publish.material_changed = 1
          ON CONFLICT(run_id, media_file_id, stage) DO NOTHING
          """,
        arguments: [runID, now, sourceID]
      )
    }
    return changedCount
  }

  private struct PreparedScanFile {
    let stableKey: String
    let stableID: String?
    let parentStableKey: String?
    let relativePath: String
    let pathCompareKey: String
    let displayName: String
    let fileExtension: String?
    let sizeBytes: Int64?
    let modifiedAtMilliseconds: Int64?
    let entityTag: String?

    init(
      entry: RemoteEntry,
      capabilities: MediaSourceCapabilities
    ) {
      pathCompareKey = entry.locator.pathComparisonKey(using: capabilities.pathSemantics)
      if capabilities.stableIDScope == .persistent, let stableID = entry.stableID {
        stableKey = "persistent:\(stableID)"
      } else {
        stableKey = "path:\(pathCompareKey)"
      }
      if let separator = pathCompareKey.lastIndex(of: "/") {
        parentStableKey = "path:\(pathCompareKey[..<separator])"
      } else {
        parentStableKey = "path:"
      }
      relativePath = entry.locator.path.relativePath
      displayName = entry.locator.path.name
      if let separator = displayName.utf8.lastIndex(of: 46), separator != displayName.startIndex {
        let extensionStart = displayName.index(after: separator)
        fileExtension =
          extensionStart == displayName.endIndex
          ? nil : displayName[extensionStart...].lowercased()
      } else {
        fileExtension = nil
      }
      stableID = entry.stableID
      sizeBytes = entry.size
      modifiedAtMilliseconds = entry.modifiedAtMilliseconds
      entityTag = entry.entityTag
    }
  }

  private static func requireActiveScanWorkLease(
    _ lease: LibraryScanWorkLease,
    expectedMediaFileID: Int64? = nil,
    now: Int64,
    database: Database
  ) throws {
    let isCurrent =
      try Bool.fetchOne(
        database,
        sql: """
          SELECT EXISTS(
            SELECT 1
            FROM scan_queue q
            JOIN media_file f ON f.id = q.media_file_id
            JOIN library_source s ON s.id = f.source_id
            WHERE q.id = ? AND q.stage = ? AND q.state = 'running'
              AND q.claimed_by = ? AND q.claim_token = ? AND q.input_revision = ?
              AND q.lease_until_ms IS NOT NULL AND q.lease_until_ms > ?
              AND q.input_revision = f.material_revision
              AND s.uid = ? AND f.stable_key = ? AND f.relative_path = ?
              AND f.availability = 'present' AND f.deleted_at_ms IS NULL
              AND (? IS NULL OR f.id = ?)
          )
          """,
        arguments: [
          lease.queueID, lease.stage.rawValue, lease.workerID, lease.claimToken,
          lease.inputRevision, now, lease.file.sourceUID, lease.file.stableKey,
          lease.file.relativePath, expectedMediaFileID, expectedMediaFileID,
        ]
      ) ?? false
    guard isCurrent else {
      throw SDKError(code: .conflict, message: "scan work lease is expired or stale")
    }
  }

  private static func encodeScanFileWorkCursor(
    _ cursor: LibraryScanFileWorkCursor
  ) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(cursor).base64EncodedString()
  }

  private static func decodeScanFileWorkCursor(
    _ encoded: String
  ) throws -> LibraryScanFileWorkCursor {
    guard !encoded.isEmpty, !encoded.contains("\0"),
      let data = Data(base64Encoded: encoded),
      let cursor = try? JSONDecoder().decode(LibraryScanFileWorkCursor.self, from: data)
    else {
      throw SDKError(code: .conflict, message: "scan file work cursor is invalid")
    }
    return cursor
  }

  private static func reconcileMissing(
    sourceID: Int64,
    runID: Int64,
    roots: [RemoteLocator],
    semantics: RemotePathSemantics,
    now: Int64,
    database: Database
  ) throws {
    let rootKeys = roots.map { $0.pathComparisonKey(using: semantics) }
    guard !rootKeys.isEmpty else { return }

    try database.execute(
      sql: """
        CREATE TEMP TABLE IF NOT EXISTS stellar_scan_covered_root (
          path_compare_key TEXT PRIMARY KEY
        ) WITHOUT ROWID
        """
    )
    try database.execute(sql: "DELETE FROM stellar_scan_covered_root")
    let insertRoot = try database.makeStatement(
      sql: "INSERT OR IGNORE INTO stellar_scan_covered_root(path_compare_key) VALUES (?)"
    )
    for rootKey in rootKeys {
      try insertRoot.execute(arguments: [rootKey])
    }

    try database.execute(
      sql: """
        UPDATE media_file AS file SET
          availability = 'missing',
          missing_since_ms = COALESCE(missing_since_ms, ?),
          missing_scan_count = missing_scan_count + 1,
          updated_at_ms = ?
        WHERE file.source_id = ?
          AND (file.last_seen_run_id IS NULL OR file.last_seen_run_id <> ?)
          AND file.availability NOT IN ('excluded', 'deleted')
          AND EXISTS (
            SELECT 1 FROM stellar_scan_covered_root AS root
            WHERE root.path_compare_key = ''
               OR file.path_compare_key = root.path_compare_key
               OR substr(file.path_compare_key, 1, length(root.path_compare_key) + 1)
                    = root.path_compare_key || '/'
          )
        """,
      arguments: [now, now, sourceID, runID]
    )
  }
}

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
      pageTransition.map({ transition in
        ([transition.completedPage] + transition.enqueuedPages).allSatisfy {
          $0.directory.sourceUID == sourceUID
        }
      }) ?? true,
      enumerationState == nil || pageTransition == nil,
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
    self.pageTransition = pageTransition
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
    let generatedUIDs = batch.entries.map { _ in uuidGenerator.makeUUID().uuidString.lowercased() }
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
          sql: "SELECT id, source_id, mode, state, checkpoint_json FROM scan_run WHERE uid = ?",
          arguments: [batch.runUID]
        )
        let runID: Int64
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
        } else {
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
        }

        let hasEnumerationMutation = batch.enumerationState != nil || batch.pageTransition != nil
        if let state = batch.enumerationState {
          try Self.replaceEnumerationState(
            state,
            runID: runID,
            now: now,
            database: database
          )
        }
        if let transition = batch.pageTransition {
          try Self.applyEnumerationTransition(
            transition,
            runID: runID,
            now: now,
            database: database
          )
        }
        if hasEnumerationMutation {
          guard let pendingPageCount = batch.pendingPageCount,
            let processedPageCount = batch.processedPageCount
          else {
            throw SDKError(code: .storageFailure, message: "scan frontier counters are missing")
          }
          try Self.validateEnumerationCounts(
            runID: runID,
            pendingCount: pendingPageCount,
            processedCount: processedPageCount,
            discoveredCount: batch.discoveredEntryCount,
            database: database
          )
        }

        var changedCount = 0
        if let capabilities = batch.capabilities {
          changedCount = try Self.upsert(
            entries: batch.entries,
            generatedUIDs: generatedUIDs,
            sourceID: sourceID,
            runID: runID,
            capabilities: capabilities,
            now: now,
            database: database
          )
        } else if batch.entries.contains(where: { $0.kind == .file }) {
          throw SDKError(code: .storageFailure, message: "file batch has no source capabilities")
        }

        if batch.reconcileMissingEligible {
          guard let capabilities = batch.capabilities else {
            throw SDKError(code: .storageFailure, message: "completion has no source capabilities")
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
            GROUP BY f.id, f.relative_path, f.path_compare_key
            ORDER BY f.path_compare_key, f.id
            """,
          arguments: [sourceUID, stage.rawValue]
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
            stage.rawValue, sourceUID,
            decodedCursor.pathCompareKey, decodedCursor.pathCompareKey, decodedCursor.fileID,
            pageSize + 1,
          ]
        } else {
          cursorPredicate = ""
          arguments = [stage.rawValue, sourceUID, pageSize + 1]
        }
        let rows = try Row.fetchAll(
          database,
          sql: """
            WITH pending AS (
              SELECT q.media_file_id, MAX(q.attempts) AS attempts
              FROM scan_queue q
              WHERE q.stage = ? AND q.state IN ('queued', 'retry', 'failed')
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
                error_code = NULL, error_message = NULL, updated_at_ms = ?
            WHERE stage = ?
              AND state IN ('queued', 'running', 'retry', 'failed')
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

  /// Materializes provider metadata and completes the corresponding work item atomically.
  @discardableResult
  public func commitRemoteMetadata(
    _ metadata: LibraryRemoteMetadata,
    sourceUID: String,
    relativePath: String,
    completing stage: LibraryScanQueueStage
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

        try database.execute(
          sql: """
            UPDATE scan_queue
            SET state = 'done', next_attempt_at_ms = NULL, lease_until_ms = NULL,
                error_code = NULL, error_message = NULL, updated_at_ms = ?
            WHERE stage = ? AND media_file_id = ?
              AND state IN ('queued', 'running', 'retry', 'failed')
            """,
          arguments: [now, stage.rawValue, mediaFileID]
        )
        return entityUID
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "remote metadata commit failed")
    }
  }

  /// Keeps one file-stage task durable so a later manual or repair scan can retry it.
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
              SELECT f.id AS media_file_id, r.id AS run_id
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
        let runID: Int64 = row["run_id"]
        try database.execute(
          sql: """
            INSERT INTO scan_queue(
              run_id, media_file_id, stage, state, attempts,
              next_attempt_at_ms, lease_until_ms, error_code, error_message, updated_at_ms
            ) VALUES (?, ?, ?, 'retry', 1, NULL, NULL, ?, NULL, ?)
            ON CONFLICT(run_id, media_file_id, stage) DO UPDATE SET
              state = 'retry',
              attempts = scan_queue.attempts + 1,
              next_attempt_at_ms = NULL,
              lease_until_ms = NULL,
              error_code = excluded.error_code,
              error_message = NULL,
              updated_at_ms = excluded.updated_at_ms
            """,
          arguments: [runID, mediaFileID, stage.rawValue, errorCode.rawValue, now]
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
    try insertSeenIdentities(
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
  ) throws {
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
    for page in transition.enqueuedPages {
      try insertFrontierPage(
        page,
        state: "pending",
        runID: runID,
        now: now,
        database: database,
        ignoresConflict: true
      )
    }
    try insertSeenIdentities(
      transition.seenEntryIdentityKeys,
      directoryKeys: Set(transition.seenDirectoryIdentityKeys),
      runID: runID,
      database: database
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
  ) throws {
    let statement = try database.makeStatement(
      sql: """
        INSERT INTO scan_seen(run_id, identity_key, is_directory)
        VALUES (?, ?, ?)
        ON CONFLICT(run_id, identity_key) DO UPDATE SET
          is_directory = MAX(scan_seen.is_directory, excluded.is_directory)
        """
    )
    for identityKey in identityKeys {
      try statement.execute(arguments: [
        runID, identityKey, directoryKeys.contains(identityKey) ? 1 : 0,
      ])
    }
    for identityKey in directoryKeys where !identityKeys.contains(identityKey) {
      try statement.execute(arguments: [runID, identityKey, 1])
    }
  }

  private static func validateEnumerationCounts(
    runID: Int64,
    pendingCount: Int,
    processedCount: Int64,
    discoveredCount: Int64,
    database: Database
  ) throws {
    let storedPending =
      try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM scan_frontier WHERE run_id = ? AND state = 'pending'",
        arguments: [runID]
      ) ?? 0
    let storedCompleted =
      try Int64.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM scan_frontier WHERE run_id = ? AND state = 'completed'",
        arguments: [runID]
      ) ?? 0
    let storedSeen =
      try Int64.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM scan_seen WHERE run_id = ?",
        arguments: [runID]
      ) ?? 0
    guard storedPending == pendingCount,
      storedCompleted == processedCount,
      storedSeen == discoveredCount
    else {
      throw SDKError(code: .storageFailure, message: "scan frontier counters are inconsistent")
    }
  }

  private static func upsert(
    entries: [RemoteEntry],
    generatedUIDs: [String],
    sourceID: Int64,
    runID: Int64,
    capabilities: MediaSourceCapabilities,
    now: Int64,
    database: Database
  ) throws -> Int {
    let files = zip(entries, generatedUIDs).compactMap { entry, generatedUID in
      entry.kind == .file
        ? PreparedScanFile(
          entry: entry,
          generatedUID: generatedUID,
          capabilities: capabilities
        ) : nil
    }
    guard !files.isEmpty else { return 0 }
    if files.count == 1, let file = files.first {
      return try upsertSingle(
        file,
        sourceID: sourceID,
        runID: runID,
        now: now,
        database: database
      )
    }

    try database.execute(
      sql: """
        CREATE TEMP TABLE IF NOT EXISTS stellar_scan_batch_file (
          stable_key TEXT PRIMARY KEY,
          generated_uid TEXT NOT NULL,
          stable_id TEXT,
          parent_stable_key TEXT,
          relative_path TEXT NOT NULL,
          path_compare_key TEXT NOT NULL,
          display_name TEXT NOT NULL,
          extension TEXT,
          size_bytes INTEGER,
          modified_at_ms INTEGER,
          etag TEXT,
          existing_id INTEGER,
          material_changed INTEGER NOT NULL DEFAULT 1
        ) WITHOUT ROWID
        """
    )
    try database.execute(sql: "DELETE FROM stellar_scan_batch_file")
    let insert = try database.makeStatement(
      sql: """
        INSERT OR REPLACE INTO stellar_scan_batch_file(
          stable_key, generated_uid, stable_id, parent_stable_key, relative_path,
          path_compare_key, display_name, extension, size_bytes, modified_at_ms, etag
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
    )
    for file in files {
      try insert.execute(
        arguments: [
          file.stableKey, file.generatedUID, file.stableID, file.parentStableKey,
          file.relativePath, file.pathCompareKey, file.displayName, file.fileExtension,
          file.sizeBytes, file.modifiedAtMilliseconds, file.entityTag,
        ]
      )
    }

    try database.execute(
      sql: """
        UPDATE stellar_scan_batch_file AS batch SET
          existing_id = file.id,
          material_changed = CASE WHEN
            file.relative_path IS NOT batch.relative_path
            OR file.path_compare_key IS NOT batch.path_compare_key
            OR file.size_bytes IS NOT batch.size_bytes
            OR file.modified_at_ms IS NOT batch.modified_at_ms
            OR file.etag IS NOT batch.etag
            OR file.availability <> 'present'
          THEN 1 ELSE 0 END
        FROM media_file AS file
        WHERE file.source_id = ? AND file.stable_key = batch.stable_key
        """,
      arguments: [sourceID]
    )
    try database.execute(
      sql: """
        UPDATE media_file AS file SET
          stable_id = batch.stable_id,
          parent_stable_key = batch.parent_stable_key,
          relative_path = batch.relative_path,
          path_compare_key = batch.path_compare_key,
          display_name = batch.display_name,
          extension = batch.extension,
          size_bytes = batch.size_bytes,
          modified_at_ms = batch.modified_at_ms,
          etag = batch.etag,
          availability = 'present',
          last_seen_run_id = ?,
          missing_since_ms = NULL,
          missing_scan_count = 0,
          deleted_at_ms = NULL,
          updated_at_ms = ?
        FROM stellar_scan_batch_file AS batch
        WHERE file.id = batch.existing_id AND batch.material_changed = 1
        """,
      arguments: [runID, now]
    )
    try database.execute(
      sql: """
        UPDATE media_file AS file SET
          stable_id = batch.stable_id,
          parent_stable_key = batch.parent_stable_key,
          last_seen_run_id = ?,
          missing_since_ms = NULL,
          missing_scan_count = 0,
          deleted_at_ms = NULL
        FROM stellar_scan_batch_file AS batch
        WHERE file.id = batch.existing_id AND batch.material_changed = 0
          AND (file.last_seen_run_id IS NULL OR file.last_seen_run_id <> ?
               OR file.stable_id IS NOT batch.stable_id)
        """,
      arguments: [runID, runID]
    )
    try database.execute(
      sql: """
        INSERT INTO media_file(
          uid, source_id, stable_key, stable_id, parent_stable_key, relative_path,
          path_compare_key, display_name, extension, size_bytes, modified_at_ms, etag,
          availability, last_seen_run_id, updated_at_ms
        )
        SELECT generated_uid, ?, stable_key, stable_id, parent_stable_key, relative_path,
               path_compare_key, display_name, extension, size_bytes, modified_at_ms, etag,
               'present', ?, ?
        FROM stellar_scan_batch_file
        WHERE existing_id IS NULL
        """,
      arguments: [sourceID, runID, now]
    )
    try database.execute(
      sql: """
        INSERT INTO scan_queue(run_id, media_file_id, stage, state, updated_at_ms)
        SELECT ?, file.id, 'parse', 'queued', ?
        FROM stellar_scan_batch_file AS batch
        JOIN media_file AS file ON file.source_id = ? AND file.stable_key = batch.stable_key
        WHERE batch.material_changed = 1
        ON CONFLICT(run_id, media_file_id, stage) DO NOTHING
        """,
      arguments: [runID, now, sourceID]
    )
    return try Int.fetchOne(
      database,
      sql: "SELECT COUNT(*) FROM stellar_scan_batch_file WHERE material_changed = 1"
    ) ?? 0
  }

  private static func upsertSingle(
    _ file: PreparedScanFile,
    sourceID: Int64,
    runID: Int64,
    now: Int64,
    database: Database
  ) throws -> Int {
    let existing = try Row.fetchOne(
      database,
      sql: """
        SELECT id, relative_path, path_compare_key, size_bytes, modified_at_ms, etag,
               availability
        FROM media_file
        WHERE source_id = ? AND stable_key = ?
        """,
      arguments: [sourceID, file.stableKey]
    )
    let mediaFileID: Int64
    let changed: Bool
    if let existing {
      mediaFileID = existing["id"]
      changed =
        (existing["relative_path"] as String) != file.relativePath
        || (existing["path_compare_key"] as String) != file.pathCompareKey
        || (existing["size_bytes"] as Int64?) != file.sizeBytes
        || (existing["modified_at_ms"] as Int64?) != file.modifiedAtMilliseconds
        || (existing["etag"] as String?) != file.entityTag
        || (existing["availability"] as String) != "present"
      if changed {
        try database.execute(
          sql: """
            UPDATE media_file SET
              stable_id = ?, parent_stable_key = ?, relative_path = ?, path_compare_key = ?,
              display_name = ?, extension = ?, size_bytes = ?, modified_at_ms = ?, etag = ?,
              availability = 'present', last_seen_run_id = ?, missing_since_ms = NULL,
              missing_scan_count = 0, deleted_at_ms = NULL, updated_at_ms = ?
            WHERE id = ?
            """,
          arguments: [
            file.stableID, file.parentStableKey, file.relativePath, file.pathCompareKey,
            file.displayName, file.fileExtension, file.sizeBytes, file.modifiedAtMilliseconds,
            file.entityTag, runID, now, mediaFileID,
          ]
        )
      } else {
        try database.execute(
          sql: """
            UPDATE media_file SET
              stable_id = ?, parent_stable_key = ?, last_seen_run_id = ?,
              missing_since_ms = NULL, missing_scan_count = 0, deleted_at_ms = NULL
            WHERE id = ? AND (last_seen_run_id IS NULL OR last_seen_run_id <> ?
                              OR stable_id IS NOT ?)
            """,
          arguments: [
            file.stableID, file.parentStableKey, runID, mediaFileID, runID, file.stableID,
          ]
        )
      }
    } else {
      changed = true
      try database.execute(
        sql: """
          INSERT INTO media_file(
            uid, source_id, stable_key, stable_id, parent_stable_key, relative_path,
            path_compare_key, display_name, extension, size_bytes, modified_at_ms, etag,
            availability, last_seen_run_id, updated_at_ms
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'present', ?, ?)
          """,
        arguments: [
          file.generatedUID, sourceID, file.stableKey, file.stableID, file.parentStableKey,
          file.relativePath, file.pathCompareKey, file.displayName, file.fileExtension,
          file.sizeBytes, file.modifiedAtMilliseconds, file.entityTag, runID, now,
        ]
      )
      mediaFileID = database.lastInsertedRowID
    }

    if changed {
      try database.execute(
        sql: """
          INSERT INTO scan_queue(run_id, media_file_id, stage, state, updated_at_ms)
          VALUES (?, ?, 'parse', 'queued', ?)
          ON CONFLICT(run_id, media_file_id, stage) DO NOTHING
          """,
        arguments: [runID, mediaFileID, now]
      )
    }
    return changed ? 1 : 0
  }

  private struct PreparedScanFile {
    let stableKey: String
    let generatedUID: String
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
      generatedUID: String,
      capabilities: MediaSourceCapabilities
    ) {
      pathCompareKey = entry.locator.pathComparisonKey(using: capabilities.pathSemantics)
      if capabilities.stableIDScope == .persistent, let stableID = entry.stableID {
        stableKey = "persistent:\(stableID)"
      } else {
        stableKey = "path:\(pathCompareKey)"
      }
      parentStableKey = entry.locator.path.parent.map {
        "path:\($0.comparisonKey(using: capabilities.pathSemantics))"
      }
      relativePath = entry.locator.path.relativePath
      displayName = entry.locator.path.name
      let pathExtension = (displayName as NSString).pathExtension
      fileExtension = pathExtension.isEmpty ? nil : pathExtension.lowercased()
      self.generatedUID = generatedUID
      stableID = entry.stableID
      sizeBytes = entry.size
      modifiedAtMilliseconds = entry.modifiedAtMilliseconds
      entityTag = entry.entityTag
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

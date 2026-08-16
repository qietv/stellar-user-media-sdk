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
  public let errorCode: String?

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
    let modes = ["full", "incremental", "repair"]
    let states = ["queued", "enumerating", "finalizing", "completed", "failed", "cancelled"]
    guard !runUID.isEmpty, !sourceUID.isEmpty, modes.contains(mode), states.contains(state),
      !checkpointJSON.isEmpty, !coverageJSON.isEmpty, discoveredEntryCount >= 0,
      entries.allSatisfy({ $0.locator.sourceUID == sourceUID }),
      coveredRoots.allSatisfy({ $0.sourceUID == sourceUID }),
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
    self.errorCode = errorCode
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

        var changedCount = 0
        if let capabilities = batch.capabilities {
          for (entry, generatedUID) in zip(batch.entries, generatedUIDs)
          where entry.kind == .file {
            if try Self.upsert(
              entry: entry,
              generatedUID: generatedUID,
              sourceID: sourceID,
              runID: runID,
              capabilities: capabilities,
              now: now,
              database: database
            ) {
              changedCount += 1
            }
          }
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

  private static func upsert(
    entry: RemoteEntry,
    generatedUID: String,
    sourceID: Int64,
    runID: Int64,
    capabilities: MediaSourceCapabilities,
    now: Int64,
    database: Database
  ) throws -> Bool {
    let pathCompareKey = entry.locator.pathComparisonKey(using: capabilities.pathSemantics)
    let stableKey: String
    if capabilities.stableIDScope == .persistent, let stableID = entry.stableID {
      stableKey = "persistent:\(stableID)"
    } else {
      stableKey = "path:\(pathCompareKey)"
    }
    let parentKey = entry.locator.path.parent.map {
      "path:\($0.comparisonKey(using: capabilities.pathSemantics))"
    }
    let path = entry.locator.path.relativePath
    let name = entry.locator.path.name
    let fileExtension = (name as NSString).pathExtension
    let existing = try Row.fetchOne(
      database,
      sql: """
        SELECT id, relative_path, path_compare_key, size_bytes, modified_at_ms, etag,
               availability, last_seen_run_id
        FROM media_file
        WHERE source_id = ? AND stable_key = ?
        """,
      arguments: [sourceID, stableKey]
    )
    let mediaFileID: Int64
    let changed: Bool
    if let existing {
      mediaFileID = existing["id"]
      let oldPath: String = existing["relative_path"]
      let oldCompareKey: String = existing["path_compare_key"]
      let oldSize: Int64? = existing["size_bytes"]
      let oldModifiedAt: Int64? = existing["modified_at_ms"]
      let oldEntityTag: String? = existing["etag"]
      let oldAvailability: String = existing["availability"]
      changed =
        oldPath != path || oldCompareKey != pathCompareKey || oldSize != entry.size
        || oldModifiedAt != entry.modifiedAtMilliseconds || oldEntityTag != entry.entityTag
        || oldAvailability != "present"
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
          entry.stableID, parentKey, path, pathCompareKey, name,
          fileExtension.isEmpty ? nil : fileExtension.lowercased(), entry.size,
          entry.modifiedAtMilliseconds, entry.entityTag, runID, now, mediaFileID,
        ]
      )
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
          generatedUID, sourceID, stableKey, entry.stableID, parentKey, path, pathCompareKey,
          name, fileExtension.isEmpty ? nil : fileExtension.lowercased(), entry.size,
          entry.modifiedAtMilliseconds, entry.entityTag, runID, now,
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
    return changed
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
    let candidates = try Row.fetchAll(
      database,
      sql: """
        SELECT id, path_compare_key
        FROM media_file
        WHERE source_id = ? AND (last_seen_run_id IS NULL OR last_seen_run_id <> ?)
          AND availability NOT IN ('excluded', 'deleted')
        """,
      arguments: [sourceID, runID]
    )
    let missingIDs: [Int64] = candidates.compactMap { row in
      let path: String = row["path_compare_key"]
      let covered = rootKeys.contains { root in
        root.isEmpty || path == root || path.hasPrefix("\(root)/")
      }
      return covered ? row["id"] : nil
    }
    for id in missingIDs {
      try database.execute(
        sql: """
          UPDATE media_file SET
            availability = 'missing',
            missing_since_ms = COALESCE(missing_since_ms, ?),
            missing_scan_count = missing_scan_count + 1,
            updated_at_ms = ?
          WHERE id = ?
          """,
        arguments: [now, now, id]
      )
    }
  }
}

import Foundation
import GRDB
import StellarCore
import StellarRemoteMedia

package enum LibraryCompositeMediaProbeStatus: String, Sendable {
  case confirmed
  case unsupported
  case corruptStructure = "corrupt_structure"
  case encrypted
  case cancelled
  case remoteUnavailable = "remote_unavailable"
  case dependencyFailure = "dependency_failure"
}

/// Storage-only input for a source-independent composite-media probe.
package struct LibraryCompositeMediaProbeInput: Equatable, Sendable {
  public let file: LibraryFileFact
  public let inputRevision: Int64
  public let descriptorsJSON: String

  package init(file: LibraryFileFact, inputRevision: Int64, descriptorsJSON: String) throws {
    guard inputRevision > 0, !descriptorsJSON.isEmpty,
      let value = try? JSONSerialization.jsonObject(with: Data(descriptorsJSON.utf8)),
      value is [Any]
    else {
      throw SDKError(code: .storageFailure, message: "composite probe input is invalid")
    }
    self.file = file
    self.inputRevision = inputRevision
    self.descriptorsJSON = descriptorsJSON
  }
}

/// One exact-revision cached result. Successful result JSON is decoded by StellarDiscMedia.
package struct LibraryCompositeMediaProbeRecord: Equatable, Sendable {
  public let inputRevision: Int64
  public let inputSizeBytes: Int64?
  public let inputModifiedAtMilliseconds: Int64?
  public let inputEntityTag: String?
  public let selectionRuleVersion: Int
  public let status: LibraryCompositeMediaProbeStatus
  public let resultJSON: String?

  package init(
    inputRevision: Int64,
    inputSizeBytes: Int64?,
    inputModifiedAtMilliseconds: Int64?,
    inputEntityTag: String?,
    selectionRuleVersion: Int,
    status: LibraryCompositeMediaProbeStatus,
    resultJSON: String?
  ) throws {
    let validResult =
      resultJSON.flatMap { json -> Bool? in
        guard json.utf8.count <= 1_048_576,
          let value = try? JSONSerialization.jsonObject(with: Data(json.utf8))
        else { return false }
        return value is [String: Any]
      } ?? false
    guard inputRevision > 0, inputSizeBytes.map({ $0 >= 0 }) ?? true,
      inputEntityTag?.contains("\0") != true, selectionRuleVersion > 0,
      (status == .confirmed && validResult) || (status != .confirmed && resultJSON == nil)
    else {
      throw SDKError(code: .invalidConfiguration, message: "composite probe record is invalid")
    }
    self.inputRevision = inputRevision
    self.inputSizeBytes = inputSizeBytes
    self.inputModifiedAtMilliseconds = inputModifiedAtMilliseconds
    self.inputEntityTag = inputEntityTag
    self.selectionRuleVersion = selectionRuleVersion
    self.status = status
    self.resultJSON = resultJSON
  }
}

package enum LibraryCompositeMediaProbeDisposition: Sendable {
  case complete
  case retry(errorCode: SDKErrorCode, afterMilliseconds: Int64)
  case fail(errorCode: SDKErrorCode)
}

extension LibraryStore {
  /// Returns the compound descriptor attached to a current probe lease.
  package func compositeMediaProbeInput(
    for lease: LibraryScanWorkLease
  ) async throws -> LibraryCompositeMediaProbeInput? {
    guard lease.stage == .probe else {
      throw SDKError(code: .invalidConfiguration, message: "composite probe lease is invalid")
    }
    let now = clock.nowMilliseconds()
    do {
      return try await database.read { database in
        try Self.requireActiveScanWorkLease(lease, now: now, database: database)
        guard
          let row = try Row.fetchOne(
            database,
            sql: """
              SELECT f.composite_media_json
              FROM scan_queue q
              JOIN media_file f ON f.id = q.media_file_id
              WHERE q.id = ?
              """,
            arguments: [lease.queueID]
          ), let descriptorsJSON: String = row["composite_media_json"]
        else { return nil }
        return try LibraryCompositeMediaProbeInput(
          file: lease.file,
          inputRevision: lease.inputRevision,
          descriptorsJSON: descriptorsJSON
        )
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "composite probe input read failed")
    }
  }

  /// Reads a cached result only when every material input still matches the published file.
  package func cachedCompositeMediaProbe(
    sourceUID: String,
    relativePath: String,
    selectionRuleVersion: Int
  ) async throws -> LibraryCompositeMediaProbeRecord? {
    let path = try RemotePath(relativePath)
    guard !sourceUID.isEmpty, !sourceUID.contains("\0"), !path.isRoot,
      selectionRuleVersion > 0
    else {
      throw SDKError(code: .invalidConfiguration, message: "composite probe cache key is invalid")
    }
    do {
      return try await database.read { database in
        guard
          let row = try Row.fetchOne(
            database,
            sql: """
              SELECT f.material_revision, f.size_bytes, f.modified_at_ms, f.etag,
                     probe.selection_rule_version, probe.status, probe.result_json
              FROM media_file f
              JOIN library_source source ON source.id = f.source_id
              JOIN composite_media_probe probe ON probe.media_file_id = f.id
              WHERE source.uid = ? AND f.relative_path = ?
                AND source.deleted_at_ms IS NULL AND f.deleted_at_ms IS NULL
                AND f.availability = 'present' AND f.composite_media_json IS NOT NULL
                AND probe.input_revision = f.material_revision
                AND probe.input_size_bytes IS f.size_bytes
                AND probe.input_modified_at_ms IS f.modified_at_ms
                AND probe.input_etag IS f.etag
                AND probe.selection_rule_version = ?
              """,
            arguments: [sourceUID, path.relativePath, selectionRuleVersion]
          ), let status = LibraryCompositeMediaProbeStatus(rawValue: row["status"])
        else { return nil }
        return try LibraryCompositeMediaProbeRecord(
          inputRevision: row["material_revision"],
          inputSizeBytes: row["size_bytes"],
          inputModifiedAtMilliseconds: row["modified_at_ms"],
          inputEntityTag: row["etag"],
          selectionRuleVersion: row["selection_rule_version"],
          status: status,
          resultJSON: row["result_json"]
        )
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "composite probe cache read failed")
    }
  }

  /// Enqueues only compound media without a current successful or durable terminal result.
  @discardableResult
  package func enqueueMissingCompositeMediaProbeWork(
    sourceUID: String,
    selectionRuleVersion: Int,
    priority: Int,
    limit: Int,
    retryTerminalFailures: Bool
  ) async throws -> Int {
    guard !sourceUID.isEmpty, !sourceUID.contains("\0"), selectionRuleVersion > 0,
      (-1_000_000...1_000_000).contains(priority), (1...2_000).contains(limit)
    else {
      throw SDKError(code: .invalidConfiguration, message: "composite probe enqueue is invalid")
    }
    let now = clock.nowMilliseconds()
    do {
      return try await database.write { database in
        guard
          let runID = try Int64.fetchOne(
            database,
            sql: """
              SELECT run.id
              FROM scan_run run
              JOIN library_source source ON source.id = run.source_id
              WHERE source.uid = ? ORDER BY run.id DESC LIMIT 1
              """,
            arguments: [sourceUID]
          )
        else { return 0 }

        let rows = try Row.fetchAll(
          database,
          sql: """
            SELECT file.id AS media_file_id, file.material_revision
            FROM media_file file
            JOIN library_source source ON source.id = file.source_id
            LEFT JOIN composite_media_probe probe ON probe.media_file_id = file.id
            WHERE source.uid = ? AND source.deleted_at_ms IS NULL
              AND file.deleted_at_ms IS NULL AND file.availability = 'present'
              AND file.composite_media_json IS NOT NULL
              AND NOT EXISTS (
                SELECT 1 FROM scan_queue active
                WHERE active.media_file_id = file.id AND active.stage = 'probe'
                  AND active.input_revision = file.material_revision
                  AND active.state IN ('queued', 'running', 'retry')
              )
              AND (
                probe.media_file_id IS NULL
                OR probe.input_revision <> file.material_revision
                OR NOT (probe.input_size_bytes IS file.size_bytes)
                OR NOT (probe.input_modified_at_ms IS file.modified_at_ms)
                OR NOT (probe.input_etag IS file.etag)
                OR probe.selection_rule_version <> ?
                OR probe.status IN ('cancelled', 'remote_unavailable', 'dependency_failure')
                OR (? = 1 AND probe.status IN (
                  'unsupported', 'corrupt_structure', 'encrypted'
                ))
              )
            ORDER BY file.path_compare_key, file.id
            LIMIT ?
            """,
          arguments: [sourceUID, selectionRuleVersion, retryTerminalFailures ? 1 : 0, limit]
        )
        for row in rows {
          try Self.enqueueOptionalScanWork(
            runID: runID,
            mediaFileID: row["media_file_id"],
            inputRevision: row["material_revision"],
            stage: .probe,
            priority: priority,
            now: now,
            database: database
          )
        }
        return rows.count
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "composite probe enqueue failed")
    }
  }

  /// Atomically caches the result, optionally stores its technical projection, and resolves lease.
  package func persistCompositeMediaProbe(
    _ record: LibraryCompositeMediaProbeRecord,
    technicalProbe: LibraryTechnicalProbeRecord?,
    completing lease: LibraryScanWorkLease,
    disposition: LibraryCompositeMediaProbeDisposition
  ) async throws {
    guard lease.stage == .probe, record.inputRevision == lease.inputRevision,
      record.inputSizeBytes == lease.file.sizeBytes,
      record.inputModifiedAtMilliseconds == lease.file.modifiedAtMilliseconds,
      record.inputEntityTag == lease.file.entityTag,
      (record.status == .confirmed) == (technicalProbe != nil),
      (record.status == .confirmed)
        == {
          if case .complete = disposition { return true }
          return false
        }()
    else {
      throw SDKError(code: .invalidConfiguration, message: "composite probe commit is invalid")
    }
    let now = clock.nowMilliseconds()
    do {
      try await database.write { database in
        try Self.requireActiveScanWorkLease(lease, now: now, database: database)
        guard
          let mediaFileID = try Int64.fetchOne(
            database,
            sql: "SELECT media_file_id FROM scan_queue WHERE id = ?",
            arguments: [lease.queueID]
          )
        else {
          throw SDKError(code: .metadataNotFound, message: "composite probe file is unavailable")
        }
        try database.execute(
          sql: """
            INSERT INTO composite_media_probe(
              media_file_id, input_revision, input_size_bytes, input_modified_at_ms,
              input_etag, selection_rule_version, status, result_json, probed_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(media_file_id) DO UPDATE SET
              input_revision = excluded.input_revision,
              input_size_bytes = excluded.input_size_bytes,
              input_modified_at_ms = excluded.input_modified_at_ms,
              input_etag = excluded.input_etag,
              selection_rule_version = excluded.selection_rule_version,
              status = excluded.status,
              result_json = excluded.result_json,
              probed_at_ms = excluded.probed_at_ms
            """,
          arguments: [
            mediaFileID, record.inputRevision, record.inputSizeBytes,
            record.inputModifiedAtMilliseconds, record.inputEntityTag,
            record.selectionRuleVersion, record.status.rawValue, record.resultJSON, now,
          ]
        )
        if let technicalProbe {
          try Self.persistTechnicalProbe(
            technicalProbe,
            mediaFileID: mediaFileID,
            now: now,
            database: database
          )
        } else {
          // A newer failed disc probe must not leave a successful projection from an older
          // material revision visible through the generic technical-metadata tables.
          try database.execute(
            sql: """
              DELETE FROM media_stream
              WHERE media_file_id = ? AND EXISTS (
                SELECT 1 FROM technical_summary
                WHERE media_file_id = ? AND probe_provider = 'bdmviocontext'
              )
              """,
            arguments: [mediaFileID, mediaFileID]
          )
          try database.execute(
            sql: """
              DELETE FROM technical_summary
              WHERE media_file_id = ? AND probe_provider = 'bdmviocontext'
              """,
            arguments: [mediaFileID]
          )
        }
        try Self.resolveCompositeProbeLease(
          lease,
          disposition: disposition,
          now: now,
          database: database
        )
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "composite probe commit failed")
    }
  }

  private static func persistTechnicalProbe(
    _ probe: LibraryTechnicalProbeRecord,
    mediaFileID: Int64,
    now: Int64,
    database: Database
  ) throws {
    let summary = probe.summary
    try database.execute(
      sql: """
        INSERT INTO technical_summary(
          media_file_id, container, duration_ms, overall_bitrate, video_codec,
          width, height, frame_rate, hdr_profile, audio_codec, audio_channels,
          embedded_cover, probe_provider, probe_version, probed_at_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(media_file_id) DO UPDATE SET
          container = excluded.container, duration_ms = excluded.duration_ms,
          overall_bitrate = excluded.overall_bitrate, video_codec = excluded.video_codec,
          width = excluded.width, height = excluded.height, frame_rate = excluded.frame_rate,
          hdr_profile = excluded.hdr_profile, audio_codec = excluded.audio_codec,
          audio_channels = excluded.audio_channels, embedded_cover = excluded.embedded_cover,
          probe_provider = excluded.probe_provider, probe_version = excluded.probe_version,
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
    try database.execute(
      sql: "UPDATE media_file SET probe_version = ?, updated_at_ms = ? WHERE id = ?",
      arguments: [probe.probeVersion, now, mediaFileID]
    )
  }

  private static func resolveCompositeProbeLease(
    _ lease: LibraryScanWorkLease,
    disposition: LibraryCompositeMediaProbeDisposition,
    now: Int64,
    database: Database
  ) throws {
    let state: String
    let attemptsIncrement: Int
    let nextAttempt: Int64?
    let errorCode: String?
    switch disposition {
    case .complete:
      state = "done"
      attemptsIncrement = 0
      nextAttempt = nil
      errorCode = nil
    case .retry(let code, let delay):
      guard (0...604_800_000).contains(delay) else {
        throw SDKError(code: .invalidConfiguration, message: "composite probe retry is invalid")
      }
      state = "retry"
      attemptsIncrement = 1
      nextAttempt = now + delay
      errorCode = code.rawValue
    case .fail(let code):
      state = "failed"
      attemptsIncrement = 1
      nextAttempt = nil
      errorCode = code.rawValue
    }
    try database.execute(
      sql: """
        UPDATE scan_queue
        SET state = ?, attempts = attempts + ?, next_attempt_at_ms = ?,
            lease_until_ms = NULL, claimed_by = NULL, claim_token = NULL,
            heartbeat_at_ms = NULL, error_code = ?, error_message = NULL, updated_at_ms = ?
        WHERE id = ? AND stage = 'probe' AND state = 'running'
          AND claimed_by = ? AND claim_token = ? AND input_revision = ?
        """,
      arguments: [
        state, attemptsIncrement, nextAttempt, errorCode, now, lease.queueID,
        lease.workerID, lease.claimToken, lease.inputRevision,
      ]
    )
    guard database.changesCount == 1 else {
      throw SDKError(code: .conflict, message: "composite probe commit lost its lease")
    }
  }
}

import GRDB
import StellarCore

/// A file revision captured before reading local metadata dependencies.
public struct LibraryMetadataRefreshTarget: Sendable {
  public let file: LibraryFileFact
  public let inputRevision: Int64
  public let fileUID: String
}

extension LibraryStore {
  /// Captures identity and material revision before asynchronous matching or source reads.
  public func metadataRefreshTarget(
    sourceUID: String, mediaRelativePath: String
  ) async throws -> LibraryMetadataRefreshTarget {
    try await database.read { database in
      guard
        let row = try Row.fetchOne(
          database,
          sql: """
            SELECT f.*, s.uid AS source_uid FROM media_file f
            JOIN library_source s ON s.id = f.source_id
            WHERE s.uid = ? AND f.relative_path = ? AND f.availability = 'present'
              AND s.deleted_at_ms IS NULL AND f.deleted_at_ms IS NULL
            """, arguments: [sourceUID, mediaRelativePath])
      else {
        throw SDKError(code: .metadataNotFound, message: "metadata target is unavailable")
      }
      return LibraryMetadataRefreshTarget(
        file: LibraryFileFact(
          sourceUID: row["source_uid"], stableKey: row["stable_key"],
          relativePath: row["relative_path"],
          sizeBytes: row["size_bytes"], modifiedAtMilliseconds: row["modified_at_ms"],
          entityTag: row["etag"],
          availability: row["availability"], missingScanCount: row["missing_scan_count"]),
        inputRevision: row["material_revision"], fileUID: row["uid"])
    }
  }

  /// Reads a bounded window of already parsed files. Resume using the last file's stable key.
  public func metadataRefreshTargets(
    sourceUID: String, afterStableKey: String? = nil, limit: Int = 100
  ) async throws -> [LibraryMetadataRefreshTarget] {
    guard (1...500).contains(limit) else {
      throw SDKError(code: .invalidConfiguration, message: "metadata refresh window is invalid")
    }
    return try await database.read { database in
      try Row.fetchAll(
        database,
        sql: """
          SELECT f.*, s.uid AS source_uid FROM media_file f
          JOIN library_source s ON s.id = f.source_id
          JOIN parse_result p ON p.media_file_id = f.id
          WHERE s.uid = ? AND f.availability = 'present'
            AND s.deleted_at_ms IS NULL AND f.deleted_at_ms IS NULL
            AND (? IS NULL OR f.stable_key > ?)
          ORDER BY f.stable_key LIMIT ?
          """, arguments: [sourceUID, afterStableKey, afterStableKey, limit]
      ).map { row in
        LibraryMetadataRefreshTarget(
          file: LibraryFileFact(
            sourceUID: row["source_uid"], stableKey: row["stable_key"],
            relativePath: row["relative_path"], sizeBytes: row["size_bytes"],
            modifiedAtMilliseconds: row["modified_at_ms"], entityTag: row["etag"],
            availability: row["availability"], missingScanCount: row["missing_scan_count"]),
          inputRevision: row["material_revision"], fileUID: row["uid"])
      }
    }
  }

  /// Explicitly requests re-identification of a captured revision, preserving manual bindings.
  /// Hosts may use this after a parser upgrade or a user-requested refresh.
  public func invalidateMetadata(_ target: LibraryMetadataRefreshTarget) async throws {
    let clock = self.clock
    try await database.write { database in
      let fileID = try Self.requireMetadataRefreshTarget(target, database: database)
      try Self.invalidateMetadata(fileID: fileID, now: clock.nowMilliseconds(), database: database)
    }
  }

  package func invalidateMetadataIfChanged(
    _ batch: LibraryMetadataIntakeBatch, target: LibraryMetadataRefreshTarget
  ) async throws -> Bool {
    guard batch.sourceUID == target.file.sourceUID,
      batch.mediaRelativePath == target.file.relativePath
    else {
      throw SDKError(code: .conflict, message: "metadata refresh target changed")
    }
    let clock = self.clock
    return try await database.write { database in
      let fileID = try Self.requireMetadataRefreshTarget(target, database: database)
      let parserVersion = try Int.fetchOne(
        database,
        sql: "SELECT parser_version FROM parse_result WHERE media_file_id = ?", arguments: [fileID])
      let rows = try Row.fetchAll(
        database,
        sql: "SELECT relative_path, modified_at_ms, sha256 FROM sidecar WHERE media_file_id = ?",
        arguments: [fileID])
      let previous = Dictionary(
        uniqueKeysWithValues: rows.map { ($0["relative_path"] as String, $0) })
      let changed =
        parserVersion != batch.parseResult.parserVersion || rows.count != batch.sidecars.count
        || batch.sidecars.contains { sidecar in
          guard let old = previous[sidecar.relativePath] else { return true }
          return (old["modified_at_ms"] as Int64?) != sidecar.modifiedAtMilliseconds
            || (old["sha256"] as String?) != sidecar.sha256
        }
      if changed {
        try Self.invalidateMetadata(
          fileID: fileID, now: clock.nowMilliseconds(), database: database)
      }
      return changed
    }
  }

  package static func requireMetadataRefreshTarget(
    _ target: LibraryMetadataRefreshTarget, database: Database
  ) throws -> Int64 {
    guard
      let fileID = try Int64.fetchOne(
        database,
        sql: """
          SELECT f.id FROM media_file f JOIN library_source s ON s.id = f.source_id
          WHERE f.uid = ? AND f.material_revision = ? AND s.uid = ? AND f.stable_key = ?
            AND f.relative_path = ? AND f.availability = 'present'
            AND f.deleted_at_ms IS NULL AND s.deleted_at_ms IS NULL
          """,
        arguments: [
          target.fileUID, target.inputRevision, target.file.sourceUID,
          target.file.stableKey, target.file.relativePath,
        ])
    else {
      throw SDKError(code: .conflict, message: "metadata refresh revision changed")
    }
    return fileID
  }

  private static func invalidateMetadata(fileID: Int64, now: Int64, database: Database) throws {
    try database.execute(
      sql: """
        UPDATE media_file SET material_revision = material_revision + 1, updated_at_ms = ? WHERE id = ?
        """, arguments: [now, fileID])
    try database.execute(
      sql: """
        UPDATE scan_queue SET state = 'done', claimed_by = NULL, claim_token = NULL,
          lease_until_ms = NULL, heartbeat_at_ms = NULL, next_attempt_at_ms = NULL,
          error_code = 'conflict', error_message = 'Local metadata dependencies changed.', updated_at_ms = ?
        WHERE media_file_id = ? AND state IN ('queued', 'running', 'retry', 'failed')
        """, arguments: [now, fileID])
    try database.execute(
      sql: """
        INSERT INTO scan_queue(run_id, media_file_id, stage, state, input_revision, updated_at_ms)
        SELECT last_seen_run_id, id, 'parse', 'queued', material_revision, ? FROM media_file WHERE id = ?
        ON CONFLICT(run_id, media_file_id, stage) DO UPDATE SET
          state = 'queued', input_revision = excluded.input_revision, updated_at_ms = excluded.updated_at_ms,
          attempts = 0, error_code = NULL, error_message = NULL
        """, arguments: [now, fileID])
  }
}

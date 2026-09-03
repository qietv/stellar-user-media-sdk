import GRDB
import StellarCore
import StellarRemoteMedia

/// Source-specific retention and anomaly protection for authoritative missing reconciliation.
public struct LibraryMissingRetentionPolicy: Equatable, Sendable {
  public let gracePeriodMilliseconds: Int64
  public let requiredMissingScanCount: Int
  public let protectsEmptyResult: Bool
  public let suspiciousDropPercentage: Int
  public let suspiciousDropMinimumCount: Int

  public init(
    gracePeriodMilliseconds: Int64,
    requiredMissingScanCount: Int = 2,
    protectsEmptyResult: Bool = true,
    suspiciousDropPercentage: Int = 80,
    suspiciousDropMinimumCount: Int = 100
  ) throws {
    guard (0...315_576_000_000).contains(gracePeriodMilliseconds),
      (1...1_000).contains(requiredMissingScanCount),
      (0...100).contains(suspiciousDropPercentage),
      (1...1_000_000_000).contains(suspiciousDropMinimumCount)
    else {
      throw SDKError(code: .invalidConfiguration, message: "missing retention policy is invalid")
    }
    self.gracePeriodMilliseconds = gracePeriodMilliseconds
    self.requiredMissingScanCount = requiredMissingScanCount
    self.protectsEmptyResult = protectsEmptyResult
    self.suspiciousDropPercentage = suspiciousDropPercentage
    self.suspiciousDropMinimumCount = suspiciousDropMinimumCount
  }

  /// Recommended defaults: one day for local storage, seven days for remote shares, and thirty
  /// days for cloud drives. Every source still requires two authoritative misses.
  public static func recommended(for kind: LibrarySourceKind) -> LibraryMissingRetentionPolicy {
    let grace: Int64
    switch kind {
    case .localFolder, .deviceMedia:
      grace = 86_400_000
    case .cloudDrive:
      grace = 2_592_000_000
    case .smb, .nfs, .webdav, .ftp, .plex, .emby, .jellyfin:
      grace = 604_800_000
    }
    return LibraryMissingRetentionPolicy(
      uncheckedGracePeriodMilliseconds: grace,
      requiredMissingScanCount: 2,
      protectsEmptyResult: true,
      suspiciousDropPercentage: 80,
      suspiciousDropMinimumCount: 100
    )
  }

  private init(
    uncheckedGracePeriodMilliseconds: Int64,
    requiredMissingScanCount: Int,
    protectsEmptyResult: Bool,
    suspiciousDropPercentage: Int,
    suspiciousDropMinimumCount: Int
  ) {
    gracePeriodMilliseconds = uncheckedGracePeriodMilliseconds
    self.requiredMissingScanCount = requiredMissingScanCount
    self.protectsEmptyResult = protectsEmptyResult
    self.suspiciousDropPercentage = suspiciousDropPercentage
    self.suspiciousDropMinimumCount = suspiciousDropMinimumCount
  }
}

/// Bounded policy for soft file deletion and Infuse-style two-phase metadata collection.
public struct LibraryGarbageCollectionPolicy: Equatable, Sendable {
  public let metadataOrphanGracePeriodMilliseconds: Int64
  public let deletionMarkGracePeriodMilliseconds: Int64
  public let fileTombstoneRetentionMilliseconds: Int64
  public let batchSize: Int

  public init(
    metadataOrphanGracePeriodMilliseconds: Int64 = 604_800_000,
    deletionMarkGracePeriodMilliseconds: Int64 = 86_400_000,
    fileTombstoneRetentionMilliseconds: Int64 = 86_400_000,
    batchSize: Int = 200
  ) throws {
    let durations = [
      metadataOrphanGracePeriodMilliseconds,
      deletionMarkGracePeriodMilliseconds,
      fileTombstoneRetentionMilliseconds,
    ]
    guard durations.allSatisfy({ (0...315_576_000_000).contains($0) }),
      (1...2_000).contains(batchSize)
    else {
      throw SDKError(code: .invalidConfiguration, message: "garbage collection policy is invalid")
    }
    self.metadataOrphanGracePeriodMilliseconds = metadataOrphanGracePeriodMilliseconds
    self.deletionMarkGracePeriodMilliseconds = deletionMarkGracePeriodMilliseconds
    self.fileTombstoneRetentionMilliseconds = fileTombstoneRetentionMilliseconds
    self.batchSize = batchSize
  }

  /// Seven-day metadata retention with a one-day reversible mark and file tombstone window.
  public static let recommended = LibraryGarbageCollectionPolicy(
    uncheckedMetadataOrphanGracePeriodMilliseconds: 604_800_000,
    deletionMarkGracePeriodMilliseconds: 86_400_000,
    fileTombstoneRetentionMilliseconds: 86_400_000,
    batchSize: 200
  )

  private init(
    uncheckedMetadataOrphanGracePeriodMilliseconds: Int64,
    deletionMarkGracePeriodMilliseconds: Int64,
    fileTombstoneRetentionMilliseconds: Int64,
    batchSize: Int
  ) {
    metadataOrphanGracePeriodMilliseconds = uncheckedMetadataOrphanGracePeriodMilliseconds
    self.deletionMarkGracePeriodMilliseconds = deletionMarkGracePeriodMilliseconds
    self.fileTombstoneRetentionMilliseconds = fileTombstoneRetentionMilliseconds
    self.batchSize = batchSize
  }
}

/// Counts from one bounded, idempotent library garbage-collection pass.
public struct LibraryGarbageCollectionResult: Equatable, Sendable {
  public let softDeletedFileCount: Int
  public let purgedFileCount: Int
  public let newlyOrphanedEntityCount: Int
  public let markedEntityCount: Int
  public let purgedEntityCount: Int
  public let restoredEntityCount: Int

  package init(
    softDeletedFileCount: Int,
    purgedFileCount: Int,
    newlyOrphanedEntityCount: Int,
    markedEntityCount: Int,
    purgedEntityCount: Int,
    restoredEntityCount: Int
  ) {
    self.softDeletedFileCount = softDeletedFileCount
    self.purgedFileCount = purgedFileCount
    self.newlyOrphanedEntityCount = newlyOrphanedEntityCount
    self.markedEntityCount = markedEntityCount
    self.purgedEntityCount = purgedEntityCount
    self.restoredEntityCount = restoredEntityCount
  }
}

package struct LibraryMissingReconciliationDecision {
  package let shouldReconcile: Bool
  package let observedFileCount: Int64
  package let warningCode: String?
  package let warningSummary: String?
}

extension LibraryStore {
  package static let missingReconciliationWithheldCode = "unsafe_missing_reconciliation"

  /// Replaces the durable missing-retention and anomalous-result policy for one source.
  public func setMissingRetentionPolicy(
    _ policy: LibraryMissingRetentionPolicy,
    forSourceUID sourceUID: String
  ) async throws {
    try Self.validateSourceUID(sourceUID)
    let now = clock.nowMilliseconds()
    do {
      try await database.write { database in
        try database.execute(
          sql: """
            UPDATE library_source SET
              missing_grace_ms = ?,
              missing_required_scan_count = ?,
              missing_empty_root_guard = ?,
              missing_drop_guard_percent = ?,
              missing_drop_guard_minimum_count = ?,
              updated_at_ms = ?
            WHERE uid = ? AND deleted_at_ms IS NULL
            """,
          arguments: [
            policy.gracePeriodMilliseconds, policy.requiredMissingScanCount,
            policy.protectsEmptyResult ? 1 : 0, policy.suspiciousDropPercentage,
            policy.suspiciousDropMinimumCount, now, sourceUID,
          ]
        )
        guard database.changesCount == 1 else {
          throw SDKError(code: .metadataNotFound, message: "library source was not found")
        }
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "missing retention policy write failed")
    }
  }

  /// Marks a remote source offline without mutating file-level missing counters.
  public func markSourceOffline(
    sourceUID: String,
    errorCode: SDKErrorCode = .networkUnavailable
  ) async throws {
    try Self.validateSourceUID(sourceUID)
    guard errorCode == .networkUnavailable || errorCode == .remoteUnavailable else {
      throw SDKError(code: .invalidConfiguration, message: "offline source error is invalid")
    }
    let now = clock.nowMilliseconds()
    do {
      try await database.write { database in
        try database.execute(
          sql: """
            UPDATE library_source SET
              offline_since_ms = COALESCE(offline_since_ms, ?),
              last_error_code = ?, updated_at_ms = ?
            WHERE uid = ? AND deleted_at_ms IS NULL
            """,
          arguments: [now, errorCode.rawValue, now, sourceUID]
        )
        guard database.changesCount == 1 else {
          throw SDKError(code: .metadataNotFound, message: "library source was not found")
        }
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "source offline state write failed")
    }
  }

  /// Clears source-level offline state after connectivity has been authoritatively restored.
  public func markSourceOnline(sourceUID: String) async throws {
    try Self.validateSourceUID(sourceUID)
    let now = clock.nowMilliseconds()
    do {
      try await database.write { database in
        try database.execute(
          sql: """
            UPDATE library_source SET
              offline_since_ms = NULL, last_error_code = NULL, updated_at_ms = ?
            WHERE uid = ? AND deleted_at_ms IS NULL
            """,
          arguments: [now, sourceUID]
        )
        guard database.changesCount == 1 else {
          throw SDKError(code: .metadataNotFound, message: "library source was not found")
        }
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "source online state write failed")
    }
  }

  /// Runs one bounded cleanup pass. Missing files become reversible tombstones first; metadata is
  /// marked and rechecked in a later pass, and user-owned state always prevents entity deletion.
  public func runGarbageCollection(
    policy: LibraryGarbageCollectionPolicy = .recommended
  ) async throws -> LibraryGarbageCollectionResult {
    let now = clock.nowMilliseconds()
    do {
      return try await database.write { database in
        let softDeleted = try Self.softDeleteExpiredMissingFiles(
          now: now,
          limit: policy.batchSize,
          database: database
        )
        let purgedFiles = try Self.purgeExpiredFileTombstones(
          now: now,
          retentionMilliseconds: policy.fileTombstoneRetentionMilliseconds,
          limit: policy.batchSize,
          database: database
        )
        try Self.refreshActiveEntitySet(database: database)
        let restored = try Self.restoreActiveEntityMarks(now: now, database: database)
        let newlyOrphaned = try Self.markNewEntityOrphans(
          now: now,
          limit: policy.batchSize,
          database: database
        )
        let marked = try Self.markExpiredEntityOrphans(
          now: now,
          graceMilliseconds: policy.metadataOrphanGracePeriodMilliseconds,
          limit: policy.batchSize,
          database: database
        )
        let purgedEntities = try Self.purgeMarkedEntities(
          now: now,
          markGraceMilliseconds: policy.deletionMarkGracePeriodMilliseconds,
          limit: policy.batchSize,
          database: database
        )
        return LibraryGarbageCollectionResult(
          softDeletedFileCount: softDeleted,
          purgedFileCount: purgedFiles,
          newlyOrphanedEntityCount: newlyOrphaned,
          markedEntityCount: marked,
          purgedEntityCount: purgedEntities,
          restoredEntityCount: restored
        )
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "library garbage collection failed")
    }
  }

  package static func missingReconciliationDecision(
    sourceID: Int64,
    runID: Int64,
    coverageJSON: String,
    roots: [RemoteLocator],
    semantics: RemotePathSemantics,
    database: Database
  ) throws -> LibraryMissingReconciliationDecision {
    try replaceCoveredRoots(roots, semantics: semantics, database: database)
    let observedFileCount = try countStagedFiles(
      runID: runID,
      insideCoveredRoots: true,
      database: database
    )
    guard
      let source = try Row.fetchOne(
        database,
        sql: """
          SELECT missing_empty_root_guard, missing_drop_guard_percent,
                 missing_drop_guard_minimum_count
          FROM library_source WHERE id = ?
          """,
        arguments: [sourceID]
      )
    else {
      throw SDKError(code: .storageFailure, message: "missing policy source is unavailable")
    }
    let presentFileCount =
      try Int64.fetchOne(
        database,
        sql: """
          SELECT COUNT(*)
          FROM media_file AS file
          WHERE file.source_id = ? AND file.availability = 'present'
            AND file.deleted_at_ms IS NULL
            AND EXISTS (
              SELECT 1 FROM stellar_scan_covered_root AS root
              WHERE root.path_compare_key = ''
                 OR file.path_compare_key = root.path_compare_key
                 OR substr(file.path_compare_key, 1, length(root.path_compare_key) + 1)
                      = root.path_compare_key || '/'
            )
          """,
        arguments: [sourceID]
      ) ?? 0
    let protectsEmptyResult = (source["missing_empty_root_guard"] as Int) == 1
    let dropPercentage: Int = source["missing_drop_guard_percent"]
    let minimumDrop: Int64 = source["missing_drop_guard_minimum_count"]
    let drop = max(0, presentFileCount - observedFileCount)
    let emptyIsSuspicious = protectsEmptyResult && presentFileCount > 0 && observedFileCount == 0
    let dropIsSuspicious = dropPercentage > 0 && drop >= minimumDrop && presentFileCount > 0
      && (Double(drop) / Double(presentFileCount)) * 100 >= Double(dropPercentage)
    guard emptyIsSuspicious || dropIsSuspicious else {
      return LibraryMissingReconciliationDecision(
        shouldReconcile: true,
        observedFileCount: observedFileCount,
        warningCode: nil,
        warningSummary: nil
      )
    }

    let previousConfirmedSameAnomaly =
      try Bool.fetchOne(
        database,
        sql: """
          SELECT EXISTS(
            SELECT 1 FROM scan_run AS previous
            WHERE previous.id = (
              SELECT MAX(candidate.id) FROM scan_run AS candidate
              WHERE candidate.source_id = ? AND candidate.id < ?
            )
              AND previous.state = 'completed'
              AND previous.reconcile_missing = 0
              AND previous.error_code = ?
              AND previous.coverage_json = ?
              AND previous.observed_file_count = ?
              AND NOT EXISTS (
                SELECT current.stable_key
                FROM scan_discovery AS current
                WHERE current.run_id = ?
                  AND EXISTS (
                    SELECT 1 FROM stellar_scan_covered_root AS root
                    WHERE root.path_compare_key = ''
                       OR current.path_compare_key = root.path_compare_key
                       OR substr(current.path_compare_key, 1, length(root.path_compare_key) + 1)
                            = root.path_compare_key || '/'
                  )
                EXCEPT
                SELECT prior.stable_key
                FROM scan_discovery AS prior
                WHERE prior.run_id = previous.id
                  AND EXISTS (
                    SELECT 1 FROM stellar_scan_covered_root AS root
                    WHERE root.path_compare_key = ''
                       OR prior.path_compare_key = root.path_compare_key
                       OR substr(prior.path_compare_key, 1, length(root.path_compare_key) + 1)
                            = root.path_compare_key || '/'
                  )
              )
              AND NOT EXISTS (
                SELECT prior.stable_key
                FROM scan_discovery AS prior
                WHERE prior.run_id = previous.id
                  AND EXISTS (
                    SELECT 1 FROM stellar_scan_covered_root AS root
                    WHERE root.path_compare_key = ''
                       OR prior.path_compare_key = root.path_compare_key
                       OR substr(prior.path_compare_key, 1, length(root.path_compare_key) + 1)
                            = root.path_compare_key || '/'
                  )
                EXCEPT
                SELECT current.stable_key
                FROM scan_discovery AS current
                WHERE current.run_id = ?
                  AND EXISTS (
                    SELECT 1 FROM stellar_scan_covered_root AS root
                    WHERE root.path_compare_key = ''
                       OR current.path_compare_key = root.path_compare_key
                       OR substr(current.path_compare_key, 1, length(root.path_compare_key) + 1)
                            = root.path_compare_key || '/'
                  )
              )
          )
          """,
        arguments: [
          sourceID, runID, missingReconciliationWithheldCode, coverageJSON, observedFileCount,
          runID, runID,
        ]
      ) ?? false
    if previousConfirmedSameAnomaly {
      return LibraryMissingReconciliationDecision(
        shouldReconcile: true,
        observedFileCount: observedFileCount,
        warningCode: nil,
        warningSummary: nil
      )
    }
    return LibraryMissingReconciliationDecision(
      shouldReconcile: false,
      observedFileCount: observedFileCount,
      warningCode: missingReconciliationWithheldCode,
      warningSummary: "Missing reconciliation was withheld pending a repeated authoritative result."
    )
  }

  package static func countStagedFiles(
    runID: Int64,
    insideCoveredRoots: Bool = false,
    database: Database
  ) throws -> Int64 {
    let rootFilter = insideCoveredRoots
      ? """
        AND EXISTS (
          SELECT 1 FROM stellar_scan_covered_root AS root
          WHERE root.path_compare_key = ''
             OR discovery.path_compare_key = root.path_compare_key
             OR substr(discovery.path_compare_key, 1, length(root.path_compare_key) + 1)
                  = root.path_compare_key || '/'
        )
        """
      : ""
    return try Int64.fetchOne(
      database,
      sql: "SELECT COUNT(*) FROM scan_discovery AS discovery WHERE discovery.run_id = ? \(rootFilter)",
      arguments: [runID]
    ) ?? 0
  }

  package static func reactivateEntitiesBoundToPublishedFiles(
    now: Int64,
    database: Database
  ) throws {
    try database.execute(
      sql: """
        WITH RECURSIVE bound(id, parent_id) AS (
          SELECT entity.id, entity.parent_id
          FROM stellar_scan_publish_file AS published
          JOIN media_file AS file ON file.id = published.media_file_id
          JOIN file_binding AS binding ON binding.media_file_id = file.id
          JOIN media_entity AS entity ON entity.id = binding.entity_id
          WHERE file.availability = 'present' AND file.deleted_at_ms IS NULL
          UNION
          SELECT parent.id, parent.parent_id
          FROM media_entity AS parent
          JOIN bound AS child ON child.parent_id = parent.id
        )
        UPDATE media_entity SET
          orphaned_at_ms = NULL, gc_marked_at_ms = NULL, updated_at_ms = ?
        WHERE id IN (SELECT id FROM bound)
          AND (orphaned_at_ms IS NOT NULL OR gc_marked_at_ms IS NOT NULL)
        """,
      arguments: [now]
    )
  }

  package static func reactivateEntityHierarchy(
    entityID: Int64,
    now: Int64,
    database: Database
  ) throws {
    try database.execute(
      sql: """
        WITH RECURSIVE hierarchy(id, parent_id) AS (
          SELECT id, parent_id FROM media_entity WHERE id = ?
          UNION
          SELECT parent.id, parent.parent_id
          FROM media_entity AS parent
          JOIN hierarchy AS child ON child.parent_id = parent.id
        )
        UPDATE media_entity SET
          orphaned_at_ms = NULL, gc_marked_at_ms = NULL, updated_at_ms = ?
        WHERE id IN (SELECT id FROM hierarchy)
          AND (orphaned_at_ms IS NOT NULL OR gc_marked_at_ms IS NOT NULL)
        """,
      arguments: [entityID, now]
    )
  }

  package static func replaceCoveredRoots(
    _ roots: [RemoteLocator],
    semantics: RemotePathSemantics,
    database: Database
  ) throws {
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
    for root in roots {
      try insertRoot.execute(arguments: [root.pathComparisonKey(using: semantics)])
    }
  }

  private static func validateSourceUID(_ sourceUID: String) throws {
    guard !sourceUID.isEmpty, !sourceUID.contains("\0") else {
      throw SDKError(code: .invalidConfiguration, message: "library source identity is invalid")
    }
  }

  private static func softDeleteExpiredMissingFiles(
    now: Int64,
    limit: Int,
    database: Database
  ) throws -> Int {
    try database.execute(
      sql: """
        CREATE TEMP TABLE IF NOT EXISTS stellar_gc_file (
          id INTEGER PRIMARY KEY
        )
        """
    )
    try database.execute(sql: "DELETE FROM stellar_gc_file")
    try database.execute(
      sql: """
        INSERT INTO stellar_gc_file(id)
        SELECT file.id
        FROM media_file AS file
        JOIN library_source AS source ON source.id = file.source_id
        WHERE file.availability = 'missing' AND file.deleted_at_ms IS NULL
          AND file.missing_since_ms IS NOT NULL
          AND file.missing_since_ms <= ? - source.missing_grace_ms
          AND file.missing_scan_count >= source.missing_required_scan_count
          AND source.enabled = 1 AND source.deleted_at_ms IS NULL
          AND source.offline_since_ms IS NULL
          AND NOT EXISTS (
            SELECT 1 FROM scan_run AS run
            WHERE run.source_id = source.id
              AND run.state IN ('queued', 'enumerating', 'processing', 'finalizing')
          )
        ORDER BY file.missing_since_ms, file.id
        LIMIT ?
        """,
      arguments: [now, limit]
    )
    let count = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM stellar_gc_file") ?? 0
    guard count > 0 else { return 0 }
    try database.execute(
      sql: """
        UPDATE media_file SET
          availability = 'deleted', deleted_at_ms = ?, updated_at_ms = ?
        WHERE id IN (SELECT id FROM stellar_gc_file)
        """,
      arguments: [now, now]
    )
    try database.execute(
      sql: """
        UPDATE playback_state SET media_file_id = NULL, updated_at_ms = ?
        WHERE media_file_id IN (SELECT id FROM stellar_gc_file)
        """,
      arguments: [now]
    )
    try database.execute(
      sql: """
        UPDATE scan_queue SET
          state = 'done', next_attempt_at_ms = NULL, lease_until_ms = NULL,
          claimed_by = NULL, claim_token = NULL, heartbeat_at_ms = NULL,
          error_code = 'metadata_not_found',
          error_message = 'File was retired after the missing retention period.',
          updated_at_ms = ?
        WHERE media_file_id IN (SELECT id FROM stellar_gc_file)
          AND state IN ('queued', 'running', 'retry', 'failed')
        """,
      arguments: [now]
    )
    return count
  }

  private static func purgeExpiredFileTombstones(
    now: Int64,
    retentionMilliseconds: Int64,
    limit: Int,
    database: Database
  ) throws -> Int {
    try database.execute(sql: "DELETE FROM stellar_gc_file")
    try database.execute(
      sql: """
        INSERT INTO stellar_gc_file(id)
        SELECT file.id
        FROM media_file AS file
        JOIN library_source AS source ON source.id = file.source_id
        WHERE file.availability = 'deleted' AND file.deleted_at_ms IS NOT NULL
          AND file.deleted_at_ms <= ? - ?
          AND source.offline_since_ms IS NULL
          AND NOT EXISTS (
            SELECT 1 FROM scan_run AS run
            WHERE run.source_id = source.id
              AND run.state IN ('queued', 'enumerating', 'processing', 'finalizing')
          )
          AND NOT EXISTS (
            SELECT 1 FROM file_binding AS binding
            WHERE binding.media_file_id = file.id AND binding.locked = 1
          )
          AND NOT EXISTS (
            SELECT 1 FROM change_log AS pending
            WHERE pending.entity_uid = file.uid AND pending.uploaded_at_ms IS NULL
          )
        ORDER BY file.deleted_at_ms, file.id
        LIMIT ?
        """,
      arguments: [now, retentionMilliseconds, limit]
    )
    let count = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM stellar_gc_file") ?? 0
    guard count > 0 else { return 0 }
    try database.execute(sql: "DELETE FROM media_file WHERE id IN (SELECT id FROM stellar_gc_file)")
    return count
  }

  private static func refreshActiveEntitySet(database: Database) throws {
    try database.execute(
      sql: """
        CREATE TEMP TABLE IF NOT EXISTS stellar_gc_active_entity (
          id INTEGER PRIMARY KEY
        )
        """
    )
    try database.execute(sql: "DELETE FROM stellar_gc_active_entity")
    try database.execute(
      sql: """
        WITH RECURSIVE active(id, parent_id) AS (
          SELECT entity.id, entity.parent_id
          FROM file_binding AS binding
          JOIN media_file AS file ON file.id = binding.media_file_id
          JOIN library_source AS source ON source.id = file.source_id
          JOIN media_entity AS entity ON entity.id = binding.entity_id
          WHERE file.deleted_at_ms IS NULL
            AND file.availability IN ('present', 'offline', 'missing')
            AND source.enabled = 1 AND source.deleted_at_ms IS NULL
          UNION
          SELECT parent.id, parent.parent_id
          FROM media_entity AS parent
          JOIN active AS child ON child.parent_id = parent.id
        )
        INSERT OR IGNORE INTO stellar_gc_active_entity(id)
        SELECT id FROM active
        """
    )
  }

  private static func restoreActiveEntityMarks(now: Int64, database: Database) throws -> Int {
    try database.execute(
      sql: """
        UPDATE media_entity SET
          orphaned_at_ms = NULL, gc_marked_at_ms = NULL, updated_at_ms = ?
        WHERE id IN (SELECT id FROM stellar_gc_active_entity)
          AND (orphaned_at_ms IS NOT NULL OR gc_marked_at_ms IS NOT NULL)
        """,
      arguments: [now]
    )
    return database.changesCount
  }

  private static func markNewEntityOrphans(
    now: Int64,
    limit: Int,
    database: Database
  ) throws -> Int {
    try database.execute(
      sql: """
        WITH candidate AS (
          SELECT entity.id FROM media_entity AS entity
          WHERE entity.deleted_at_ms IS NULL AND entity.orphaned_at_ms IS NULL
            AND entity.id NOT IN (SELECT id FROM stellar_gc_active_entity)
          ORDER BY entity.id
          LIMIT ?
        )
        UPDATE media_entity SET orphaned_at_ms = ?, updated_at_ms = ?
        WHERE id IN (SELECT id FROM candidate)
        """,
      arguments: [limit, now, now]
    )
    return database.changesCount
  }

  private static func markExpiredEntityOrphans(
    now: Int64,
    graceMilliseconds: Int64,
    limit: Int,
    database: Database
  ) throws -> Int {
    try database.execute(
      sql: """
        WITH candidate AS (
          SELECT entity.id FROM media_entity AS entity
          WHERE entity.deleted_at_ms IS NULL AND entity.gc_marked_at_ms IS NULL
            AND entity.orphaned_at_ms IS NOT NULL
            AND entity.orphaned_at_ms <= ? - ?
            AND entity.id NOT IN (SELECT id FROM stellar_gc_active_entity)
          ORDER BY entity.orphaned_at_ms, entity.id
          LIMIT ?
        )
        UPDATE media_entity SET gc_marked_at_ms = ?, updated_at_ms = ?
        WHERE id IN (SELECT id FROM candidate)
        """,
      arguments: [now, graceMilliseconds, limit, now, now]
    )
    return database.changesCount
  }

  private static func purgeMarkedEntities(
    now: Int64,
    markGraceMilliseconds: Int64,
    limit: Int,
    database: Database
  ) throws -> Int {
    try database.execute(
      sql: """
        CREATE TEMP TABLE IF NOT EXISTS stellar_gc_entity (
          id INTEGER PRIMARY KEY
        )
        """
    )
    try database.execute(sql: "DELETE FROM stellar_gc_entity")
    try database.execute(
      sql: """
        INSERT INTO stellar_gc_entity(id)
        SELECT entity.id
        FROM media_entity AS entity
        WHERE entity.deleted_at_ms IS NULL AND entity.gc_marked_at_ms IS NOT NULL
          AND entity.gc_marked_at_ms <= ? - ?
          AND entity.id NOT IN (SELECT id FROM stellar_gc_active_entity)
          AND entity.metadata_state <> 'manual'
          AND NOT EXISTS (SELECT 1 FROM media_entity child WHERE child.parent_id = entity.id)
          AND NOT EXISTS (SELECT 1 FROM file_binding binding WHERE binding.entity_id = entity.id)
          AND NOT EXISTS (SELECT 1 FROM playback_state state WHERE state.entity_id = entity.id)
          AND NOT EXISTS (SELECT 1 FROM playback_marker marker WHERE marker.entity_id = entity.id)
          AND NOT EXISTS (
            SELECT 1 FROM collection_item item
            JOIN media_collection collection ON collection.id = item.collection_id
            WHERE item.entity_id = entity.id AND collection.kind = 'manual'
              AND collection.deleted_at_ms IS NULL
          )
          AND (entity.locked_fields_json IS NULL OR entity.locked_fields_json IN ('', '{}'))
          AND NOT EXISTS (
            SELECT 1 FROM change_log pending
            WHERE pending.entity_uid = entity.uid AND pending.uploaded_at_ms IS NULL
          )
        ORDER BY entity.gc_marked_at_ms, entity.id
        LIMIT ?
        """,
      arguments: [now, markGraceMilliseconds, limit]
    )
    let count = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM stellar_gc_entity") ?? 0
    guard count > 0 else { return 0 }
    try database.execute(
      sql: """
        DELETE FROM collection_item
        WHERE entity_id IN (SELECT id FROM stellar_gc_entity)
          AND collection_id IN (
            SELECT id FROM media_collection WHERE kind <> 'manual' OR deleted_at_ms IS NOT NULL
          )
        """
    )
    try database.execute(
      sql: "DELETE FROM media_entity WHERE id IN (SELECT id FROM stellar_gc_entity)"
    )
    return count
  }
}

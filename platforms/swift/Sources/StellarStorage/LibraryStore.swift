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

/// Scanner-oriented repository over a migrated `library.sqlite` database.
public struct LibraryStore: Sendable {
  public let database: StorageDatabase
  private let clock: any SDKClock
  private let uuidGenerator: any SDKUUIDGenerating

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

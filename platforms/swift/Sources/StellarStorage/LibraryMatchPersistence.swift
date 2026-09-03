import GRDB
import StellarCore

package struct LibraryMatchExternalIDRecord: Equatable, Hashable, Sendable {
  package let provider: String
  package let namespace: String
  package let value: String
  package let isPrimary: Bool

  package init(provider: String, namespace: String, value: String, isPrimary: Bool) throws {
    guard !provider.isEmpty, !namespace.isEmpty, !value.isEmpty,
      !provider.contains("\0"), !namespace.contains("\0"), !value.contains("\0")
    else {
      throw SDKError(code: .invalidConfiguration, message: "match external ID is invalid")
    }
    self.provider = provider
    self.namespace = namespace
    self.value = value
    self.isPrimary = isPrimary
  }
}

package struct LibraryMatchRootEntityRecord: Equatable, Sendable {
  package let kind: String
  package let canonicalTitle: String
  package let originalTitle: String?
  package let year: Int?
  package let externalIDs: [LibraryMatchExternalIDRecord]

  package init(
    kind: String,
    canonicalTitle: String,
    originalTitle: String? = nil,
    year: Int? = nil,
    externalIDs: [LibraryMatchExternalIDRecord]
  ) throws {
    guard ["movie", "series"].contains(kind), !canonicalTitle.isEmpty,
      !canonicalTitle.contains("\0"), originalTitle?.contains("\0") != true,
      year.map({ (1000...9999).contains($0) }) ?? true, !externalIDs.isEmpty,
      Set(externalIDs.map { "\($0.provider)\0\($0.namespace)" }).count == externalIDs.count
    else {
      throw SDKError(code: .invalidConfiguration, message: "match root entity is invalid")
    }
    self.kind = kind
    self.canonicalTitle = canonicalTitle
    self.originalTitle = originalTitle
    self.year = year
    self.externalIDs = externalIDs
  }
}

package struct LibraryFileBindingRequest: Sendable {
  package let sourceUID: String
  package let mediaRelativePath: String
  package let rootEntity: LibraryMatchRootEntityRecord
  package let seasonNumber: Int?
  package let episodeNumber: Int?
  package let matchMethod: String
  package let confidence: Double
  package let matchedQueryJSON: String
  package let locked: Bool
  package let canReplaceLockedBinding: Bool

  package init(
    sourceUID: String,
    mediaRelativePath: String,
    rootEntity: LibraryMatchRootEntityRecord,
    seasonNumber: Int? = nil,
    episodeNumber: Int? = nil,
    matchMethod: String,
    confidence: Double,
    matchedQueryJSON: String,
    locked: Bool,
    canReplaceLockedBinding: Bool
  ) throws {
    let methods = [
      "manual", "sidecar_id", "filename_id", "provider_search", "media_server", "inherited",
    ]
    let hasEpisode = seasonNumber != nil || episodeNumber != nil
    guard !sourceUID.isEmpty, !sourceUID.contains("\0"), !mediaRelativePath.isEmpty,
      !mediaRelativePath.contains("\0"), methods.contains(matchMethod), confidence.isFinite,
      (0...1).contains(confidence), !matchedQueryJSON.isEmpty,
      !matchedQueryJSON.contains("\0"),
      !hasEpisode || (rootEntity.kind == "series" && seasonNumber != nil && episodeNumber != nil),
      seasonNumber.map({ $0 >= 0 }) ?? true, episodeNumber.map({ $0 >= 0 }) ?? true,
      rootEntity.kind != "series" || hasEpisode,
      !canReplaceLockedBinding || locked
    else {
      throw SDKError(code: .invalidConfiguration, message: "file binding request is invalid")
    }
    self.sourceUID = sourceUID
    self.mediaRelativePath = mediaRelativePath
    self.rootEntity = rootEntity
    self.seasonNumber = seasonNumber
    self.episodeNumber = episodeNumber
    self.matchMethod = matchMethod
    self.confidence = confidence
    self.matchedQueryJSON = matchedQueryJSON
    self.locked = locked
    self.canReplaceLockedBinding = canReplaceLockedBinding
  }
}

package struct LibraryExtraBindingRequest: Sendable {
  package let sourceUID: String
  package let mediaRelativePath: String
  package let parentEntityUID: String
  package let title: String
  package let matchMethod: String
  package let confidence: Double
  package let locked: Bool

  package init(
    sourceUID: String,
    mediaRelativePath: String,
    parentEntityUID: String,
    title: String,
    matchMethod: String,
    confidence: Double,
    locked: Bool
  ) throws {
    let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sourceUID.isEmpty, !sourceUID.contains("\0"),
      !mediaRelativePath.isEmpty, !mediaRelativePath.contains("\0"),
      !parentEntityUID.isEmpty, !parentEntityUID.contains("\0"),
      !normalizedTitle.isEmpty, !normalizedTitle.contains("\0"),
      ["manual", "inherited"].contains(matchMethod), confidence.isFinite,
      (0...1).contains(confidence), matchMethod != "manual" || locked
    else {
      throw SDKError(code: .invalidConfiguration, message: "extra binding request is invalid")
    }
    self.sourceUID = sourceUID
    self.mediaRelativePath = mediaRelativePath
    self.parentEntityUID = parentEntityUID
    self.title = normalizedTitle
    self.matchMethod = matchMethod
    self.confidence = confidence
    self.locked = locked
  }
}

package struct LibraryFileBindingSnapshot: Equatable, Sendable {
  package let fileUID: String
  package let entityUID: String
  package let entityKind: String
  package let canonicalTitle: String
  package let bindingRole: String
  package let matchMethod: String
  package let confidence: Double
  package let isLocked: Bool
}

package enum LibraryMatchCommitResult: Equatable, Sendable {
  case committed(LibraryFileBindingSnapshot)
  case lockedBindingPreserved(LibraryFileBindingSnapshot)
}

extension LibraryStore {
  package func mediaFileUID(
    sourceUID: String,
    mediaRelativePath: String
  ) async throws -> String {
    do {
      guard
        let uid = try await database.read({ database in
          try String.fetchOne(
            database,
            sql: """
              SELECT f.uid
              FROM media_file f
              JOIN library_source s ON s.id = f.source_id
              WHERE s.uid = ? AND f.relative_path = ? AND f.deleted_at_ms IS NULL
              """,
            arguments: [sourceUID, mediaRelativePath]
          )
        })
      else {
        throw SDKError(code: .metadataNotFound, message: "scanned media file was not found")
      }
      return uid
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "media file identity read failed")
    }
  }

  package func matchBinding(
    sourceUID: String,
    mediaRelativePath: String
  ) async throws -> LibraryFileBindingSnapshot? {
    do {
      return try await database.read { database in
        guard
          let file = try Row.fetchOne(
            database,
            sql: """
              SELECT f.id, f.uid
              FROM media_file f
              JOIN library_source s ON s.id = f.source_id
              WHERE s.uid = ? AND f.relative_path = ? AND f.deleted_at_ms IS NULL
              """,
            arguments: [sourceUID, mediaRelativePath]
          )
        else { return nil }
        let mediaFileID: Int64 = file["id"]
        let fileUID: String = file["uid"]
        return try Self.readIdentityBinding(
          mediaFileID: mediaFileID,
          fileUID: fileUID,
          onlyLocked: false,
          database: database
        )
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "file binding read failed")
    }
  }

  package func extraBinding(
    sourceUID: String,
    mediaRelativePath: String
  ) async throws -> LibraryFileBindingSnapshot? {
    do {
      return try await database.read { database in
        guard
          let file = try Row.fetchOne(
            database,
            sql: """
              SELECT f.id, f.uid
              FROM media_file f
              JOIN library_source s ON s.id = f.source_id
              WHERE s.uid = ? AND f.relative_path = ? AND f.deleted_at_ms IS NULL
              """,
            arguments: [sourceUID, mediaRelativePath]
          )
        else { return nil }
        return try Self.readExtraBinding(
          mediaFileID: file["id"],
          fileUID: file["uid"],
          database: database
        )
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "extra binding read failed")
    }
  }

  package func commitMatchBinding(_ request: LibraryFileBindingRequest) async throws
    -> LibraryMatchCommitResult
  {
    let now = clock.nowMilliseconds()
    let generatedRootUID = uuidGenerator.makeUUID().uuidString.lowercased()
    let generatedSeasonUID = uuidGenerator.makeUUID().uuidString.lowercased()
    let generatedEpisodeUID = uuidGenerator.makeUUID().uuidString.lowercased()
    do {
      return try await database.write { database in
        guard
          let file = try Row.fetchOne(
            database,
            sql: """
              SELECT f.id, f.uid
              FROM media_file f
              JOIN library_source s ON s.id = f.source_id
              WHERE s.uid = ? AND f.relative_path = ? AND f.deleted_at_ms IS NULL
              """,
            arguments: [request.sourceUID, request.mediaRelativePath]
          )
        else {
          throw SDKError(code: .metadataNotFound, message: "scanned media file was not found")
        }
        let mediaFileID: Int64 = file["id"]
        let fileUID: String = file["uid"]
        if !request.canReplaceLockedBinding,
          let locked = try Self.readIdentityBinding(
            mediaFileID: mediaFileID,
            fileUID: fileUID,
            onlyLocked: true,
            database: database
          )
        {
          return .lockedBindingPreserved(locked)
        }

        let rootEntityID = try Self.resolveRootEntity(
          request.rootEntity,
          generatedUID: generatedRootUID,
          now: now,
          database: database
        )
        let entityID: Int64
        if let seasonNumber = request.seasonNumber,
          let episodeNumber = request.episodeNumber
        {
          let seasonID = try Self.resolveSeason(
            parentID: rootEntityID,
            seasonNumber: seasonNumber,
            generatedUID: generatedSeasonUID,
            now: now,
            database: database
          )
          entityID = try Self.resolveEpisode(
            parentID: seasonID,
            episodeNumber: episodeNumber,
            generatedUID: generatedEpisodeUID,
            now: now,
            database: database
          )
        } else {
          entityID = rootEntityID
        }

        let otherBindingCount =
          try Int.fetchOne(
            database,
            sql: "SELECT COUNT(*) FROM file_binding WHERE entity_id = ? AND media_file_id <> ?",
            arguments: [entityID, mediaFileID]
          ) ?? 0
        let bindingRole = otherBindingCount == 0 ? "primary" : "version"
        try database.execute(
          sql: """
            DELETE FROM file_binding
            WHERE media_file_id = ? AND binding_role IN ('primary', 'version')
            """,
          arguments: [mediaFileID]
        )
        try database.execute(
          sql: """
            INSERT INTO file_binding(
              media_file_id, entity_id, binding_role, match_method, confidence,
              matched_query, locked, decided_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(media_file_id, entity_id) DO UPDATE SET
              binding_role = excluded.binding_role,
              match_method = excluded.match_method,
              confidence = excluded.confidence,
              matched_query = excluded.matched_query,
              locked = excluded.locked,
              decided_at_ms = excluded.decided_at_ms
            """,
          arguments: [
            mediaFileID, entityID, bindingRole, request.matchMethod, request.confidence,
            request.matchedQueryJSON, request.locked ? 1 : 0, now,
          ]
        )
        try Self.reactivateEntityHierarchy(entityID: entityID, now: now, database: database)
        guard
          let snapshot = try Self.readIdentityBinding(
            mediaFileID: mediaFileID,
            fileUID: fileUID,
            onlyLocked: false,
            database: database
          )
        else {
          throw SDKError(code: .storageFailure, message: "file binding was not persisted")
        }
        return .committed(snapshot)
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "file binding transaction failed")
    }
  }

  package func commitExtraBinding(_ request: LibraryExtraBindingRequest) async throws
    -> LibraryFileBindingSnapshot
  {
    let now = clock.nowMilliseconds()
    let generatedUID = uuidGenerator.makeUUID().uuidString.lowercased()
    do {
      return try await database.write { database in
        guard
          let file = try Row.fetchOne(
            database,
            sql: """
              SELECT f.id, f.uid
              FROM media_file f
              JOIN library_source s ON s.id = f.source_id
              WHERE s.uid = ? AND f.relative_path = ? AND f.deleted_at_ms IS NULL
              """,
            arguments: [request.sourceUID, request.mediaRelativePath]
          ),
          let parent = try Row.fetchOne(
            database,
            sql: """
              SELECT id, kind FROM media_entity
              WHERE uid = ? AND status = 'active' AND deleted_at_ms IS NULL
              """,
            arguments: [request.parentEntityUID]
          )
        else {
          throw SDKError(code: .metadataNotFound, message: "extra file or parent was not found")
        }
        let parentKind: String = parent["kind"]
        guard ["movie", "series"].contains(parentKind) else {
          throw SDKError(
            code: .invalidConfiguration, message: "extra parent must be movie or series")
        }
        let mediaFileID: Int64 = file["id"]
        let fileUID: String = file["uid"]
        let parentID: Int64 = parent["id"]

        if let existing = try Row.fetchOne(
          database,
          sql: """
            SELECT e.id, b.locked
            FROM file_binding b
            JOIN media_entity e ON e.id = b.entity_id
            WHERE b.media_file_id = ? AND b.binding_role = 'extra'
              AND e.parent_id = ? AND e.kind = 'extra' AND e.deleted_at_ms IS NULL
            ORDER BY b.locked DESC, e.uid
            LIMIT 1
            """,
          arguments: [mediaFileID, parentID]
        ) {
          let entityID: Int64 = existing["id"]
          let existingLocked = (existing["locked"] as Int) == 1
          try Self.reactivateEntityHierarchy(entityID: entityID, now: now, database: database)
          if !existingLocked || request.locked {
            try database.execute(
              sql: """
                UPDATE media_entity SET
                  canonical_title = ?, sort_title = ?,
                  metadata_state = CASE WHEN ? = 1 THEN 'manual' ELSE metadata_state END,
                  orphaned_at_ms = NULL, gc_marked_at_ms = NULL,
                  updated_at_ms = ?
                WHERE id = ?
                """,
              arguments: [request.title, request.title, request.locked ? 1 : 0, now, entityID]
            )
            try database.execute(
              sql: """
                UPDATE file_binding SET
                  match_method = ?, confidence = ?, locked = MAX(locked, ?), decided_at_ms = ?
                WHERE media_file_id = ? AND entity_id = ?
                """,
              arguments: [
                request.matchMethod, request.confidence, request.locked ? 1 : 0, now,
                mediaFileID, entityID,
              ]
            )
          }
          guard
            let snapshot = try Self.readExtraBinding(
              mediaFileID: mediaFileID,
              fileUID: fileUID,
              database: database
            )
          else {
            throw SDKError(code: .storageFailure, message: "extra binding was not persisted")
          }
          return snapshot
        }

        let lockedCount =
          try Int.fetchOne(
            database,
            sql: "SELECT COUNT(*) FROM file_binding WHERE media_file_id = ? AND locked = 1",
            arguments: [mediaFileID]
          ) ?? 0
        guard lockedCount == 0 else {
          throw SDKError(code: .conflict, message: "locked binding prevents extra classification")
        }
        let obsoleteExtraIDs = try Int64.fetchAll(
          database,
          sql: """
            SELECT e.id
            FROM file_binding b
            JOIN media_entity e ON e.id = b.entity_id
            WHERE b.media_file_id = ? AND b.binding_role = 'extra' AND e.kind = 'extra'
            """,
          arguments: [mediaFileID]
        )
        try database.execute(
          sql: "DELETE FROM file_binding WHERE media_file_id = ?",
          arguments: [mediaFileID]
        )
        for entityID in obsoleteExtraIDs {
          try database.execute(
            sql: "UPDATE media_entity SET status = 'obsolete', updated_at_ms = ? WHERE id = ?",
            arguments: [now, entityID]
          )
        }
        try database.execute(
          sql: """
            INSERT INTO media_entity(
              uid, kind, parent_id, canonical_title, sort_title, status, metadata_state,
              created_at_ms, updated_at_ms
            ) VALUES (?, 'extra', ?, ?, ?, 'active', ?, ?, ?)
            """,
          arguments: [
            generatedUID, parentID, request.title, request.title,
            request.locked ? "manual" : "partial", now, now,
          ]
        )
        let entityID = database.lastInsertedRowID
        try database.execute(
          sql: """
            INSERT INTO file_binding(
              media_file_id, entity_id, binding_role, match_method, confidence,
              matched_query, locked, decided_at_ms
            ) VALUES (?, ?, 'extra', ?, ?, '{}', ?, ?)
            """,
          arguments: [
            mediaFileID, entityID, request.matchMethod, request.confidence,
            request.locked ? 1 : 0, now,
          ]
        )
        try Self.reactivateEntityHierarchy(entityID: entityID, now: now, database: database)
        guard
          let snapshot = try Self.readExtraBinding(
            mediaFileID: mediaFileID,
            fileUID: fileUID,
            database: database
          )
        else {
          throw SDKError(code: .storageFailure, message: "extra binding was not persisted")
        }
        return snapshot
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "extra binding transaction failed")
    }
  }

  private static func resolveRootEntity(
    _ record: LibraryMatchRootEntityRecord,
    generatedUID: String,
    now: Int64,
    database: Database
  ) throws -> Int64 {
    var matchedEntityIDs: Set<Int64> = []
    for identifier in record.externalIDs {
      if let entityID = try Int64.fetchOne(
        database,
        sql: """
          SELECT entity_id FROM external_id
          WHERE provider = ? AND namespace = ? AND external_value = ?
          """,
        arguments: [identifier.provider, identifier.namespace, identifier.value]
      ) {
        matchedEntityIDs.insert(entityID)
      }
    }
    guard matchedEntityIDs.count <= 1 else {
      throw SDKError(code: .storageFailure, message: "provider identity maps to multiple entities")
    }

    let entityID: Int64
    if let existingID = matchedEntityIDs.first {
      guard
        let existing = try Row.fetchOne(
          database,
          sql: "SELECT kind, status FROM media_entity WHERE id = ? AND deleted_at_ms IS NULL",
          arguments: [existingID]
        )
      else {
        throw SDKError(code: .storageFailure, message: "matched entity is unavailable")
      }
      let existingKind: String = existing["kind"]
      let existingStatus: String = existing["status"]
      guard existingKind == record.kind, existingStatus != "deleted" else {
        throw SDKError(code: .storageFailure, message: "provider identity kind is inconsistent")
      }
      entityID = existingID
      try database.execute(
        sql: """
          UPDATE media_entity SET
            canonical_title = CASE
              WHEN metadata_state = 'manual' OR locked_fields_json IS NOT NULL
              THEN canonical_title ELSE ? END,
            original_title = CASE
              WHEN metadata_state = 'manual' OR locked_fields_json IS NOT NULL
              THEN original_title ELSE ? END,
            year = CASE
              WHEN metadata_state = 'manual' OR locked_fields_json IS NOT NULL
              THEN year ELSE ? END,
            status = 'active',
            orphaned_at_ms = NULL,
            gc_marked_at_ms = NULL,
            updated_at_ms = ?
          WHERE id = ?
          """,
        arguments: [record.canonicalTitle, record.originalTitle, record.year, now, entityID]
      )
    } else {
      try database.execute(
        sql: """
          INSERT INTO media_entity(
            uid, kind, canonical_title, original_title, sort_title, year,
            status, metadata_state, created_at_ms, updated_at_ms
          ) VALUES (?, ?, ?, ?, ?, ?, 'active', 'partial', ?, ?)
          """,
        arguments: [
          generatedUID, record.kind, record.canonicalTitle, record.originalTitle,
          record.canonicalTitle, record.year, now, now,
        ]
      )
      entityID = database.lastInsertedRowID
    }

    for identifier in record.externalIDs {
      if let existingValue = try String.fetchOne(
        database,
        sql: """
          SELECT external_value FROM external_id
          WHERE entity_id = ? AND provider = ? AND namespace = ?
          """,
        arguments: [entityID, identifier.provider, identifier.namespace]
      ), existingValue != identifier.value {
        throw SDKError(code: .storageFailure, message: "provider identity cannot be replaced")
      }
      try database.execute(
        sql: """
          INSERT INTO external_id(
            entity_id, provider, namespace, external_value, is_primary, updated_at_ms
          ) VALUES (?, ?, ?, ?, ?, ?)
          ON CONFLICT(entity_id, provider, namespace) DO UPDATE SET
            is_primary = MAX(external_id.is_primary, excluded.is_primary),
            updated_at_ms = excluded.updated_at_ms
          """,
        arguments: [
          entityID, identifier.provider, identifier.namespace, identifier.value,
          identifier.isPrimary ? 1 : 0, now,
        ]
      )
    }
    return entityID
  }

  private static func resolveSeason(
    parentID: Int64,
    seasonNumber: Int,
    generatedUID: String,
    now: Int64,
    database: Database
  ) throws -> Int64 {
    if let existing = try Int64.fetchOne(
      database,
      sql: """
        SELECT id FROM media_entity
        WHERE parent_id = ? AND kind = 'season' AND season_number = ?
          AND deleted_at_ms IS NULL
        """,
      arguments: [parentID, seasonNumber]
    ) {
      try reactivateEntityHierarchy(entityID: existing, now: now, database: database)
      return existing
    }
    let title = "Season \(seasonNumber)"
    try database.execute(
      sql: """
        INSERT INTO media_entity(
          uid, kind, parent_id, canonical_title, sort_title, season_number,
          status, metadata_state, created_at_ms, updated_at_ms
        ) VALUES (?, 'season', ?, ?, ?, ?, 'active', 'none', ?, ?)
        """,
      arguments: [generatedUID, parentID, title, title, seasonNumber, now, now]
    )
    return database.lastInsertedRowID
  }

  private static func resolveEpisode(
    parentID: Int64,
    episodeNumber: Int,
    generatedUID: String,
    now: Int64,
    database: Database
  ) throws -> Int64 {
    if let existing = try Int64.fetchOne(
      database,
      sql: """
        SELECT id FROM media_entity
        WHERE parent_id = ? AND kind = 'episode' AND episode_number = ?
          AND deleted_at_ms IS NULL
        """,
      arguments: [parentID, episodeNumber]
    ) {
      try reactivateEntityHierarchy(entityID: existing, now: now, database: database)
      return existing
    }
    let title = "Episode \(episodeNumber)"
    try database.execute(
      sql: """
        INSERT INTO media_entity(
          uid, kind, parent_id, canonical_title, sort_title, episode_number,
          status, metadata_state, created_at_ms, updated_at_ms
        ) VALUES (?, 'episode', ?, ?, ?, ?, 'active', 'none', ?, ?)
        """,
      arguments: [generatedUID, parentID, title, title, episodeNumber, now, now]
    )
    return database.lastInsertedRowID
  }

  private static func readIdentityBinding(
    mediaFileID: Int64,
    fileUID: String,
    onlyLocked: Bool,
    database: Database
  ) throws -> LibraryFileBindingSnapshot? {
    let row = try Row.fetchOne(
      database,
      sql: """
        SELECT e.uid AS entity_uid, e.kind AS entity_kind, e.canonical_title,
               b.binding_role, b.match_method, b.confidence, b.locked
        FROM file_binding b
        JOIN media_entity e ON e.id = b.entity_id
        WHERE b.media_file_id = ?
          AND b.binding_role IN ('primary', 'version')
          AND (? = 0 OR b.locked = 1)
        ORDER BY b.locked DESC,
                 CASE b.binding_role WHEN 'primary' THEN 0 ELSE 1 END,
                 e.uid
        LIMIT 1
        """,
      arguments: [mediaFileID, onlyLocked ? 1 : 0]
    )
    guard let row else { return nil }
    return LibraryFileBindingSnapshot(
      fileUID: fileUID,
      entityUID: row["entity_uid"],
      entityKind: row["entity_kind"],
      canonicalTitle: row["canonical_title"],
      bindingRole: row["binding_role"],
      matchMethod: row["match_method"],
      confidence: row["confidence"],
      isLocked: (row["locked"] as Int) == 1
    )
  }

  private static func readExtraBinding(
    mediaFileID: Int64,
    fileUID: String,
    database: Database
  ) throws -> LibraryFileBindingSnapshot? {
    let row = try Row.fetchOne(
      database,
      sql: """
        SELECT e.uid AS entity_uid, e.kind AS entity_kind, e.canonical_title,
               b.binding_role, b.match_method, b.confidence, b.locked
        FROM file_binding b
        JOIN media_entity e ON e.id = b.entity_id
        WHERE b.media_file_id = ? AND b.binding_role = 'extra'
          AND e.kind = 'extra' AND e.status = 'active' AND e.deleted_at_ms IS NULL
        ORDER BY b.locked DESC, e.uid
        LIMIT 1
        """,
      arguments: [mediaFileID]
    )
    guard let row else { return nil }
    return LibraryFileBindingSnapshot(
      fileUID: fileUID,
      entityUID: row["entity_uid"],
      entityKind: row["entity_kind"],
      canonicalTitle: row["canonical_title"],
      bindingRole: row["binding_role"],
      matchMethod: row["match_method"],
      confidence: row["confidence"],
      isLocked: (row["locked"] as Int) == 1
    )
  }
}

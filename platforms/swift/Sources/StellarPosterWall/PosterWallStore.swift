import Foundation
import GRDB
import StellarCore
import StellarStorage

/// GRDB-backed PosterWall list, search, pagination, and detail queries.
public struct PosterWallStore: Sendable {
  public let database: StorageDatabase

  public init(database: StorageDatabase) throws {
    guard database.kind == .library else {
      throw SDKError(
        code: .invalidConfiguration, message: "PosterWallStore requires library.sqlite")
    }
    self.database = database
  }

  /// Returns one deterministic page and rejects cursors from a different library revision or query.
  public func page(_ query: PosterWallQuery) async throws -> PosterWallPage {
    do {
      return try await database.read { database in
        let revision = try Self.libraryRevision(database)
        guard query.libraryRevision == nil || query.libraryRevision == revision else {
          throw SDKError(code: .conflict, message: "PosterWall library revision changed")
        }
        let identity = try Self.queryIdentity(query)
        let cursor = try query.cursor.map(Self.decodeCursor)
        guard
          cursor == nil
            || (cursor?.libraryRevision == revision && cursor?.queryIdentity == identity)
        else {
          throw SDKError(code: .conflict, message: "PosterWall cursor is stale or incompatible")
        }

        var roots = try Self.loadRoots(
          locale: query.locale,
          profileUID: query.profileUID,
          database: database
        )
        roots = Self.filter(roots, query: query)
        roots.sort { Self.isOrderedBefore($0, $1, query: query) }

        let startIndex: Int
        if let cursor {
          guard let index = roots.firstIndex(where: { $0.item.mediaUID == cursor.lastMediaUID })
          else {
            throw SDKError(code: .conflict, message: "PosterWall cursor anchor is unavailable")
          }
          startIndex = roots.index(after: index)
        } else {
          startIndex = roots.startIndex
        }
        let endIndex = min(roots.count, startIndex + query.pageSize)
        let selected = startIndex < roots.count ? Array(roots[startIndex..<endIndex]) : []
        let nextCursor: String?
        if endIndex < roots.count, let last = selected.last {
          nextCursor = try Self.encodeCursor(
            PosterWallCursor(
              libraryRevision: revision,
              queryIdentity: identity,
              lastMediaUID: last.item.mediaUID
            )
          )
        } else {
          nextCursor = nil
        }
        return PosterWallPage(
          schemaVersion: 1,
          libraryRevision: revision,
          items: selected.map(\.item),
          nextCursor: nextCursor
        )
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "PosterWall page query failed")
    }
  }

  /// Returns logical media, artwork, playable versions, technical streams, and series hierarchy.
  public func details(
    mediaUID: String,
    profileUID: String? = nil,
    locale: String = "und"
  ) async throws -> PosterWallDetails {
    guard !mediaUID.isEmpty, !mediaUID.contains("\0"),
      profileUID?.isEmpty != true, profileUID?.contains("\0") != true,
      !locale.isEmpty, !locale.contains("\0")
    else {
      throw SDKError(code: .invalidConfiguration, message: "PosterWall details request is invalid")
    }
    do {
      return try await database.read { database in
        let revision = try Self.libraryRevision(database)
        let roots = try Self.loadRoots(
          locale: locale,
          profileUID: profileUID,
          database: database
        )
        guard let root = roots.first(where: { $0.item.mediaUID == mediaUID }) else {
          throw SDKError(code: .metadataNotFound, message: "PosterWall media was not found")
        }
        let metadata = try Self.localizedDetails(
          entityID: root.entityID,
          locale: locale,
          database: database
        )
        let externalIDs = try Row.fetchAll(
          database,
          sql: """
            SELECT provider, namespace, external_value
            FROM external_id
            WHERE entity_id = ?
            ORDER BY is_primary DESC, provider, namespace, external_value
            """,
          arguments: [root.entityID]
        ).map { row in
          PosterWallExternalID(
            provider: row["provider"],
            namespace: row["namespace"],
            value: row["external_value"]
          )
        }
        let artwork = try Self.artwork(entityID: root.entityID, database: database)
        let fileRecords = try Self.files(rootEntityID: root.entityID, database: database)
        let streams = try Self.streams(
          fileIDs: fileRecords.map(\.fileID),
          database: database
        )
        let filesByEntity = Dictionary(grouping: fileRecords, by: \.boundEntityID)
        let rootFiles = fileRecords.filter { record in
          record.boundEntityID == root.entityID || record.boundKind == "extra"
        }.map { record in
          Self.makePlayableFile(record, streams: streams[record.fileID] ?? [])
        }
        let seasons = try Self.seasons(
          rootEntityID: root.entityID,
          profileUID: profileUID,
          filesByEntity: filesByEntity,
          streams: streams,
          database: database
        )
        return PosterWallDetails(
          schemaVersion: 1,
          libraryRevision: revision,
          item: root.item,
          originalTitle: root.originalTitle,
          overview: metadata.overview,
          tagline: metadata.tagline,
          contentRating: metadata.contentRating,
          genres: root.genres.sorted(),
          externalIDs: externalIDs,
          artwork: artwork,
          playableFiles: rootFiles,
          seasons: seasons
        )
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "PosterWall details query failed")
    }
  }

  private static func libraryRevision(_ database: Database) throws -> String {
    var hash = UInt64(14_695_981_039_346_656_037)
    for sql in revisionQueries {
      for value in try String.fetchAll(database, sql: sql) {
        for byte in value.utf8 {
          hash ^= UInt64(byte)
          hash &*= 1_099_511_628_211
        }
        hash ^= 0xff
        hash &*= 1_099_511_628_211
      }
    }
    return "v1-" + String(hash, radix: 16, uppercase: false).leftPadding(toLength: 16, with: "0")
  }

  private static func loadRoots(
    locale: String,
    profileUID: String?,
    database: Database
  ) throws -> [RootProjection] {
    let rows = try Row.fetchAll(
      database,
      sql: """
        SELECT e.id, e.uid, e.kind, e.original_title, e.year, e.release_date,
               e.created_at_ms, e.updated_at_ms,
               COALESCE(
                 (SELECT lm.title FROM localized_metadata lm
                  WHERE lm.entity_id = e.id AND lm.locale = ?),
                 (SELECT lm.title FROM localized_metadata lm
                  WHERE lm.entity_id = e.id AND lm.locale = 'und'),
                 e.canonical_title
               ) AS display_title,
               COALESCE(sd.title, '') || ' ' || COALESCE(sd.aliases, '') || ' '
                 || COALESCE(sd.people, '') || ' ' || COALESCE(sd.genres, '') || ' '
                 || COALESCE(sd.romanized, '') AS search_text
        FROM media_entity e
        LEFT JOIN search_document sd ON sd.entity_id = e.id
        WHERE e.kind IN ('movie', 'series')
          AND e.status = 'active' AND e.deleted_at_ms IS NULL
        ORDER BY e.uid
        """,
      arguments: [locale]
    )
    var roots = rows.map { row in
      let kindValue: String = row["kind"]
      return RootProjection(
        entityID: row["id"],
        item: PosterWallItem(
          mediaUID: row["uid"],
          kind: kindValue == "movie" ? .movie : .series,
          title: row["display_title"],
          subtitle: nil,
          year: row["year"],
          poster: nil,
          backdrop: nil,
          progress: nil,
          unwatchedEpisodeCount: nil,
          availability: .unavailable,
          metadataRevision: row["updated_at_ms"]
        ),
        originalTitle: row["original_title"],
        releaseDate: row["release_date"],
        addedAtMilliseconds: row["created_at_ms"],
        lastPlayedAtMilliseconds: nil,
        sourceUIDs: [],
        genres: [],
        collectionUIDs: [],
        searchText: row["search_text"],
        hasPlaybackState: false,
        isCompleted: false,
        totalEpisodeCount: 0
      )
    }
    var rootIndex = Dictionary(uniqueKeysWithValues: roots.indices.map { (roots[$0].entityID, $0) })

    let fileRows = try Row.fetchAll(database, sql: rootFileSQL)
    var availabilityByRoot: [Int64: [String]] = [:]
    for row in fileRows {
      let rootID: Int64 = row["root_id"]
      guard let index = rootIndex[rootID] else { continue }
      let sourceUID: String = row["source_uid"]
      roots[index].sourceUIDs.insert(sourceUID)
      let availability: String = row["availability"]
      availabilityByRoot[rootID, default: []].append(availability)
    }
    for (rootID, values) in availabilityByRoot {
      guard let index = rootIndex[rootID] else { continue }
      roots[index].item = replacing(
        roots[index].item,
        availability: aggregateAvailability(values)
      )
    }

    let genreRows = try Row.fetchAll(
      database,
      sql: """
        SELECT eg.entity_id, gn.name
        FROM entity_genre eg
        JOIN genre_name gn ON gn.genre_id = eg.genre_id
        WHERE gn.locale = ? OR gn.locale = 'und'
        ORDER BY eg.entity_id, CASE WHEN gn.locale = ? THEN 0 ELSE 1 END, eg.position, gn.name
        """,
      arguments: [locale, locale]
    )
    for row in genreRows {
      let entityID: Int64 = row["entity_id"]
      guard let index = rootIndex[entityID] else { continue }
      roots[index].genres.insert(row["name"])
    }

    let collectionRows = try Row.fetchAll(
      database,
      sql: """
        SELECT ci.entity_id, c.uid
        FROM collection_item ci
        JOIN media_collection c ON c.id = ci.collection_id
        WHERE c.deleted_at_ms IS NULL
        ORDER BY ci.entity_id, c.uid
        """
    )
    for row in collectionRows {
      let entityID: Int64 = row["entity_id"]
      guard let index = rootIndex[entityID] else { continue }
      roots[index].collectionUIDs.insert(row["uid"])
    }

    let artworkRows = try Row.fetchAll(
      database,
      sql: """
        SELECT entity_id, uid, kind, locale, provider, remote_url, local_relative_path,
               width, height, score, is_selected
        FROM artwork
        ORDER BY entity_id, kind, uid
        """
    )
    let groupedArtwork = Dictionary(grouping: artworkRows) { row -> Int64 in row["entity_id"] }
    for (entityID, candidates) in groupedArtwork {
      guard let index = rootIndex[entityID] else { continue }
      let poster = selectArtwork(kind: "poster", locale: locale, rows: candidates)
      let backdrop = selectArtwork(kind: "backdrop", locale: locale, rows: candidates)
      roots[index].item = replacing(roots[index].item, poster: poster, backdrop: backdrop)
    }

    if let profileUID {
      let playbackRows = try Row.fetchAll(
        database,
        sql: rootPlaybackSQL,
        arguments: [profileUID]
      )
      var playbackByRoot: [Int64: [PlaybackProjection]] = [:]
      for row in playbackRows {
        let rootID: Int64 = row["root_id"]
        playbackByRoot[rootID, default: []].append(
          PlaybackProjection(
            positionMilliseconds: row["position_ms"],
            durationMilliseconds: row["duration_ms"],
            isCompleted: (row["completed"] as Int) == 1,
            lastPlayedAtMilliseconds: row["last_played_at_ms"]
          )
        )
      }
      let episodeRows = try Row.fetchAll(
        database,
        sql: """
          SELECT series.id AS root_id, COUNT(episode.id) AS episode_count,
                 SUM(CASE WHEN ps.completed = 1 THEN 0 ELSE 1 END) AS unwatched_count
          FROM media_entity series
          JOIN media_entity season ON season.parent_id = series.id AND season.kind = 'season'
          JOIN media_entity episode ON episode.parent_id = season.id AND episode.kind = 'episode'
          LEFT JOIN playback_profile profile ON profile.uid = ?
          LEFT JOIN playback_state ps
            ON ps.profile_id = profile.id AND ps.entity_id = episode.id
          WHERE series.kind = 'series' AND series.deleted_at_ms IS NULL
            AND season.deleted_at_ms IS NULL AND episode.deleted_at_ms IS NULL
          GROUP BY series.id
          """,
        arguments: [profileUID]
      )
      for row in episodeRows {
        let rootID: Int64 = row["root_id"]
        guard let index = rootIndex[rootID] else { continue }
        let episodeCount: Int = row["episode_count"]
        let unwatchedCount: Int = row["unwatched_count"]
        roots[index].totalEpisodeCount = episodeCount
        roots[index].isCompleted = episodeCount > 0 && unwatchedCount == 0
        roots[index].item = replacing(
          roots[index].item,
          unwatchedEpisodeCount: unwatchedCount
        )
      }
      for (rootID, values) in playbackByRoot {
        guard let index = rootIndex[rootID] else { continue }
        roots[index].hasPlaybackState = true
        roots[index].lastPlayedAtMilliseconds = values.compactMap(\.lastPlayedAtMilliseconds).max()
        if roots[index].item.kind == .movie {
          roots[index].isCompleted = values.contains(where: \.isCompleted)
        }
        let resumable = values.filter {
          !$0.isCompleted && $0.positionMilliseconds > 0 && ($0.durationMilliseconds ?? 0) > 0
        }.sorted {
          ($0.lastPlayedAtMilliseconds ?? 0) > ($1.lastPlayedAtMilliseconds ?? 0)
        }.first
        let progress = resumable.flatMap { value -> Double? in
          guard let duration = value.durationMilliseconds, duration > 0 else { return nil }
          return roundedProgress(Double(value.positionMilliseconds) / Double(duration))
        }
        roots[index].item = replacing(roots[index].item, progress: progress)
      }
    }

    rootIndex.removeAll(keepingCapacity: false)
    return roots
  }

  private static func filter(_ roots: [RootProjection], query: PosterWallQuery)
    -> [RootProjection]
  {
    roots.filter { root in
      switch query.section {
      case .movies where root.item.kind != .movie:
        return false
      case .series where root.item.kind != .series:
        return false
      case .continueWatching where root.item.progress == nil:
        return false
      case .recentlyPlayed where root.lastPlayedAtMilliseconds == nil:
        return false
      case .collection where !root.collectionUIDs.contains(query.collectionUID ?? ""):
        return false
      default:
        break
      }
      if !query.filter.mediaKinds.isEmpty,
        !query.filter.mediaKinds.contains(root.item.kind)
      {
        return false
      }
      if !query.filter.sourceUIDs.isEmpty,
        root.sourceUIDs.isDisjoint(with: query.filter.sourceUIDs)
      {
        return false
      }
      if !query.filter.genres.isEmpty {
        let available = Set(root.genres.map(normalizeText))
        let requested = Set(query.filter.genres.map(normalizeText))
        if !requested.isSubset(of: available) { return false }
      }
      if let yearFrom = query.filter.yearFrom, (root.item.year ?? Int.min) < yearFrom {
        return false
      }
      if let yearThrough = query.filter.yearThrough, (root.item.year ?? Int.max) > yearThrough {
        return false
      }
      switch query.filter.availability {
      case .present where root.item.availability != .present:
        return false
      case .unavailable where root.item.availability == .present:
        return false
      default:
        break
      }
      switch query.filter.watchState {
      case .unwatched where root.hasPlaybackState:
        return false
      case .inProgress where root.item.progress == nil:
        return false
      case .completed where !root.isCompleted:
        return false
      default:
        break
      }
      if let searchText = query.searchText {
        let needle = normalizeText(searchText)
        let haystack = normalizeText(
          [
            root.item.title, root.originalTitle, root.searchText,
            root.genres.sorted().joined(separator: " "),
          ]
          .compactMap { $0 }.joined(separator: " ")
        )
        if !haystack.contains(needle) { return false }
      }
      return true
    }
  }

  private static func isOrderedBefore(
    _ lhs: RootProjection,
    _ rhs: RootProjection,
    query: PosterWallQuery
  ) -> Bool {
    let sort: PosterWallSort
    switch query.section {
    case .recentlyAdded:
      sort = .addedAt
    case .continueWatching, .recentlyPlayed:
      sort = .recentlyPlayed
    default:
      sort = query.sort
    }
    switch sort {
    case .addedAt:
      if lhs.addedAtMilliseconds != rhs.addedAtMilliseconds {
        return lhs.addedAtMilliseconds > rhs.addedAtMilliseconds
      }
    case .releaseDate:
      if lhs.releaseDate != rhs.releaseDate {
        return (lhs.releaseDate ?? "") > (rhs.releaseDate ?? "")
      }
    case .recentlyPlayed:
      if lhs.lastPlayedAtMilliseconds != rhs.lastPlayedAtMilliseconds {
        return (lhs.lastPlayedAtMilliseconds ?? Int64.min)
          > (rhs.lastPlayedAtMilliseconds ?? Int64.min)
      }
    case .random:
      let left = stableRandom(mediaUID: lhs.item.mediaUID, seed: query.randomSeed)
      let right = stableRandom(mediaUID: rhs.item.mediaUID, seed: query.randomSeed)
      if left != right { return left < right }
    case .title, .unknown:
      let left = normalizeText(lhs.item.title)
      let right = normalizeText(rhs.item.title)
      if left != right { return left < right }
    }
    return lhs.item.mediaUID < rhs.item.mediaUID
  }

  private static func queryIdentity(_ query: PosterWallQuery) throws -> String {
    let identity = PosterWallQueryIdentity(
      section: query.section,
      sort: query.sort,
      filter: query.filter,
      searchText: query.searchText,
      profileUID: query.profileUID,
      collectionUID: query.collectionUID,
      locale: query.locale,
      randomSeed: query.randomSeed
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return base64URLEncoded(try encoder.encode(identity))
  }

  private static func encodeCursor(_ cursor: PosterWallCursor) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return base64URLEncoded(try encoder.encode(cursor))
  }

  private static func decodeCursor(_ value: String) throws -> PosterWallCursor {
    guard value.utf8.count <= 16_384, let data = base64URLDecoded(value) else {
      throw SDKError(code: .invalidConfiguration, message: "PosterWall cursor is invalid")
    }
    do {
      return try JSONDecoder().decode(PosterWallCursor.self, from: data)
    } catch {
      throw SDKError(code: .invalidConfiguration, message: "PosterWall cursor is invalid")
    }
  }

  private static func localizedDetails(
    entityID: Int64,
    locale: String,
    database: Database
  ) throws -> LocalizedDetails {
    let row = try Row.fetchOne(
      database,
      sql: """
        SELECT overview, tagline, content_rating
        FROM localized_metadata
        WHERE entity_id = ? AND locale IN (?, 'und')
        ORDER BY CASE WHEN locale = ? THEN 0 ELSE 1 END
        LIMIT 1
        """,
      arguments: [entityID, locale, locale]
    )
    return LocalizedDetails(
      overview: row?["overview"],
      tagline: row?["tagline"],
      contentRating: row?["content_rating"]
    )
  }

  private static func artwork(entityID: Int64, database: Database) throws
    -> [PosterWallArtwork]
  {
    try Row.fetchAll(
      database,
      sql: """
        SELECT uid, kind, provider, remote_url, local_relative_path, width, height
        FROM artwork
        WHERE entity_id = ?
        ORDER BY kind, is_selected DESC, score DESC, uid
        """,
      arguments: [entityID]
    ).map(makeArtwork)
  }

  private static func files(rootEntityID: Int64, database: Database) throws -> [FileRecord] {
    try Row.fetchAll(
      database,
      sql: """
        SELECT f.id AS file_id, f.uid AS file_uid, s.uid AS source_uid, f.relative_path,
               f.availability, f.size_bytes, b.binding_role,
               bound.id AS bound_entity_id, bound.kind AS bound_kind,
               ts.duration_ms, ts.video_codec, ts.width, ts.height
        FROM file_binding b
        JOIN media_file f ON f.id = b.media_file_id
        JOIN library_source s ON s.id = f.source_id
        JOIN media_entity bound ON bound.id = b.entity_id
        LEFT JOIN media_entity parent ON parent.id = bound.parent_id
        LEFT JOIN media_entity grandparent ON grandparent.id = parent.parent_id
        LEFT JOIN technical_summary ts ON ts.media_file_id = f.id
        WHERE CASE
          WHEN bound.kind IN ('movie', 'series') THEN bound.id
          WHEN bound.kind = 'season' THEN bound.parent_id
          WHEN bound.kind = 'episode' THEN parent.parent_id
          WHEN bound.kind = 'extra' AND parent.kind = 'season' THEN parent.parent_id
          WHEN bound.kind = 'extra' THEN bound.parent_id
        END = ?
          AND f.deleted_at_ms IS NULL AND bound.deleted_at_ms IS NULL
        ORDER BY bound.kind, COALESCE(bound.season_number, -1),
                 COALESCE(bound.episode_number, -1), b.binding_role, f.uid
        """,
      arguments: [rootEntityID]
    ).map { row in
      FileRecord(
        fileID: row["file_id"],
        fileUID: row["file_uid"],
        sourceUID: row["source_uid"],
        relativePath: row["relative_path"],
        bindingRole: row["binding_role"],
        availability: row["availability"],
        sizeBytes: row["size_bytes"],
        durationMilliseconds: row["duration_ms"],
        videoCodec: row["video_codec"],
        width: row["width"],
        height: row["height"],
        boundEntityID: row["bound_entity_id"],
        boundKind: row["bound_kind"]
      )
    }
  }

  private static func streams(fileIDs: [Int64], database: Database) throws
    -> [Int64: [PosterWallStream]]
  {
    guard !fileIDs.isEmpty else { return [:] }
    let placeholders = Array(repeating: "?", count: fileIDs.count).joined(separator: ",")
    let rows = try Row.fetchAll(
      database,
      sql: """
        SELECT media_file_id, stream_index, kind, codec, language, title, is_default, is_forced
        FROM media_stream
        WHERE media_file_id IN (\(placeholders))
        ORDER BY media_file_id, stream_index
        """,
      arguments: StatementArguments(fileIDs)
    )
    return Dictionary(grouping: rows) { row -> Int64 in row["media_file_id"] }
      .mapValues { values in
        values.map { row in
          PosterWallStream(
            index: row["stream_index"],
            kind: row["kind"],
            codec: row["codec"],
            language: row["language"],
            title: row["title"],
            isDefault: (row["is_default"] as Int) == 1,
            isForced: (row["is_forced"] as Int) == 1
          )
        }
      }
  }

  private static func seasons(
    rootEntityID: Int64,
    profileUID: String?,
    filesByEntity: [Int64: [FileRecord]],
    streams: [Int64: [PosterWallStream]],
    database: Database
  ) throws -> [PosterWallSeason] {
    let rows = try Row.fetchAll(
      database,
      sql: """
        SELECT season.id AS season_id, season.uid AS season_uid, season.season_number,
               season.canonical_title AS season_title,
               episode.id AS episode_id, episode.uid AS episode_uid,
               episode.episode_number, episode.canonical_title AS episode_title,
               ps.position_ms, ps.duration_ms, ps.completed
        FROM media_entity season
        JOIN media_entity episode ON episode.parent_id = season.id AND episode.kind = 'episode'
        LEFT JOIN playback_profile profile ON profile.uid = ?
        LEFT JOIN playback_state ps
          ON ps.profile_id = profile.id AND ps.entity_id = episode.id
        WHERE season.parent_id = ? AND season.kind = 'season'
          AND season.deleted_at_ms IS NULL AND episode.deleted_at_ms IS NULL
        ORDER BY season.season_number, episode.episode_number, episode.uid
        """,
      arguments: [profileUID, rootEntityID]
    )
    let grouped = Dictionary(grouping: rows) { row -> Int64 in row["season_id"] }
    return grouped.values.map { episodeRows in
      let first = episodeRows[0]
      let episodes = episodeRows.map { row in
        let episodeID: Int64 = row["episode_id"]
        let duration: Int64? = row["duration_ms"]
        let position: Int64? = row["position_ms"]
        let progress: Double?
        if let duration, duration > 0, let position {
          progress = roundedProgress(Double(position) / Double(duration))
        } else {
          progress = nil
        }
        return PosterWallEpisode(
          mediaUID: row["episode_uid"],
          episodeNumber: row["episode_number"],
          title: row["episode_title"],
          progress: progress,
          isCompleted: ((row["completed"] as Int?) ?? 0) == 1,
          files: (filesByEntity[episodeID] ?? []).map { record in
            makePlayableFile(record, streams: streams[record.fileID] ?? [])
          }
        )
      }
      return PosterWallSeason(
        mediaUID: first["season_uid"],
        seasonNumber: first["season_number"],
        title: first["season_title"],
        episodes: episodes
      )
    }.sorted {
      ($0.seasonNumber, $0.mediaUID) < ($1.seasonNumber, $1.mediaUID)
    }
  }

  private static func makePlayableFile(
    _ record: FileRecord,
    streams: [PosterWallStream]
  ) -> PosterWallPlayableFile {
    PosterWallPlayableFile(
      fileUID: record.fileUID,
      sourceUID: record.sourceUID,
      relativePath: record.relativePath,
      bindingRole: record.bindingRole,
      availability: record.availability,
      sizeBytes: record.sizeBytes,
      durationMilliseconds: record.durationMilliseconds,
      videoCodec: record.videoCodec,
      width: record.width,
      height: record.height,
      streams: streams
    )
  }

  private static func selectArtwork(
    kind: String,
    locale: String,
    rows: [Row]
  ) -> PosterWallArtwork? {
    rows.filter { ($0["kind"] as String) == kind }.sorted { lhs, rhs in
      let lhsSelected = (lhs["is_selected"] as Int) == 1
      let rhsSelected = (rhs["is_selected"] as Int) == 1
      if lhsSelected != rhsSelected { return lhsSelected }
      let lhsLocale: String = lhs["locale"]
      let rhsLocale: String = rhs["locale"]
      let lhsLocaleRank = lhsLocale == locale ? 0 : (lhsLocale == "und" ? 1 : 2)
      let rhsLocaleRank = rhsLocale == locale ? 0 : (rhsLocale == "und" ? 1 : 2)
      if lhsLocaleRank != rhsLocaleRank { return lhsLocaleRank < rhsLocaleRank }
      let lhsScore: Double = lhs["score"] ?? 0
      let rhsScore: Double = rhs["score"] ?? 0
      if lhsScore != rhsScore { return lhsScore > rhsScore }
      let lhsArea = Int64(lhs["width"] ?? 0) * Int64(lhs["height"] ?? 0)
      let rhsArea = Int64(rhs["width"] ?? 0) * Int64(rhs["height"] ?? 0)
      if lhsArea != rhsArea { return lhsArea > rhsArea }
      return (lhs["uid"] as String) < (rhs["uid"] as String)
    }.first.map(makeArtwork)
  }

  private static func makeArtwork(_ row: Row) -> PosterWallArtwork {
    PosterWallArtwork(
      artworkUID: row["uid"],
      kind: row["kind"],
      provider: row["provider"],
      remoteReference: row["remote_url"],
      localRelativePath: row["local_relative_path"],
      width: row["width"],
      height: row["height"]
    )
  }

  private static func aggregateAvailability(_ values: [String]) -> PosterWallAvailability {
    if values.contains("present") { return .present }
    if values.contains("offline") { return .offline }
    if values.contains("missing") { return .missing }
    return .unavailable
  }

  private static func replacing(
    _ item: PosterWallItem,
    poster: PosterWallArtwork? = nil,
    backdrop: PosterWallArtwork? = nil,
    progress: Double? = nil,
    unwatchedEpisodeCount: Int? = nil,
    availability: PosterWallAvailability? = nil
  ) -> PosterWallItem {
    PosterWallItem(
      mediaUID: item.mediaUID,
      kind: item.kind,
      title: item.title,
      subtitle: item.subtitle,
      year: item.year,
      poster: poster ?? item.poster,
      backdrop: backdrop ?? item.backdrop,
      progress: progress ?? item.progress,
      unwatchedEpisodeCount: unwatchedEpisodeCount ?? item.unwatchedEpisodeCount,
      availability: availability ?? item.availability,
      metadataRevision: item.metadataRevision
    )
  }

  private static func roundedProgress(_ value: Double) -> Double {
    min(1, max(0, (value * 1_000_000).rounded() / 1_000_000))
  }

  private static func normalizeText(_ value: String) -> String {
    let folded = value.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    )
    var result = ""
    var pendingSeparator = false
    for scalar in folded.unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar) {
        if pendingSeparator, !result.isEmpty { result.append(" ") }
        result.unicodeScalars.append(scalar)
        pendingSeparator = false
      } else {
        pendingSeparator = true
      }
    }
    return result
  }

  private static func stableRandom(mediaUID: String, seed: UInt64) -> UInt64 {
    var hash = UInt64(14_695_981_039_346_656_037) ^ seed
    for byte in mediaUID.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return hash
  }

  private static func base64URLEncoded(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func base64URLDecoded(_ value: String) -> Data? {
    var base64 = value.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder != 0 { base64.append(String(repeating: "=", count: 4 - remainder)) }
    return Data(base64Encoded: base64)
  }

  private static let rootFileSQL = """
    SELECT CASE
             WHEN bound.kind IN ('movie', 'series') THEN bound.id
             WHEN bound.kind = 'season' THEN bound.parent_id
             WHEN bound.kind = 'episode' THEN parent.parent_id
             WHEN bound.kind = 'extra' AND parent.kind = 'season' THEN parent.parent_id
             WHEN bound.kind = 'extra' THEN bound.parent_id
           END AS root_id,
           source.uid AS source_uid, file.availability
    FROM file_binding binding
    JOIN media_file file ON file.id = binding.media_file_id
    JOIN library_source source ON source.id = file.source_id
    JOIN media_entity bound ON bound.id = binding.entity_id
    LEFT JOIN media_entity parent ON parent.id = bound.parent_id
    WHERE binding.binding_role IN ('primary', 'version')
      AND file.deleted_at_ms IS NULL AND bound.deleted_at_ms IS NULL
    ORDER BY root_id, source.uid, file.uid
    """

  private static let rootPlaybackSQL = """
    SELECT CASE
             WHEN bound.kind IN ('movie', 'series') THEN bound.id
             WHEN bound.kind = 'season' THEN bound.parent_id
             WHEN bound.kind = 'episode' THEN parent.parent_id
             WHEN bound.kind = 'extra' AND parent.kind = 'season' THEN parent.parent_id
             WHEN bound.kind = 'extra' THEN bound.parent_id
           END AS root_id,
           state.position_ms, state.duration_ms, state.completed, state.last_played_at_ms
    FROM playback_state state
    JOIN playback_profile profile ON profile.id = state.profile_id
    JOIN media_entity bound ON bound.id = state.entity_id
    LEFT JOIN media_entity parent ON parent.id = bound.parent_id
    WHERE profile.uid = ? AND bound.deleted_at_ms IS NULL
    ORDER BY root_id, state.last_played_at_ms DESC, bound.uid
    """

  private static let revisionQueries = [
    """
    SELECT 'source|' || id || '|' || quote(uid) || '|' || quote(kind) || '|'
      || quote(display_name) || '|' || enabled || '|' || updated_at_ms || '|'
      || COALESCE(deleted_at_ms, -1)
    FROM library_source ORDER BY id
    """,
    """
    SELECT 'entity|' || id || '|' || quote(uid) || '|' || quote(kind) || '|'
      || COALESCE(parent_id, -1) || '|' || quote(canonical_title) || '|'
      || COALESCE(quote(original_title), 'NULL') || '|' || COALESCE(year, -1) || '|'
      || COALESCE(season_number, -1) || '|' || COALESCE(episode_number, -1) || '|'
      || COALESCE(quote(release_date), 'NULL') || '|' || quote(status) || '|'
      || updated_at_ms || '|' || COALESCE(deleted_at_ms, -1)
    FROM media_entity ORDER BY id
    """,
    """
    SELECT 'file|' || id || '|' || quote(uid) || '|' || source_id || '|'
      || quote(availability) || '|' || COALESCE(size_bytes, -1) || '|'
      || updated_at_ms || '|' || COALESCE(deleted_at_ms, -1)
    FROM media_file ORDER BY id
    """,
    """
    SELECT 'binding|' || media_file_id || '|' || entity_id || '|' || quote(binding_role)
      || '|' || quote(match_method) || '|' || quote(confidence) || '|' || locked
      || '|' || decided_at_ms
    FROM file_binding ORDER BY media_file_id, entity_id
    """,
    """
    SELECT 'localized|' || entity_id || '|' || quote(locale) || '|' || quote(title) || '|'
      || COALESCE(quote(overview), 'NULL') || '|' || COALESCE(quote(tagline), 'NULL') || '|'
      || COALESCE(quote(content_rating), 'NULL') || '|' || quote(provider) || '|'
      || materialized_at_ms
    FROM localized_metadata ORDER BY entity_id, locale
    """,
    """
    SELECT 'genre|' || id || '|' || quote(uid) || '|' || quote(provider) || '|'
      || quote(provider_key)
    FROM genre ORDER BY id
    """,
    """
    SELECT 'genre_name|' || genre_id || '|' || quote(locale) || '|' || quote(name)
    FROM genre_name ORDER BY genre_id, locale
    """,
    """
    SELECT 'entity_genre|' || entity_id || '|' || genre_id || '|' || position
    FROM entity_genre ORDER BY entity_id, genre_id
    """,
    """
    SELECT 'artwork|' || id || '|' || quote(uid) || '|' || entity_id || '|'
      || quote(kind) || '|' || quote(locale) || '|' || quote(provider) || '|'
      || COALESCE(width, -1) || '|' || COALESCE(height, -1) || '|'
      || COALESCE(quote(score), 'NULL') || '|' || is_selected || '|' || updated_at_ms
    FROM artwork ORDER BY id
    """,
    """
    SELECT 'profile|' || id || '|' || quote(uid) || '|' || is_default || '|' || updated_at_ms
    FROM playback_profile ORDER BY id
    """,
    """
    SELECT 'playback|' || profile_id || '|' || entity_id || '|'
      || COALESCE(media_file_id, -1) || '|' || position_ms || '|'
      || COALESCE(duration_ms, -1) || '|' || completed || '|' || play_count || '|'
      || COALESCE(last_played_at_ms, -1) || '|' || updated_at_ms || '|' || revision
    FROM playback_state ORDER BY profile_id, entity_id
    """,
    """
    SELECT 'collection|' || id || '|' || quote(uid) || '|' || quote(kind) || '|'
      || quote(title) || '|' || updated_at_ms || '|' || COALESCE(deleted_at_ms, -1)
    FROM media_collection ORDER BY id
    """,
    """
    SELECT 'collection_item|' || collection_id || '|' || entity_id || '|'
      || position || '|' || added_at_ms
    FROM collection_item ORDER BY collection_id, entity_id
    """,
    """
    SELECT 'search|' || entity_id || '|' || quote(title) || '|' || quote(aliases) || '|'
      || quote(people) || '|' || quote(genres) || '|' || quote(romanized) || '|'
      || updated_at_ms
    FROM search_document ORDER BY entity_id
    """,
    """
    SELECT 'external|' || entity_id || '|' || quote(provider) || '|' || quote(namespace)
      || '|' || quote(external_value) || '|' || is_primary || '|' || updated_at_ms
    FROM external_id ORDER BY entity_id, provider, namespace
    """,
    """
    SELECT 'technical|' || media_file_id || '|' || COALESCE(duration_ms, -1) || '|'
      || COALESCE(quote(video_codec), 'NULL') || '|' || COALESCE(width, -1) || '|'
      || COALESCE(height, -1) || '|' || probe_version || '|' || probed_at_ms
    FROM technical_summary ORDER BY media_file_id
    """,
    """
    SELECT 'stream|' || media_file_id || '|' || stream_index || '|' || quote(kind) || '|'
      || COALESCE(quote(codec), 'NULL') || '|' || quote(language) || '|'
      || COALESCE(quote(title), 'NULL') || '|' || is_default || '|' || is_forced
    FROM media_stream ORDER BY media_file_id, stream_index
    """,
  ]
}

private struct RootProjection: Sendable {
  let entityID: Int64
  var item: PosterWallItem
  let originalTitle: String?
  let releaseDate: String?
  let addedAtMilliseconds: Int64
  var lastPlayedAtMilliseconds: Int64?
  var sourceUIDs: Set<String>
  var genres: Set<String>
  var collectionUIDs: Set<String>
  let searchText: String
  var hasPlaybackState: Bool
  var isCompleted: Bool
  var totalEpisodeCount: Int
}

private struct PlaybackProjection: Sendable {
  let positionMilliseconds: Int64
  let durationMilliseconds: Int64?
  let isCompleted: Bool
  let lastPlayedAtMilliseconds: Int64?
}

private struct LocalizedDetails: Sendable {
  let overview: String?
  let tagline: String?
  let contentRating: String?
}

private struct FileRecord: Sendable {
  let fileID: Int64
  let fileUID: String
  let sourceUID: String
  let relativePath: String
  let bindingRole: String
  let availability: String
  let sizeBytes: Int64?
  let durationMilliseconds: Int64?
  let videoCodec: String?
  let width: Int?
  let height: Int?
  let boundEntityID: Int64
  let boundKind: String
}

private struct PosterWallCursor: Codable, Sendable {
  let libraryRevision: String
  let queryIdentity: String
  let lastMediaUID: String

  private enum CodingKeys: String, CodingKey {
    case libraryRevision = "library_revision"
    case queryIdentity = "query_identity"
    case lastMediaUID = "last_media_uid"
  }
}

private struct PosterWallQueryIdentity: Codable, Sendable {
  let section: PosterWallSection
  let sort: PosterWallSort
  let filter: PosterWallFilter
  let searchText: String?
  let profileUID: String?
  let collectionUID: String?
  let locale: String
  let randomSeed: UInt64

  private enum CodingKeys: String, CodingKey {
    case section
    case sort
    case filter
    case searchText = "search_text"
    case profileUID = "profile_uid"
    case collectionUID = "collection_uid"
    case locale
    case randomSeed = "random_seed"
  }
}

extension String {
  fileprivate func leftPadding(toLength: Int, with character: Character) -> String {
    guard count < toLength else { return self }
    return String(repeating: String(character), count: toLength - count) + self
  }
}

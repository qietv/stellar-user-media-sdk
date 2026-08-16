import GRDB
import StellarCore

/// Repository for provider, match-candidate, and artwork data that is safe to rebuild.
public struct MetadataCacheStore: Sendable {
  public let database: StorageDatabase

  public init(database: StorageDatabase) throws {
    guard database.kind == .metadataCache else {
      throw SDKError(
        code: .invalidConfiguration,
        message: "MetadataCacheStore requires metadata_cache.sqlite"
      )
    }
    self.database = database
  }

  package func replaceMatchCandidates(
    fileUID: String,
    candidates: [MetadataMatchCandidateCacheRecord]
  ) async throws {
    do {
      try await database.write { database in
        try database.execute(
          sql: "DELETE FROM match_candidate_cache WHERE file_uid = ?",
          arguments: [fileUID]
        )
        for candidate in candidates {
          try database.execute(
            sql: """
              INSERT INTO match_candidate_cache(
                file_uid, provider, entity_kind, provider_id, candidate_title,
                candidate_year, season_number, episode_number, score, rank,
                raw_fragment_json, created_at_ms
              ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
              """,
            arguments: [
              fileUID, candidate.provider, candidate.entityKind, candidate.providerID,
              candidate.title, candidate.year, candidate.seasonNumber,
              candidate.episodeNumber, candidate.score, candidate.rank,
              candidate.rawFragmentJSON, candidate.createdAtMilliseconds,
            ]
          )
        }
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "match candidate cache write failed")
    }
  }

  package func matchCandidates(fileUID: String) async throws
    -> [MetadataMatchCandidateCacheRecord]
  {
    do {
      return try await database.read { database in
        try Row.fetchAll(
          database,
          sql: """
            SELECT provider, entity_kind, provider_id, candidate_title, candidate_year,
                   season_number, episode_number, score, rank, raw_fragment_json,
                   created_at_ms
            FROM match_candidate_cache
            WHERE file_uid = ?
            ORDER BY rank, provider, provider_id
            """,
          arguments: [fileUID]
        ).map { row in
          try MetadataMatchCandidateCacheRecord(
            provider: row["provider"],
            entityKind: row["entity_kind"],
            providerID: row["provider_id"],
            title: row["candidate_title"],
            year: row["candidate_year"],
            seasonNumber: row["season_number"],
            episodeNumber: row["episode_number"],
            score: row["score"],
            rank: row["rank"],
            rawFragmentJSON: row["raw_fragment_json"],
            createdAtMilliseconds: row["created_at_ms"]
          )
        }
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "match candidate cache read failed")
    }
  }
}

package struct MetadataMatchCandidateCacheRecord: Equatable, Sendable {
  package let provider: String
  package let entityKind: String
  package let providerID: String
  package let title: String
  package let year: Int?
  package let seasonNumber: Int?
  package let episodeNumber: Int?
  package let score: Double
  package let rank: Int
  package let rawFragmentJSON: String
  package let createdAtMilliseconds: Int64

  package init(
    provider: String,
    entityKind: String,
    providerID: String,
    title: String,
    year: Int? = nil,
    seasonNumber: Int? = nil,
    episodeNumber: Int? = nil,
    score: Double,
    rank: Int,
    rawFragmentJSON: String,
    createdAtMilliseconds: Int64
  ) throws {
    guard !provider.isEmpty, !entityKind.isEmpty, !providerID.isEmpty, !title.isEmpty,
      !provider.contains("\0"), !entityKind.contains("\0"), !providerID.contains("\0"),
      !title.contains("\0"), !rawFragmentJSON.isEmpty, !rawFragmentJSON.contains("\0"),
      year.map({ (1000...9999).contains($0) }) ?? true,
      seasonNumber.map({ $0 >= 0 }) ?? true,
      episodeNumber.map({ $0 >= 0 }) ?? true,
      score.isFinite, (0...1).contains(score), rank >= 0
    else {
      throw SDKError(code: .invalidConfiguration, message: "match candidate cache is invalid")
    }
    self.provider = provider
    self.entityKind = entityKind
    self.providerID = providerID
    self.title = title
    self.year = year
    self.seasonNumber = seasonNumber
    self.episodeNumber = episodeNumber
    self.score = score
    self.rank = rank
    self.rawFragmentJSON = rawFragmentJSON
    self.createdAtMilliseconds = createdAtMilliseconds
  }
}

import GRDB
import StellarCore

/// One regenerable HTTP response retained for provider reuse and conditional requests.
public struct MetadataProviderResponseCacheEntry: Equatable, Sendable {
  public let requestKey: String
  public let provider: String
  public let endpoint: String
  public let requestFingerprint: String
  public let locale: String
  public let httpStatus: Int
  public let entityTag: String?
  public let lastModified: String?
  public let responseJSON: String?
  public let fetchedAtMilliseconds: Int64
  public let expiresAtMilliseconds: Int64
  public let errorCount: Int

  public var isNegative: Bool { responseJSON == nil }

  public init(
    requestKey: String,
    provider: String,
    endpoint: String,
    requestFingerprint: String,
    locale: String = "und",
    httpStatus: Int,
    entityTag: String? = nil,
    lastModified: String? = nil,
    responseJSON: String? = nil,
    fetchedAtMilliseconds: Int64,
    expiresAtMilliseconds: Int64,
    errorCount: Int = 0
  ) throws {
    guard !requestKey.isEmpty, !provider.isEmpty, !endpoint.isEmpty,
      !requestFingerprint.isEmpty, !locale.isEmpty,
      !requestKey.contains("\0"), !provider.contains("\0"), !endpoint.contains("\0"),
      !requestFingerprint.contains("\0"), !locale.contains("\0"),
      entityTag?.contains("\0") != true, lastModified?.contains("\0") != true,
      responseJSON?.contains("\0") != true, (100...599).contains(httpStatus),
      fetchedAtMilliseconds >= 0, expiresAtMilliseconds >= fetchedAtMilliseconds,
      errorCount >= 0
    else {
      throw SDKError(code: .invalidConfiguration, message: "provider cache entry is invalid")
    }
    self.requestKey = requestKey
    self.provider = provider
    self.endpoint = endpoint
    self.requestFingerprint = requestFingerprint
    self.locale = locale
    self.httpStatus = httpStatus
    self.entityTag = entityTag
    self.lastModified = lastModified
    self.responseJSON = responseJSON
    self.fetchedAtMilliseconds = fetchedAtMilliseconds
    self.expiresAtMilliseconds = expiresAtMilliseconds
    self.errorCount = errorCount
  }

  public func isFresh(at milliseconds: Int64) -> Bool {
    milliseconds < expiresAtMilliseconds
  }
}

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

  /// Reads a provider response when both the stable key and full request fingerprint match.
  public func providerResponse(
    requestKey: String,
    requestFingerprint: String
  ) async throws -> MetadataProviderResponseCacheEntry? {
    guard !requestKey.isEmpty, !requestFingerprint.isEmpty,
      !requestKey.contains("\0"), !requestFingerprint.contains("\0")
    else {
      throw SDKError(code: .invalidConfiguration, message: "provider cache key is invalid")
    }
    do {
      return try await database.read { database in
        guard
          let row = try Row.fetchOne(
            database,
            sql: """
              SELECT request_key, provider, endpoint, request_fingerprint, locale,
                     http_status, etag, last_modified, response_json, fetched_at_ms,
                     expires_at_ms, error_count
              FROM provider_response_cache
              WHERE request_key = ? AND request_fingerprint = ?
              """,
            arguments: [requestKey, requestFingerprint]
          )
        else { return nil }
        return try MetadataProviderResponseCacheEntry(
          requestKey: row["request_key"],
          provider: row["provider"],
          endpoint: row["endpoint"],
          requestFingerprint: row["request_fingerprint"],
          locale: row["locale"],
          httpStatus: row["http_status"],
          entityTag: row["etag"],
          lastModified: row["last_modified"],
          responseJSON: row["response_json"],
          fetchedAtMilliseconds: row["fetched_at_ms"],
          expiresAtMilliseconds: row["expires_at_ms"],
          errorCount: row["error_count"]
        )
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "provider cache read failed")
    }
  }

  /// Atomically inserts or replaces one provider response and its validators.
  public func storeProviderResponse(_ entry: MetadataProviderResponseCacheEntry) async throws {
    do {
      try await database.write { database in
        try database.execute(
          sql: """
            INSERT INTO provider_response_cache(
              request_key, provider, endpoint, request_fingerprint, locale, http_status,
              etag, last_modified, response_json, fetched_at_ms, expires_at_ms, error_count
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(request_key) DO UPDATE SET
              provider = excluded.provider,
              endpoint = excluded.endpoint,
              request_fingerprint = excluded.request_fingerprint,
              locale = excluded.locale,
              http_status = excluded.http_status,
              etag = excluded.etag,
              last_modified = excluded.last_modified,
              response_json = excluded.response_json,
              fetched_at_ms = excluded.fetched_at_ms,
              expires_at_ms = excluded.expires_at_ms,
              error_count = excluded.error_count
            """,
          arguments: [
            entry.requestKey, entry.provider, entry.endpoint, entry.requestFingerprint,
            entry.locale, entry.httpStatus, entry.entityTag, entry.lastModified,
            entry.responseJSON, entry.fetchedAtMilliseconds, entry.expiresAtMilliseconds,
            entry.errorCount,
          ]
        )
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "provider cache write failed")
    }
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

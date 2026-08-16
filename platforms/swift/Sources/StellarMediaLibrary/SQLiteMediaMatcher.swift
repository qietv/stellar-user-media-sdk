import Foundation
import StellarCore
import StellarStorage

/// The role a playable file has in a logical media entity.
public enum MediaMatchBindingRole: String, Sendable {
  case primary
  case contained
  case version
  case extra
  case unknown
}

extension MediaMatchBindingRole: Codable {
  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = MediaMatchBindingRole(rawValue: value) ?? .unknown
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// The evidence source that produced a persisted file-to-entity binding.
public enum MediaMatchMethod: String, Sendable {
  case manual
  case sidecarID = "sidecar_id"
  case filenameID = "filename_id"
  case providerSearch = "provider_search"
  case mediaServer = "media_server"
  case inherited
  case unknown
}

extension MediaMatchMethod: Codable {
  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = MediaMatchMethod(rawValue: value) ?? .unknown
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// A stable read model for one file's current logical-media binding.
public struct MediaFileMatchBinding: Codable, Equatable, Sendable {
  public let fileUID: String
  public let entityUID: String
  public let entityKind: ParsedMediaKind
  public let canonicalTitle: String
  public let role: MediaMatchBindingRole
  public let method: MediaMatchMethod
  public let confidence: Double
  public let isLocked: Bool

  private enum CodingKeys: String, CodingKey {
    case fileUID = "file_uid"
    case entityUID = "entity_uid"
    case entityKind = "entity_kind"
    case canonicalTitle = "canonical_title"
    case role
    case method
    case confidence
    case isLocked = "is_locked"
  }
}

/// The durable state transition produced by candidate evaluation.
public enum MediaMatchPersistenceState: String, Sendable {
  case automaticBound = "automatic_bound"
  case reviewRequired = "review_required"
  case detailsRequired = "details_required"
  case unmatched
  case lockedBindingPreserved = "locked_binding_preserved"
  case unknown
}

extension MediaMatchPersistenceState: Codable {
  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = MediaMatchPersistenceState(rawValue: value) ?? .unknown
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// The binding and review candidates visible after a persisted match decision.
public struct MediaMatchPersistenceResult: Codable, Equatable, Sendable {
  public let state: MediaMatchPersistenceState
  public let binding: MediaFileMatchBinding?
  public let candidates: [ScoredMediaMetadataCandidate]
}

/// Coordinates provider search, deterministic scoring, review caching, and SQLite bindings.
public struct SQLiteMediaMatcher: Sendable {
  public let libraryStore: LibraryStore
  public let metadataCacheStore: MetadataCacheStore
  public let scorer: MediaMetadataCandidateScorer
  private let clock: any SDKClock

  public init(
    libraryStore: LibraryStore,
    metadataCacheStore: MetadataCacheStore,
    scorer: MediaMetadataCandidateScorer = MediaMetadataCandidateScorer(),
    clock: any SDKClock = SystemSDKClock()
  ) {
    self.libraryStore = libraryStore
    self.metadataCacheStore = metadataCacheStore
    self.scorer = scorer
    self.clock = clock
  }

  /// Searches through an injected provider and persists only a successful decision.
  public func match(
    query: MediaMatchQuery,
    sourceUID: String,
    mediaRelativePath: String,
    using provider: any MediaMetadataProviding
  ) async throws -> MediaMatchPersistenceResult {
    if let binding = try await binding(
      sourceUID: sourceUID,
      mediaRelativePath: mediaRelativePath
    ), binding.isLocked {
      return MediaMatchPersistenceResult(
        state: .lockedBindingPreserved,
        binding: binding,
        candidates: []
      )
    }
    let candidates = try await provider.search(query)
    return try await evaluate(
      query: query,
      candidates: candidates,
      sourceUID: sourceUID,
      mediaRelativePath: mediaRelativePath
    )
  }

  /// Scores already-decoded candidates and commits an automatic, review, or unmatched outcome.
  public func evaluate(
    query: MediaMatchQuery,
    candidates: [MediaMetadataCandidate],
    sourceUID: String,
    mediaRelativePath: String
  ) async throws -> MediaMatchPersistenceResult {
    let fileUID = try await libraryStore.mediaFileUID(
      sourceUID: sourceUID,
      mediaRelativePath: mediaRelativePath
    )
    if let existing = try await binding(
      sourceUID: sourceUID,
      mediaRelativePath: mediaRelativePath
    ), existing.isLocked {
      return MediaMatchPersistenceResult(
        state: .lockedBindingPreserved,
        binding: existing,
        candidates: []
      )
    }

    let ranked = scorer.rank(query: query, candidates: candidates)
    guard let best = ranked.first(where: { $0.decision != .rejected }) else {
      try await metadataCacheStore.replaceMatchCandidates(fileUID: fileUID, candidates: [])
      return MediaMatchPersistenceResult(
        state: .unmatched,
        binding: try await binding(sourceUID: sourceUID, mediaRelativePath: mediaRelativePath),
        candidates: []
      )
    }

    switch best.decision {
    case .automatic:
      guard canMaterialize(query: query, candidate: best.candidate) else {
        let pending = ranked.filter { $0.decision != .rejected }
        try await persistReviewCandidates(pending, query: query, fileUID: fileUID)
        return MediaMatchPersistenceResult(
          state: .detailsRequired,
          binding: try await binding(sourceUID: sourceUID, mediaRelativePath: mediaRelativePath),
          candidates: pending
        )
      }
      let request = try makeBindingRequest(
        query: query,
        scoredCandidate: best,
        sourceUID: sourceUID,
        mediaRelativePath: mediaRelativePath,
        method: .providerSearch,
        locked: false,
        canReplaceLockedBinding: false
      )
      let result = try await libraryStore.commitMatchBinding(request)
      try await metadataCacheStore.replaceMatchCandidates(fileUID: fileUID, candidates: [])
      switch result {
      case .committed(let snapshot):
        return MediaMatchPersistenceResult(
          state: .automaticBound,
          binding: makeBinding(snapshot),
          candidates: []
        )
      case .lockedBindingPreserved(let snapshot):
        return MediaMatchPersistenceResult(
          state: .lockedBindingPreserved,
          binding: makeBinding(snapshot),
          candidates: []
        )
      }
    case .review:
      let pending = ranked.filter { $0.decision != .rejected }
      try await persistReviewCandidates(pending, query: query, fileUID: fileUID)
      return MediaMatchPersistenceResult(
        state: .reviewRequired,
        binding: try await binding(sourceUID: sourceUID, mediaRelativePath: mediaRelativePath),
        candidates: pending
      )
    case .unmatched, .rejected, .unknown:
      try await metadataCacheStore.replaceMatchCandidates(fileUID: fileUID, candidates: [])
      return MediaMatchPersistenceResult(
        state: .unmatched,
        binding: try await binding(sourceUID: sourceUID, mediaRelativePath: mediaRelativePath),
        candidates: []
      )
    }
  }

  /// Confirms one candidate as a user-owned binding that automatic repair cannot replace.
  public func confirm(
    query: MediaMatchQuery,
    candidate: MediaMetadataCandidate,
    sourceUID: String,
    mediaRelativePath: String
  ) async throws -> MediaFileMatchBinding {
    let scored = scorer.rank(query: query, candidates: [candidate])[0]
    guard scored.decision != .rejected, canMaterialize(query: query, candidate: candidate) else {
      throw SDKError(code: .invalidConfiguration, message: "candidate requires provider details")
    }
    let request = try makeBindingRequest(
      query: query,
      scoredCandidate: scored,
      sourceUID: sourceUID,
      mediaRelativePath: mediaRelativePath,
      method: .manual,
      locked: true,
      canReplaceLockedBinding: true
    )
    let result = try await libraryStore.commitMatchBinding(request)
    let snapshot: LibraryFileBindingSnapshot
    switch result {
    case .committed(let value), .lockedBindingPreserved(let value):
      snapshot = value
    }
    try await metadataCacheStore.replaceMatchCandidates(
      fileUID: snapshot.fileUID,
      candidates: []
    )
    return makeBinding(snapshot)
  }

  /// Reads ranked candidates retained for a user-review decision.
  public func pendingCandidates(
    sourceUID: String,
    mediaRelativePath: String
  ) async throws -> [ScoredMediaMetadataCandidate] {
    let fileUID = try await libraryStore.mediaFileUID(
      sourceUID: sourceUID,
      mediaRelativePath: mediaRelativePath
    )
    let records = try await metadataCacheStore.matchCandidates(fileUID: fileUID)
    let decoder = JSONDecoder()
    return try records.map { record in
      do {
        return try decoder.decode(
          ScoredMediaMetadataCandidate.self,
          from: Data(record.rawFragmentJSON.utf8)
        )
      } catch {
        throw SDKError(code: .storageFailure, message: "cached match candidate is invalid")
      }
    }
  }

  /// Reads the current primary or version binding without exposing database row IDs.
  public func binding(
    sourceUID: String,
    mediaRelativePath: String
  ) async throws -> MediaFileMatchBinding? {
    try await libraryStore.matchBinding(
      sourceUID: sourceUID,
      mediaRelativePath: mediaRelativePath
    ).map(makeBinding)
  }

  private func persistReviewCandidates(
    _ candidates: [ScoredMediaMetadataCandidate],
    query: MediaMatchQuery,
    fileUID: String
  ) async throws {
    var identityKeys: Set<String> = []
    let encoder = canonicalJSONEncoder()
    let now = clock.nowMilliseconds()
    let records = try candidates.enumerated().map { rank, scored in
      let candidate = scored.candidate
      let key = "\(candidate.provider)\0\(candidate.kind.rawValue)\0\(candidate.candidateID)"
      guard identityKeys.insert(key).inserted else {
        throw SDKError(code: .invalidConfiguration, message: "metadata candidates are duplicated")
      }
      return try MetadataMatchCandidateCacheRecord(
        provider: candidate.provider,
        entityKind: candidate.kind.rawValue,
        providerID: candidate.candidateID,
        title: candidate.title,
        year: candidate.year,
        seasonNumber: query.season,
        episodeNumber: query.episode,
        score: scored.score,
        rank: rank,
        rawFragmentJSON: String(decoding: try encoder.encode(scored), as: UTF8.self),
        createdAtMilliseconds: now
      )
    }
    try await metadataCacheStore.replaceMatchCandidates(fileUID: fileUID, candidates: records)
  }

  private func makeBindingRequest(
    query: MediaMatchQuery,
    scoredCandidate: ScoredMediaMetadataCandidate,
    sourceUID: String,
    mediaRelativePath: String,
    method: MediaMatchMethod,
    locked: Bool,
    canReplaceLockedBinding: Bool
  ) throws -> LibraryFileBindingRequest {
    let candidate = scoredCandidate.candidate
    let rootKind: ParsedMediaKind
    let rootTitle: String
    let rootOriginalTitle: String?
    let rootYear: Int?
    var identifiers: [LocalMetadataExternalID]
    switch (query.kind, candidate.kind) {
    case (.movie, .movie):
      rootKind = .movie
      rootTitle = candidate.title
      rootOriginalTitle = candidate.originalTitle
      rootYear = candidate.year
      identifiers = (query.externalIDs + candidate.externalIDs).filter {
        $0.namespace.lowercased() == "movie"
      }
      identifiers.append(
        try LocalMetadataExternalID(
          provider: candidate.provider,
          namespace: "movie",
          value: candidate.candidateID,
          isPrimary: true
        )
      )
    case (.episode, .series):
      rootKind = .series
      rootTitle = candidate.title
      rootOriginalTitle = candidate.originalTitle
      rootYear = candidate.year
      identifiers = (query.externalIDs + candidate.externalIDs).filter {
        $0.namespace.lowercased() == "series"
      }
      identifiers.append(
        try LocalMetadataExternalID(
          provider: candidate.provider,
          namespace: "series",
          value: candidate.candidateID,
          isPrimary: true
        )
      )
    case (.episode, .episode):
      rootKind = .series
      rootTitle = query.title ?? candidate.title
      rootOriginalTitle = nil
      rootYear = query.year
      identifiers = (query.externalIDs + candidate.externalIDs).filter {
        $0.namespace.lowercased() == "series"
      }
    default:
      throw SDKError(code: .invalidConfiguration, message: "candidate kind cannot be materialized")
    }

    let externalIDs = try normalizeExternalIDs(identifiers)
    let root = try LibraryMatchRootEntityRecord(
      kind: rootKind.rawValue,
      canonicalTitle: rootTitle,
      originalTitle: rootOriginalTitle,
      year: rootYear,
      externalIDs: externalIDs
    )
    let matchedQueryJSON = String(
      decoding: try canonicalJSONEncoder().encode(query),
      as: UTF8.self
    )
    return try LibraryFileBindingRequest(
      sourceUID: sourceUID,
      mediaRelativePath: mediaRelativePath,
      rootEntity: root,
      seasonNumber: query.kind == .episode ? query.season : nil,
      episodeNumber: query.kind == .episode ? query.episode : nil,
      matchMethod: method.rawValue,
      confidence: scoredCandidate.score,
      matchedQueryJSON: matchedQueryJSON,
      locked: locked,
      canReplaceLockedBinding: canReplaceLockedBinding
    )
  }

  private func normalizeExternalIDs(_ identifiers: [LocalMetadataExternalID]) throws
    -> [LibraryMatchExternalIDRecord]
  {
    var byKey: [String: LibraryMatchExternalIDRecord] = [:]
    for identifier in identifiers {
      let provider = identifier.provider.lowercased()
      let namespace = identifier.namespace.lowercased()
      let key = "\(provider)\0\(namespace)"
      if let existing = byKey[key] {
        guard existing.value == identifier.value else {
          throw SDKError(code: .conflict, message: "candidate external IDs conflict")
        }
        if identifier.isPrimary, !existing.isPrimary {
          byKey[key] = try LibraryMatchExternalIDRecord(
            provider: provider,
            namespace: namespace,
            value: identifier.value,
            isPrimary: true
          )
        }
      } else {
        byKey[key] = try LibraryMatchExternalIDRecord(
          provider: provider,
          namespace: namespace,
          value: identifier.value,
          isPrimary: identifier.isPrimary
        )
      }
    }
    return byKey.values.sorted {
      ($0.provider, $0.namespace, $0.value) < ($1.provider, $1.namespace, $1.value)
    }
  }

  private func canMaterialize(
    query: MediaMatchQuery,
    candidate: MediaMetadataCandidate
  ) -> Bool {
    switch (query.kind, candidate.kind) {
    case (.movie, .movie), (.episode, .series):
      true
    case (.episode, .episode):
      (query.externalIDs + candidate.externalIDs).contains {
        $0.namespace.lowercased() == "series"
      }
    default:
      false
    }
  }

  private func makeBinding(_ snapshot: LibraryFileBindingSnapshot) -> MediaFileMatchBinding {
    MediaFileMatchBinding(
      fileUID: snapshot.fileUID,
      entityUID: snapshot.entityUID,
      entityKind: ParsedMediaKind(rawValue: snapshot.entityKind) ?? .unknown,
      canonicalTitle: snapshot.canonicalTitle,
      role: MediaMatchBindingRole(rawValue: snapshot.bindingRole) ?? .unknown,
      method: MediaMatchMethod(rawValue: snapshot.matchMethod) ?? .unknown,
      confidence: snapshot.confidence,
      isLocked: snapshot.isLocked
    )
  }

  private func canonicalJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}

import Foundation
import StellarCore

/// A season and episode pair used to verify episodic candidates.
public struct MediaEpisodeCoordinate: Codable, Equatable, Hashable, Sendable {
  public let season: Int
  public let episode: Int

  public init(season: Int, episode: Int) throws {
    guard season >= 0, episode >= 0 else {
      throw SDKError(code: .parseFailure, message: "episode coordinate is invalid")
    }
    self.season = season
    self.episode = episode
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        season: container.decode(Int.self, forKey: .season),
        episode: container.decode(Int.self, forKey: .episode)
      )
    } catch let error as SDKError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message)
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case season
    case episode
  }
}

/// The minimal, source-independent evidence sent to a metadata provider.
public struct MediaMatchQuery: Codable, Equatable, Sendable {
  public let kind: ParsedMediaKind
  public let title: String?
  public let year: Int?
  public let season: Int?
  public let episode: Int?
  public let externalIDs: [LocalMetadataExternalID]

  public init(
    kind: ParsedMediaKind,
    title: String? = nil,
    year: Int? = nil,
    season: Int? = nil,
    episode: Int? = nil,
    externalIDs: [LocalMetadataExternalID] = []
  ) throws {
    let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard kind == .movie || kind == .episode,
      normalizedTitle?.contains("\0") != true,
      normalizedTitle?.isEmpty == false || !externalIDs.isEmpty,
      year.map({ (1000...9999).contains($0) }) ?? true,
      season.map({ $0 >= 0 }) ?? true,
      episode.map({ $0 >= 0 }) ?? true,
      kind != .episode || (season != nil && episode != nil)
    else {
      throw SDKError(code: .parseFailure, message: "metadata match query is incomplete")
    }
    self.kind = kind
    self.title = normalizedTitle
    self.year = year
    self.season = season
    self.episode = episode
    self.externalIDs = externalIDs
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        kind: container.decode(ParsedMediaKind.self, forKey: .kind),
        title: container.decodeIfPresent(String.self, forKey: .title),
        year: container.decodeIfPresent(Int.self, forKey: .year),
        season: container.decodeIfPresent(Int.self, forKey: .season),
        episode: container.decodeIfPresent(Int.self, forKey: .episode),
        externalIDs: container.decodeIfPresent([LocalMetadataExternalID].self, forKey: .externalIDs)
          ?? []
      )
    } catch let error as SDKError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message)
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    try container.encodeIfPresent(title, forKey: .title)
    try container.encodeIfPresent(year, forKey: .year)
    try container.encodeIfPresent(season, forKey: .season)
    try container.encodeIfPresent(episode, forKey: .episode)
    try container.encode(externalIDs, forKey: .externalIDs)
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case title
    case year
    case season
    case episode
    case externalIDs = "external_ids"
  }
}

/// Builds provider queries while preserving local-metadata precedence over filenames.
public struct MediaMatchQueryBuilder: Sendable {
  public init() {}

  public func build(
    filename: ParsedMediaFilename,
    localMetadata: LocalMetadataDocument? = nil
  ) throws -> MediaMatchQuery {
    let kind = resolvedKind(filename: filename, localMetadata: localMetadata)
    let localEvidence = compatibleLocalMetadata(localMetadata, with: kind)
    let title: String?
    if kind == .episode {
      title =
        localEvidence?.seriesTitle
        ?? (localEvidence?.kind == .series ? localEvidence?.title : nil)
        ?? filename.title
    } else {
      title = localEvidence?.title ?? filename.title
    }
    return try MediaMatchQuery(
      kind: kind,
      title: title,
      year: localEvidence?.year ?? filename.year,
      season: localEvidence?.season ?? filename.season,
      episode: localEvidence?.episode ?? filename.episode,
      externalIDs: localEvidence?.externalIDs ?? []
    )
  }

  private func resolvedKind(
    filename: ParsedMediaFilename,
    localMetadata: LocalMetadataDocument?
  ) -> ParsedMediaKind {
    if filename.kind == .episode, localMetadata?.kind == .series {
      return .episode
    }
    if localMetadata?.kind == .movie || localMetadata?.kind == .episode {
      return localMetadata?.kind ?? filename.kind
    }
    return filename.kind
  }

  private func compatibleLocalMetadata(
    _ localMetadata: LocalMetadataDocument?,
    with kind: ParsedMediaKind
  ) -> LocalMetadataDocument? {
    guard let localMetadata else { return nil }
    switch kind {
    case .movie:
      return localMetadata.kind == .movie ? localMetadata : nil
    case .episode:
      return localMetadata.kind == .series || localMetadata.kind == .episode
        ? localMetadata
        : nil
    case .series, .season, .extra, .unknown:
      return nil
    }
  }
}

/// One provider search candidate before SDK policy is applied.
public struct MediaMetadataCandidate: Codable, Equatable, Sendable {
  public let provider: String
  public let candidateID: String
  public let kind: ParsedMediaKind
  public let title: String
  public let originalTitle: String?
  public let aliases: [String]
  public let year: Int?
  public let availableEpisodes: [MediaEpisodeCoordinate]
  public let externalIDs: [LocalMetadataExternalID]
  public let popularity: Double

  public init(
    provider: String,
    candidateID: String,
    kind: ParsedMediaKind,
    title: String,
    originalTitle: String? = nil,
    aliases: [String] = [],
    year: Int? = nil,
    availableEpisodes: [MediaEpisodeCoordinate] = [],
    externalIDs: [LocalMetadataExternalID] = [],
    popularity: Double = 0
  ) throws {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !provider.isEmpty, !candidateID.isEmpty, !trimmedTitle.isEmpty,
      !provider.contains("\0"), !candidateID.contains("\0"), !trimmedTitle.contains("\0"),
      originalTitle?.contains("\0") != true,
      aliases.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }),
      year.map({ (1000...9999).contains($0) }) ?? true,
      Set(availableEpisodes).count == availableEpisodes.count,
      popularity.isFinite, popularity >= 0
    else {
      throw SDKError(code: .parseFailure, message: "metadata candidate is invalid")
    }
    self.provider = provider
    self.candidateID = candidateID
    self.kind = kind
    self.title = trimmedTitle
    self.originalTitle = originalTitle
    self.aliases = aliases
    self.year = year
    self.availableEpisodes = availableEpisodes.sorted {
      ($0.season, $0.episode) < ($1.season, $1.episode)
    }
    self.externalIDs = externalIDs
    self.popularity = popularity
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        provider: container.decode(String.self, forKey: .provider),
        candidateID: container.decode(String.self, forKey: .candidateID),
        kind: container.decode(ParsedMediaKind.self, forKey: .kind),
        title: container.decode(String.self, forKey: .title),
        originalTitle: container.decodeIfPresent(String.self, forKey: .originalTitle),
        aliases: container.decodeIfPresent([String].self, forKey: .aliases) ?? [],
        year: container.decodeIfPresent(Int.self, forKey: .year),
        availableEpisodes: container.decodeIfPresent(
          [MediaEpisodeCoordinate].self,
          forKey: .availableEpisodes
        ) ?? [],
        externalIDs: container.decodeIfPresent([LocalMetadataExternalID].self, forKey: .externalIDs)
          ?? [],
        popularity: container.decodeIfPresent(Double.self, forKey: .popularity) ?? 0
      )
    } catch let error as SDKError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message)
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case provider
    case candidateID = "candidate_id"
    case kind
    case title
    case originalTitle = "original_title"
    case aliases
    case year
    case availableEpisodes = "available_episodes"
    case externalIDs = "external_ids"
    case popularity
  }
}

/// Injectable provider boundary. Production transports and fixture providers share this seam.
public protocol MediaMetadataProviding: Sendable {
  func search(_ query: MediaMatchQuery) async throws -> [MediaMetadataCandidate]
}

/// The policy outcome for one scored metadata candidate.
public enum MediaMatchDecision: String, Sendable {
  case automatic
  case review
  case unmatched
  case rejected
  case unknown
}

extension MediaMatchDecision: Codable {
  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = MediaMatchDecision(rawValue: value) ?? .unknown
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// A stable explanation signal emitted by the v1 scorer.
public enum MediaMatchSignal: String, Sendable {
  case kindMismatch = "kind_mismatch"
  case exactExternalID = "exact_external_id"
  case titleExact = "title_exact"
  case titleAliasExact = "title_alias_exact"
  case yearExact = "year_exact"
  case yearNear = "year_near"
  case yearMismatch = "year_mismatch"
  case episodeExists = "episode_exists"
  case episodeMissing = "episode_missing"
  case unknown
}

extension MediaMatchSignal: Codable {
  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = MediaMatchSignal(rawValue: value) ?? .unknown
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// One provider candidate plus its deterministic SDK score and decision.
public struct ScoredMediaMetadataCandidate: Codable, Equatable, Sendable {
  public let candidate: MediaMetadataCandidate
  public let score: Double
  public let decision: MediaMatchDecision
  public let signals: [MediaMatchSignal]

  public init(
    candidate: MediaMetadataCandidate,
    score: Double,
    decision: MediaMatchDecision,
    signals: [MediaMatchSignal]
  ) {
    self.candidate = candidate
    self.score = score
    self.decision = decision
    self.signals = signals
  }
}

/// Configurable automatic/review thresholds for deterministic candidate scoring.
public struct MediaMatchScoringPolicy: Equatable, Sendable {
  public let automaticThreshold: Double
  public let reviewThreshold: Double

  public init(automaticThreshold: Double = 0.88, reviewThreshold: Double = 0.72) throws {
    guard automaticThreshold.isFinite, reviewThreshold.isFinite,
      (0...1).contains(automaticThreshold), (0...1).contains(reviewThreshold),
      reviewThreshold <= automaticThreshold
    else {
      throw SDKError(code: .invalidConfiguration, message: "metadata scoring policy is invalid")
    }
    self.automaticThreshold = automaticThreshold
    self.reviewThreshold = reviewThreshold
  }

  private init(validatedAutomaticThreshold: Double, validatedReviewThreshold: Double) {
    automaticThreshold = validatedAutomaticThreshold
    reviewThreshold = validatedReviewThreshold
  }

  fileprivate static var standard: MediaMatchScoringPolicy {
    MediaMatchScoringPolicy(validatedAutomaticThreshold: 0.88, validatedReviewThreshold: 0.72)
  }
}

/// The cross-platform v1 metadata candidate scorer.
public struct MediaMetadataCandidateScorer: Sendable {
  public let policy: MediaMatchScoringPolicy

  public init() {
    policy = .standard
  }

  public init(policy: MediaMatchScoringPolicy) {
    self.policy = policy
  }

  public func rank(
    query: MediaMatchQuery,
    candidates: [MediaMetadataCandidate]
  ) -> [ScoredMediaMetadataCandidate] {
    candidates.map { score(query: query, candidate: $0) }
      .sorted { lhs, rhs in
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.candidate.popularity != rhs.candidate.popularity {
          return lhs.candidate.popularity > rhs.candidate.popularity
        }
        if lhs.candidate.provider != rhs.candidate.provider {
          return lhs.candidate.provider < rhs.candidate.provider
        }
        return lhs.candidate.candidateID < rhs.candidate.candidateID
      }
  }

  private func score(
    query: MediaMatchQuery,
    candidate: MediaMetadataCandidate
  ) -> ScoredMediaMetadataCandidate {
    guard kindsAreCompatible(query: query.kind, candidate: candidate.kind) else {
      return rejected(candidate, signal: .kindMismatch)
    }

    if query.kind == .episode,
      let season = query.season,
      let episode = query.episode,
      !candidate.availableEpisodes.isEmpty,
      !candidate.availableEpisodes.contains(where: {
        $0.season == season && $0.episode == episode
      })
    {
      return rejected(candidate, signal: .episodeMissing)
    }

    if hasExactExternalID(query.externalIDs, candidate.externalIDs) {
      return ScoredMediaMetadataCandidate(
        candidate: candidate,
        score: 1,
        decision: .automatic,
        signals: [.exactExternalID]
      )
    }

    var value = 0.0
    var signals: [MediaMatchSignal] = []
    if let queryTitle = query.title.map(normalizeTitle) {
      if normalizeTitle(candidate.title) == queryTitle {
        value += 0.70
        signals.append(.titleExact)
      } else {
        let alternateTitles = ([candidate.originalTitle].compactMap { $0 } + candidate.aliases)
          .map(normalizeTitle)
        if alternateTitles.contains(queryTitle) {
          value += 0.62
          signals.append(.titleAliasExact)
        }
      }
    }

    if let queryYear = query.year, let candidateYear = candidate.year {
      switch abs(queryYear - candidateYear) {
      case 0:
        value += 0.18
        signals.append(.yearExact)
      case 1:
        value += 0.09
        signals.append(.yearNear)
      default:
        value -= 0.15
        signals.append(.yearMismatch)
      }
    }

    if query.kind == .episode, let season = query.season, let episode = query.episode,
      candidate.availableEpisodes.contains(where: {
        $0.season == season && $0.episode == episode
      })
    {
      value += 0.20
      signals.append(.episodeExists)
    }

    value = min(1, max(0, (value * 1_000_000).rounded() / 1_000_000))
    let decision: MediaMatchDecision
    if value >= policy.automaticThreshold {
      decision = .automatic
    } else if value >= policy.reviewThreshold {
      decision = .review
    } else {
      decision = .unmatched
    }
    return ScoredMediaMetadataCandidate(
      candidate: candidate,
      score: value,
      decision: decision,
      signals: signals
    )
  }

  private func rejected(
    _ candidate: MediaMetadataCandidate,
    signal: MediaMatchSignal
  ) -> ScoredMediaMetadataCandidate {
    ScoredMediaMetadataCandidate(
      candidate: candidate,
      score: 0,
      decision: .rejected,
      signals: [signal]
    )
  }

  private func kindsAreCompatible(query: ParsedMediaKind, candidate: ParsedMediaKind) -> Bool {
    switch query {
    case .movie:
      candidate == .movie
    case .episode:
      candidate == .series || candidate == .episode
    case .series, .season, .extra, .unknown:
      false
    }
  }

  private func hasExactExternalID(
    _ queryIDs: [LocalMetadataExternalID],
    _ candidateIDs: [LocalMetadataExternalID]
  ) -> Bool {
    let candidateKeys = Set(candidateIDs.map(externalIDKey))
    return queryIDs.map(externalIDKey).contains(where: candidateKeys.contains)
  }

  private func externalIDKey(_ identifier: LocalMetadataExternalID) -> String {
    "\(identifier.provider.lowercased())\0\(identifier.namespace.lowercased())\0\(identifier.value)"
  }

  private func normalizeTitle(_ value: String) -> String {
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
}

import Foundation
import StellarCore

/// A logical media kind that can appear as a top-level PosterWall item.
public enum PosterWallMediaKind: String, Equatable, Hashable, Sendable {
  case movie
  case series
  case unknown
}

extension PosterWallMediaKind: Codable {
  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = PosterWallMediaKind(rawValue: value) ?? .unknown
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// A stable PosterWall section with section-specific ordering semantics.
public enum PosterWallSection: String, Equatable, Hashable, Sendable {
  case all
  case recentlyAdded = "recently_added"
  case continueWatching = "continue_watching"
  case recentlyPlayed = "recently_played"
  case movies
  case series
  case collection
  case unknown
}

extension PosterWallSection: Codable {
  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = PosterWallSection(rawValue: value) ?? .unknown
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// Supported deterministic PosterWall sort orders.
public enum PosterWallSort: String, Equatable, Hashable, Sendable {
  case title
  case addedAt = "added_at"
  case releaseDate = "release_date"
  case recentlyPlayed = "recently_played"
  case random
  case unknown
}

extension PosterWallSort: Codable {
  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = PosterWallSort(rawValue: value) ?? .unknown
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// Availability filtering applied after all playable versions are aggregated.
public enum PosterWallAvailabilityFilter: String, Equatable, Hashable, Sendable {
  case any
  case present
  case unavailable
  case unknown
}

extension PosterWallAvailabilityFilter: Codable {
  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = PosterWallAvailabilityFilter(rawValue: value) ?? .unknown
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// User playback-state filtering for one profile.
public enum PosterWallWatchFilter: String, Equatable, Hashable, Sendable {
  case any
  case unwatched
  case inProgress = "in_progress"
  case completed
  case unknown
}

extension PosterWallWatchFilter: Codable {
  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = PosterWallWatchFilter(rawValue: value) ?? .unknown
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// Aggregated source availability for a logical movie or series.
public enum PosterWallAvailability: String, Equatable, Hashable, Sendable {
  case present
  case offline
  case missing
  case unavailable
  case unknown
}

extension PosterWallAvailability: Codable {
  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = PosterWallAvailability(rawValue: value) ?? .unknown
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// Optional filters shared by list, section, collection, and search queries.
public struct PosterWallFilter: Codable, Equatable, Sendable {
  public let mediaKinds: [PosterWallMediaKind]
  public let sourceUIDs: [String]
  public let genres: [String]
  public let yearFrom: Int?
  public let yearThrough: Int?
  public let availability: PosterWallAvailabilityFilter
  public let watchState: PosterWallWatchFilter

  public init(
    mediaKinds: [PosterWallMediaKind] = [],
    sourceUIDs: [String] = [],
    genres: [String] = [],
    yearFrom: Int? = nil,
    yearThrough: Int? = nil,
    availability: PosterWallAvailabilityFilter = .any,
    watchState: PosterWallWatchFilter = .any
  ) throws {
    let normalizedSources = sourceUIDs.sorted()
    let normalizedGenres = genres.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.sorted()
    guard Set(mediaKinds).count == mediaKinds.count,
      !mediaKinds.contains(.unknown),
      Set(normalizedSources).count == normalizedSources.count,
      normalizedSources.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }),
      Set(normalizedGenres).count == normalizedGenres.count,
      normalizedGenres.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }),
      yearFrom.map({ (1000...9999).contains($0) }) ?? true,
      yearThrough.map({ (1000...9999).contains($0) }) ?? true,
      yearFrom.map({ $0 <= (yearThrough ?? 9999) }) ?? true,
      availability != .unknown,
      watchState != .unknown
    else {
      throw SDKError(code: .invalidConfiguration, message: "PosterWall filter is invalid")
    }
    self.mediaKinds = mediaKinds.sorted { $0.rawValue < $1.rawValue }
    self.sourceUIDs = normalizedSources
    self.genres = normalizedGenres
    self.yearFrom = yearFrom
    self.yearThrough = yearThrough
    self.availability = availability
    self.watchState = watchState
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        mediaKinds: container.decodeIfPresent([PosterWallMediaKind].self, forKey: .mediaKinds)
          ?? [],
        sourceUIDs: container.decodeIfPresent([String].self, forKey: .sourceUIDs) ?? [],
        genres: container.decodeIfPresent([String].self, forKey: .genres) ?? [],
        yearFrom: container.decodeIfPresent(Int.self, forKey: .yearFrom),
        yearThrough: container.decodeIfPresent(Int.self, forKey: .yearThrough),
        availability: container.decodeIfPresent(
          PosterWallAvailabilityFilter.self,
          forKey: .availability
        ) ?? .any,
        watchState: container.decodeIfPresent(PosterWallWatchFilter.self, forKey: .watchState)
          ?? .any
      )
    } catch let error as SDKError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message)
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case mediaKinds = "media_kinds"
    case sourceUIDs = "source_uids"
    case genres
    case yearFrom = "year_from"
    case yearThrough = "year_through"
    case availability
    case watchState = "watch_state"
  }
}

/// One validated, cursor-paginated PosterWall request.
public struct PosterWallQuery: Codable, Equatable, Sendable {
  public let section: PosterWallSection
  public let sort: PosterWallSort
  public let filter: PosterWallFilter
  public let searchText: String?
  public let profileUID: String?
  public let collectionUID: String?
  public let locale: String
  public let pageSize: Int
  public let cursor: String?
  public let libraryRevision: String?
  public let randomSeed: UInt64

  public init(
    section: PosterWallSection = .all,
    sort: PosterWallSort = .title,
    filter: PosterWallFilter? = nil,
    searchText: String? = nil,
    profileUID: String? = nil,
    collectionUID: String? = nil,
    locale: String = "und",
    pageSize: Int = 50,
    cursor: String? = nil,
    libraryRevision: String? = nil,
    randomSeed: UInt64 = 0
  ) throws {
    let normalizedSearch = searchText?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedLocale = locale.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedFilter = try filter ?? PosterWallFilter()
    guard section != .unknown, sort != .unknown,
      normalizedSearch?.isEmpty != true, normalizedSearch?.contains("\0") != true,
      profileUID?.isEmpty != true, profileUID?.contains("\0") != true,
      collectionUID?.isEmpty != true, collectionUID?.contains("\0") != true,
      !normalizedLocale.isEmpty, !normalizedLocale.contains("\0"),
      (1...200).contains(pageSize), cursor?.isEmpty != true, cursor?.contains("\0") != true,
      libraryRevision?.isEmpty != true, libraryRevision?.contains("\0") != true,
      ![PosterWallSection.continueWatching, .recentlyPlayed].contains(section)
        || profileUID != nil,
      section != .collection || collectionUID != nil,
      normalizedFilter.watchState == .any || profileUID != nil
    else {
      throw SDKError(code: .invalidConfiguration, message: "PosterWall query is invalid")
    }
    self.section = section
    self.sort = sort
    self.filter = normalizedFilter
    self.searchText = normalizedSearch
    self.profileUID = profileUID
    self.collectionUID = collectionUID
    self.locale = normalizedLocale
    self.pageSize = pageSize
    self.cursor = cursor
    self.libraryRevision = libraryRevision
    self.randomSeed = randomSeed
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        section: container.decodeIfPresent(PosterWallSection.self, forKey: .section) ?? .all,
        sort: container.decodeIfPresent(PosterWallSort.self, forKey: .sort) ?? .title,
        filter: container.decodeIfPresent(PosterWallFilter.self, forKey: .filter),
        searchText: container.decodeIfPresent(String.self, forKey: .searchText),
        profileUID: container.decodeIfPresent(String.self, forKey: .profileUID),
        collectionUID: container.decodeIfPresent(String.self, forKey: .collectionUID),
        locale: container.decodeIfPresent(String.self, forKey: .locale) ?? "und",
        pageSize: container.decodeIfPresent(Int.self, forKey: .pageSize) ?? 50,
        cursor: container.decodeIfPresent(String.self, forKey: .cursor),
        libraryRevision: container.decodeIfPresent(String.self, forKey: .libraryRevision),
        randomSeed: container.decodeIfPresent(UInt64.self, forKey: .randomSeed) ?? 0
      )
    } catch let error as SDKError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message)
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case section
    case sort
    case filter
    case searchText = "search_text"
    case profileUID = "profile_uid"
    case collectionUID = "collection_uid"
    case locale
    case pageSize = "page_size"
    case cursor
    case libraryRevision = "library_revision"
    case randomSeed = "random_seed"
  }
}

/// The selected artwork projection returned in list and detail results.
public struct PosterWallArtwork: Codable, Equatable, Sendable {
  public let artworkUID: String
  public let kind: String
  public let provider: String
  public let remoteReference: String?
  public let localRelativePath: String?
  public let width: Int?
  public let height: Int?

  private enum CodingKeys: String, CodingKey {
    case artworkUID = "artwork_uid"
    case kind
    case provider
    case remoteReference = "remote_reference"
    case localRelativePath = "local_relative_path"
    case width
    case height
  }
}

/// A stable, source-aggregated PosterWall list item.
public struct PosterWallItem: Codable, Equatable, Sendable {
  public let mediaUID: String
  public let kind: PosterWallMediaKind
  public let title: String
  public let subtitle: String?
  public let year: Int?
  public let poster: PosterWallArtwork?
  public let backdrop: PosterWallArtwork?
  public let progress: Double?
  public let unwatchedEpisodeCount: Int?
  public let availability: PosterWallAvailability
  public let metadataRevision: Int64

  private enum CodingKeys: String, CodingKey {
    case mediaUID = "media_uid"
    case kind
    case title
    case subtitle
    case year
    case poster
    case backdrop
    case progress
    case unwatchedEpisodeCount = "unwatched_episode_count"
    case availability
    case metadataRevision = "metadata_revision"
  }
}

/// One PosterWall page tied to a stable library revision.
public struct PosterWallPage: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let libraryRevision: String
  public let items: [PosterWallItem]
  public let nextCursor: String?

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case libraryRevision = "library_revision"
    case items
    case nextCursor = "next_cursor"
  }
}

/// One normalized audio, video, subtitle, or attachment stream in media details.
public struct PosterWallStream: Codable, Equatable, Sendable {
  public let index: Int
  public let kind: String
  public let codec: String?
  public let language: String
  public let title: String?
  public let isDefault: Bool
  public let isForced: Bool

  private enum CodingKeys: String, CodingKey {
    case index
    case kind
    case codec
    case language
    case title
    case isDefault = "is_default"
    case isForced = "is_forced"
  }
}

/// A playable file and its technical summary returned by media details.
public struct PosterWallPlayableFile: Codable, Equatable, Sendable {
  public let fileUID: String
  public let sourceUID: String
  public let relativePath: String
  public let bindingRole: String
  public let availability: String
  public let sizeBytes: Int64?
  public let durationMilliseconds: Int64?
  public let videoCodec: String?
  public let width: Int?
  public let height: Int?
  public let streams: [PosterWallStream]

  private enum CodingKeys: String, CodingKey {
    case fileUID = "file_uid"
    case sourceUID = "source_uid"
    case relativePath = "relative_path"
    case bindingRole = "binding_role"
    case availability
    case sizeBytes = "size_bytes"
    case durationMilliseconds = "duration_ms"
    case videoCodec = "video_codec"
    case width
    case height
    case streams
  }
}

/// One episode projection nested under a PosterWall season.
public struct PosterWallEpisode: Codable, Equatable, Sendable {
  public let mediaUID: String
  public let episodeNumber: Int
  public let title: String
  public let progress: Double?
  public let isCompleted: Bool
  public let files: [PosterWallPlayableFile]

  private enum CodingKeys: String, CodingKey {
    case mediaUID = "media_uid"
    case episodeNumber = "episode_number"
    case title
    case progress
    case isCompleted = "is_completed"
    case files
  }
}

/// One season projection nested under PosterWall series details.
public struct PosterWallSeason: Codable, Equatable, Sendable {
  public let mediaUID: String
  public let seasonNumber: Int
  public let title: String
  public let episodes: [PosterWallEpisode]

  private enum CodingKeys: String, CodingKey {
    case mediaUID = "media_uid"
    case seasonNumber = "season_number"
    case title
    case episodes
  }
}

/// A provider identity attached to the requested logical media entity.
public struct PosterWallExternalID: Codable, Equatable, Sendable {
  public let provider: String
  public let namespace: String
  public let value: String

  private enum CodingKeys: String, CodingKey {
    case provider
    case namespace
    case value
  }
}

/// Full media details for playback selection and season browsing.
public struct PosterWallDetails: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let libraryRevision: String
  public let item: PosterWallItem
  public let originalTitle: String?
  public let overview: String?
  public let tagline: String?
  public let contentRating: String?
  public let genres: [String]
  public let externalIDs: [PosterWallExternalID]
  public let artwork: [PosterWallArtwork]
  public let playableFiles: [PosterWallPlayableFile]
  public let seasons: [PosterWallSeason]

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case libraryRevision = "library_revision"
    case item
    case originalTitle = "original_title"
    case overview
    case tagline
    case contentRating = "content_rating"
    case genres
    case externalIDs = "external_ids"
    case artwork
    case playableFiles = "playable_files"
    case seasons
  }
}

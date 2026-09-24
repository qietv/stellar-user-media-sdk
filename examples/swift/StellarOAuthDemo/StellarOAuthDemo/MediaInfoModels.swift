import Foundation

// The service owns these identities. They are never interpreted as TMDB IDs or local media UIDs.
struct MediaInfoEntity: Decodable, Sendable {
  let objectID: String
  let objectKind: String
  let title: String?
  let originalTitle: String?
  let overview: String?
  let releaseDate: String?
  let firstAirDate: String?
  let lastAirDate: String?
  let airDate: String?
  let runtimeMinutes: Int?
  let genres: [MediaInfoGenre]?
  let originalLanguage: String?
  let status: String?
  let seriesID: String?
  let seasonID: String?
  let seasonNumber: Int?
  let episodeNumber: Int?
  let episodeCount: Int?
  let name: String?
  let biography: String?
  let birthDate: String?
  let deathDate: String?
  let knownForDepartment: String?
  let placeOfBirth: String?

  var displayTitle: String { title ?? name ?? "Untitled" }
  var date: String? { releaseDate ?? firstAirDate ?? airDate }

  enum CodingKeys: String, CodingKey {
    case objectID = "object_id"
    case objectKind = "object_kind"
    case title, overview, genres, status, name, biography
    case originalTitle = "original_title"
    case releaseDate = "release_date"
    case firstAirDate = "first_air_date"
    case lastAirDate = "last_air_date"
    case airDate = "air_date"
    case runtimeMinutes = "runtime_minutes"
    case originalLanguage = "original_language"
    case seriesID = "series_id"
    case seasonID = "season_id"
    case seasonNumber = "season_number"
    case episodeNumber = "episode_number"
    case episodeCount = "episode_count"
    case birthDate = "birth_date"
    case deathDate = "death_date"
    case knownForDepartment = "known_for_department"
    case placeOfBirth = "place_of_birth"
  }
}

struct MediaInfoGenre: Decodable, Sendable {
  let name: String
}

struct MediaInfoCredits: Decodable, Sendable {
  let ownerID: String
  let cast: [MediaInfoCast]
  let crew: [MediaInfoCrew]

  enum CodingKeys: String, CodingKey {
    case ownerID = "owner_id"
    case cast, crew
  }
}

struct MediaInfoCast: Decodable, Identifiable, Sendable {
  let personID: String
  let name: String
  let character: String?
  let order: Int
  let roles: [MediaInfoRole]
  var id: String { "\(personID):\(order):\(character ?? "")" }
  var subtitle: String {
    let values = roles.map(\.character).filter { !$0.isEmpty }
    return values.isEmpty ? (character ?? "Cast") : values.joined(separator: " / ")
  }
  enum CodingKeys: String, CodingKey {
    case personID = "person_id"
    case name, character, order, roles
  }
}

struct MediaInfoRole: Decodable, Sendable {
  let character: String
  let episodeCount: Int?
  enum CodingKeys: String, CodingKey {
    case character
    case episodeCount = "episode_count"
  }
}

struct MediaInfoCrew: Decodable, Identifiable, Sendable {
  let personID: String
  let name: String
  let department: String?
  let job: String?
  let order: Int
  let jobs: [MediaInfoJob]
  // A person may hold several separate credits; order distinguishes those rows.
  var id: String { "\(personID):\(order):\(department ?? ""):\(job ?? "")" }
  var subtitle: String {
    let values = jobs.map(\.job).filter { !$0.isEmpty }
    return values.isEmpty ? (job ?? department ?? "Crew") : values.joined(separator: " / ")
  }
  enum CodingKeys: String, CodingKey {
    case personID = "person_id"
    case name, department, job, order, jobs
  }
}

struct MediaInfoJob: Decodable, Sendable {
  let department: String
  let job: String
  let episodeCount: Int?
  enum CodingKeys: String, CodingKey {
    case department, job
    case episodeCount = "episode_count"
  }
}

struct MediaInfoFilmography: Decodable, Sendable {
  let personID: String
  let sourceCount: Int
  let truncated: Bool
  let items: [MediaInfoWork]
  enum CodingKeys: String, CodingKey {
    case personID = "person_id"
    case sourceCount = "source_count"
    case truncated, items
  }
}

struct MediaInfoWork: Decodable, Identifiable, Sendable {
  let mediaID: String
  let mediaKind: String
  let title: String
  let character: String?
  let department: String?
  let job: String?
  let date: String?
  let order: Int
  var id: String { "\(mediaID):\(order):\(job ?? ""):\(character ?? "")" }
  var subtitle: String { character ?? job ?? department ?? "" }
  enum CodingKeys: String, CodingKey {
    case mediaID = "media_id"
    case mediaKind = "media_kind"
    case title, character, department, job, date, order
  }
}

struct MediaInfoPage<Item: Decodable & Sendable>: Decodable, Sendable {
  let metadataVersion: String
  let items: [Item]
  let nextCursor: String?
  enum CodingKeys: String, CodingKey {
    case metadataVersion = "metadata_version"
    case items
    case nextCursor = "next_cursor"
  }
}

struct MediaInfoEpisodeOrder: Decodable, Identifiable, Sendable {
  let orderID: String
  let seriesID: String
  let orderKind: String
  let label: String
  let entryCount: Int
  var id: String { orderID }
  enum CodingKeys: String, CodingKey {
    case orderID = "order_id"
    case seriesID = "series_id"
    case orderKind = "order_kind"
    case label
    case entryCount = "entry_count"
  }
}

struct MediaInfoEpisodeEntry: Decodable, Identifiable, Sendable {
  let episodeID: String
  let seasonID: String
  let ordinal: Int
  let seasonNumber: Int
  let episodeNumber: Int
  // Alternate orders may refer to the same episode more than once.
  var id: String { "\(ordinal):\(episodeID)" }
  var coordinate: MediaInfoCoordinate { .init(season: seasonNumber, episode: episodeNumber) }
  enum CodingKeys: String, CodingKey {
    case episodeID = "episode_id"
    case seasonID = "season_id"
    case ordinal
    case seasonNumber = "season_number"
    case episodeNumber = "episode_number"
  }
}

struct MediaInfoCoordinate: Hashable, Sendable {
  let season: Int
  let episode: Int
  var label: String { String(format: "S%02d E%02d", season, episode) }
}

/// Binds alternate order entries to local *aired* coordinates using identity, never display numbers.
struct MediaInfoEpisodeIndex: Sendable {
  private let coordinates: [String: MediaInfoCoordinate]
  init(airedEntries: [MediaInfoEpisodeEntry]) {
    var values: [String: MediaInfoCoordinate] = [:]
    for entry in airedEntries { values[entry.episodeID] = entry.coordinate }
    coordinates = values
  }
  func airedCoordinate(for entry: MediaInfoEpisodeEntry) -> MediaInfoCoordinate? {
    coordinates[entry.episodeID]
  }
}

enum MediaInfoPaginationError: Error { case changedVersion, repeatedCursor, tooManyItems }

/// Pages from different catalog generations must never be combined into one episode order.
struct MediaInfoPageAccumulator<Item: Decodable & Sendable> {
  private(set) var items: [Item] = []
  private var version: String?
  private var cursors: Set<String> = []
  let maximumItems: Int

  init(maximumItems: Int) { self.maximumItems = maximumItems }

  mutating func append(_ page: MediaInfoPage<Item>) throws -> String? {
    if let version, version != page.metadataVersion {
      throw MediaInfoPaginationError.changedVersion
    }
    guard items.count + page.items.count <= maximumItems else {
      throw MediaInfoPaginationError.tooManyItems
    }
    if let cursor = page.nextCursor, cursor.isEmpty || !cursors.insert(cursor).inserted {
      throw MediaInfoPaginationError.repeatedCursor
    }
    version = page.metadataVersion
    items.append(contentsOf: page.items)
    return page.nextCursor
  }
}

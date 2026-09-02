import Foundation
import StellarCore

/// An application-level TMDB credential that never renders credential material.
public struct TMDBCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  fileprivate let authentication: TMDBAuthentication

  public init(readAccessToken: String) throws {
    guard Self.validSecret(readAccessToken, maximumUTF8Count: 4_096) else {
      throw SDKError(code: .invalidConfiguration, message: "TMDB credential is invalid")
    }
    authentication = .readAccessToken(readAccessToken)
  }

  /// Creates a v3 query-key credential supplied by the host application at runtime.
  public init(apiKey: String) throws {
    guard apiKey.range(of: #"^[A-Fa-f0-9]{32}$"#, options: .regularExpression) != nil else {
      throw SDKError(code: .invalidConfiguration, message: "TMDB credential is invalid")
    }
    authentication = .apiKey(apiKey)
  }

  /// A representation that never contains the API key or read token.
  public var description: String { "<TMDBCredential redacted>" }

  /// A representation that never contains the API key or read token.
  public var debugDescription: String { description }

  private static func validSecret(_ value: String, maximumUTF8Count: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maximumUTF8Count && !value.contains("\0")
      && !value.contains("\r") && !value.contains("\n")
  }
}

private enum TMDBAuthentication: Sendable {
  case readAccessToken(String)
  case apiKey(String)
}

/// Locale, content, and bounded-result policy for the TMDB adapter.
public struct TMDBProviderConfiguration: Equatable, Sendable {
  public let language: String
  public let artworkLanguage: String
  public let includeAdult: Bool
  public let maximumSearchResults: Int

  public init(
    language: String = "en-US",
    artworkLanguage: String? = nil,
    includeAdult: Bool = false,
    maximumSearchResults: Int = 5
  ) throws {
    let normalizedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedArtworkLanguage = (artworkLanguage ?? language)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.isLanguageTag(normalizedLanguage),
      Self.isLanguageTag(normalizedArtworkLanguage),
      (1...20).contains(maximumSearchResults)
    else {
      throw SDKError(code: .invalidConfiguration, message: "TMDB configuration is invalid")
    }
    self.language = normalizedLanguage
    self.artworkLanguage = normalizedArtworkLanguage
    self.includeAdult = includeAdult
    self.maximumSearchResults = maximumSearchResults
  }

  private static func isLanguageTag(_ value: String) -> Bool {
    value.range(
      of: #"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})?$"#,
      options: .regularExpression
    ) != nil
  }
}

/// A credential-safe request value used by injectable TMDB transports.
public struct TMDBHTTPRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public let method: String
  public let url: URL
  public let headers: [String: String]

  public init(method: String, url: URL, headers: [String: String] = [:]) {
    self.method = method
    self.url = url
    self.headers = headers
  }

  /// A representation that hides the URL query and every header value.
  public var description: String { "<TMDBHTTPRequest method=\(method) redacted>" }

  /// A representation that hides the URL query and every header value.
  public var debugDescription: String { description }
}

/// The bounded HTTP response consumed by the TMDB adapter.
public struct TMDBHTTPResponse: Sendable {
  public let statusCode: Int
  public let headers: [String: String]
  public let body: Data

  public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
    self.statusCode = statusCode
    self.headers = headers
    self.body = body
  }
}

/// Injectable HTTP boundary for live TMDB access and server-free fixture replay.
public protocol TMDBTransport: Sendable {
  func send(_ request: TMDBHTTPRequest) async throws -> TMDBHTTPResponse
}

/// Ephemeral URLSession transport that refuses automatic redirects carrying credentials.
public struct URLSessionTMDBTransport: TMDBTransport {
  public init() {}

  public func send(_ request: TMDBHTTPRequest) async throws -> TMDBHTTPResponse {
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = request.method
    for (name, value) in request.headers {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }
    let session = URLSession(
      configuration: .ephemeral,
      delegate: TMDBNoRedirectDelegate.shared,
      delegateQueue: nil
    )
    defer { session.invalidateAndCancel() }
    do {
      let (data, response) = try await session.data(for: urlRequest)
      guard let response = response as? HTTPURLResponse else {
        throw SDKError(code: .remoteUnavailable, message: "TMDB response is not HTTP")
      }
      var headers: [String: String] = [:]
      for (name, value) in response.allHeaderFields {
        headers[String(describing: name).lowercased()] = String(describing: value)
      }
      return TMDBHTTPResponse(statusCode: response.statusCode, headers: headers, body: data)
    } catch let error as SDKError {
      throw error
    } catch let error as URLError {
      switch error.code {
      case .cancelled:
        throw SDKError(code: .cancelled, message: "TMDB request cancelled")
      case .notConnectedToInternet, .networkConnectionLost:
        throw SDKError(code: .networkUnavailable, message: "TMDB network is unavailable")
      case .serverCertificateHasBadDate, .serverCertificateUntrusted,
        .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
        throw SDKError(code: .forbidden, message: "TMDB TLS validation failed")
      case .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
        throw SDKError(code: .remoteUnavailable, message: "TMDB service is unavailable")
      default:
        throw SDKError(code: .remoteUnavailable, message: "TMDB request failed")
      }
    } catch {
      throw SDKError(code: .remoteUnavailable, message: "TMDB request failed")
    }
  }
}

/// One stable TMDB artwork reference returned by a details response.
public struct TMDBArtworkImage: Codable, Equatable, Sendable {
  public let kind: LocalMetadataArtworkKind
  public let remotePath: String
  public let language: String?
  public let width: Int?
  public let height: Int?
  public let score: Double

  public init(
    kind: LocalMetadataArtworkKind,
    remotePath: String,
    language: String? = nil,
    width: Int? = nil,
    height: Int? = nil,
    score: Double = 0
  ) throws {
    guard kind != .unknown, remotePath.hasPrefix("/"), !remotePath.contains("\0"),
      URLComponents(string: remotePath)?.query == nil,
      URLComponents(string: remotePath)?.fragment == nil,
      language?.contains("\0") != true,
      width.map({ $0 > 0 }) ?? true, height.map({ $0 > 0 }) ?? true,
      score.isFinite, score >= 0
    else {
      throw SDKError(code: .parseFailure, message: "TMDB artwork is invalid")
    }
    self.kind = kind
    self.remotePath = remotePath
    self.language = language
    self.width = width
    self.height = height
    self.score = score
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        kind: container.decode(LocalMetadataArtworkKind.self, forKey: .kind),
        remotePath: container.decode(String.self, forKey: .remotePath),
        language: container.decodeIfPresent(String.self, forKey: .language),
        width: container.decodeIfPresent(Int.self, forKey: .width),
        height: container.decodeIfPresent(Int.self, forKey: .height),
        score: container.decodeIfPresent(Double.self, forKey: .score) ?? 0
      )
    } catch let error as SDKError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message)
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case remotePath = "remote_path"
    case language
    case width
    case height
    case score
  }
}

/// Normalized provider details without exposing TMDB's raw response shape.
public struct TMDBMediaDetails: Codable, Equatable, Sendable {
  public let providerID: String
  public let kind: ParsedMediaKind
  public let metadata: LocalMetadataDocument
  public let aliases: [String]
  public let artwork: [TMDBArtworkImage]

  public init(
    providerID: String,
    kind: ParsedMediaKind,
    metadata: LocalMetadataDocument,
    aliases: [String] = [],
    artwork: [TMDBArtworkImage] = []
  ) throws {
    guard !providerID.isEmpty, !providerID.contains("\0"),
      kind == .movie || kind == .series || kind == .episode,
      metadata.kind == kind,
      aliases.allSatisfy({ !$0.isEmpty && !$0.contains("\0") })
    else {
      throw SDKError(code: .parseFailure, message: "TMDB media details are invalid")
    }
    self.providerID = providerID
    self.kind = kind
    self.metadata = metadata
    self.aliases = aliases
    self.artwork = artwork
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        providerID: container.decode(String.self, forKey: .providerID),
        kind: container.decode(ParsedMediaKind.self, forKey: .kind),
        metadata: container.decode(LocalMetadataDocument.self, forKey: .metadata),
        aliases: container.decodeIfPresent([String].self, forKey: .aliases) ?? [],
        artwork: container.decodeIfPresent([TMDBArtworkImage].self, forKey: .artwork) ?? []
      )
    } catch let error as SDKError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message)
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case providerID = "provider_id"
    case kind
    case metadata
    case aliases
    case artwork
  }
}

/// TMDB image host and supported-size configuration used to resolve stable remote paths.
public struct TMDBImageConfiguration: Codable, Equatable, Sendable {
  public let secureBaseURL: URL
  public let backdropSizes: [String]
  public let logoSizes: [String]
  public let posterSizes: [String]
  public let profileSizes: [String]
  public let stillSizes: [String]

  public init(
    secureBaseURL: URL,
    backdropSizes: [String],
    logoSizes: [String],
    posterSizes: [String],
    profileSizes: [String],
    stillSizes: [String]
  ) throws {
    guard secureBaseURL.scheme?.lowercased() == "https", secureBaseURL.host?.isEmpty == false,
      secureBaseURL.user == nil, secureBaseURL.password == nil,
      secureBaseURL.query == nil, secureBaseURL.fragment == nil,
      [backdropSizes, logoSizes, posterSizes, profileSizes, stillSizes]
        .allSatisfy(Self.validSizes)
    else {
      throw SDKError(code: .parseFailure, message: "TMDB image configuration is invalid")
    }
    self.secureBaseURL = secureBaseURL
    self.backdropSizes = backdropSizes
    self.logoSizes = logoSizes
    self.posterSizes = posterSizes
    self.profileSizes = profileSizes
    self.stillSizes = stillSizes
  }

  /// Resolves a response path only when the requested kind and size are advertised by TMDB.
  public func imageURL(
    remotePath: String,
    kind: LocalMetadataArtworkKind,
    size: String = "original"
  ) throws -> URL {
    let sizes: [String]
    switch kind {
    case .backdrop: sizes = backdropSizes
    case .logo: sizes = logoSizes
    case .poster: sizes = posterSizes
    case .thumbnail: sizes = stillSizes
    case .banner, .unknown:
      throw SDKError(code: .invalidConfiguration, message: "TMDB artwork kind is unsupported")
    }
    guard sizes.contains(size), remotePath.hasPrefix("/"), !remotePath.contains("\0"),
      URLComponents(string: remotePath)?.query == nil,
      URLComponents(string: remotePath)?.fragment == nil
    else {
      throw SDKError(code: .invalidConfiguration, message: "TMDB artwork variant is invalid")
    }
    return
      secureBaseURL
      .appendingPathComponent(size, isDirectory: true)
      .appendingPathComponent(String(remotePath.dropFirst()))
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        secureBaseURL: container.decode(URL.self, forKey: .secureBaseURL),
        backdropSizes: container.decode([String].self, forKey: .backdropSizes),
        logoSizes: container.decode([String].self, forKey: .logoSizes),
        posterSizes: container.decode([String].self, forKey: .posterSizes),
        profileSizes: container.decode([String].self, forKey: .profileSizes),
        stillSizes: container.decode([String].self, forKey: .stillSizes)
      )
    } catch let error as SDKError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message)
      )
    }
  }

  private static func validSizes(_ values: [String]) -> Bool {
    !values.isEmpty && Set(values).count == values.count
      && values.allSatisfy { !$0.isEmpty && !$0.contains("\0") && !$0.contains("/") }
  }

  private enum CodingKeys: String, CodingKey {
    case secureBaseURL = "secure_base_url"
    case backdropSizes = "backdrop_sizes"
    case logoSizes = "logo_sizes"
    case posterSizes = "poster_sizes"
    case profileSizes = "profile_sizes"
    case stillSizes = "still_sizes"
  }
}

/// Concrete TMDB v3 adapter for search, details, episode validation, and image configuration.
public struct TMDBMetadataProvider: MediaMetadataProviding {
  private let credential: TMDBCredential
  private let configuration: TMDBProviderConfiguration
  private let transport: any TMDBTransport

  public init(
    credential: TMDBCredential,
    configuration: TMDBProviderConfiguration,
    transport: any TMDBTransport = URLSessionTMDBTransport()
  ) {
    self.credential = credential
    self.configuration = configuration
    self.transport = transport
  }

  public func search(_ query: MediaMatchQuery) async throws -> [MediaMetadataCandidate] {
    if let identifier = directTMDBIdentifier(for: query) {
      return try await searchDirect(identifier: identifier, query: query)
    }
    if let identifier = supportedExternalIdentifier(for: query) {
      let candidates = try await searchExternal(identifier: identifier, query: query)
      if !candidates.isEmpty || query.title == nil { return candidates }
    }
    guard let title = query.title else { return [] }
    return try await searchTitle(title, query: query)
  }

  /// Fetches normalized movie details and artwork by a positive TMDB movie ID.
  public func movieDetails(id: Int64) async throws -> TMDBMediaDetails {
    try validateID(id)
    let raw: TMDBRawMedia = try await get(
      path: ["movie", String(id)],
      query: detailsQuery
    )
    return try makeDetails(raw, kind: .movie)
  }

  /// Fetches normalized series details and artwork by a positive TMDB series ID.
  public func seriesDetails(id: Int64) async throws -> TMDBMediaDetails {
    try validateID(id)
    let raw: TMDBRawMedia = try await get(
      path: ["tv", String(id)],
      query: detailsQuery
    )
    return try makeDetails(raw, kind: .series)
  }

  /// Fetches one normalized episode with both its TMDB episode and series identities.
  public func episodeDetails(seriesID: Int64, season: Int, episode: Int) async throws
    -> TMDBMediaDetails
  {
    try validateID(seriesID)
    guard season >= 0, episode >= 0 else {
      throw SDKError(code: .invalidConfiguration, message: "TMDB episode coordinate is invalid")
    }
    let raw: TMDBRawMedia = try await get(
      path: ["tv", String(seriesID), "season", String(season), "episode", String(episode)],
      query: detailsQuery
    )
    return try makeDetails(raw, kind: .episode, seriesID: seriesID)
  }

  /// Fetches the current HTTPS image host and advertised variant sizes.
  public func imageConfiguration() async throws -> TMDBImageConfiguration {
    let response: TMDBRawConfiguration = try await get(path: ["configuration"], query: [])
    guard let url = URL(string: response.images.secureBaseURL) else {
      throw SDKError(code: .parseFailure, message: "TMDB image base URL is invalid")
    }
    return try TMDBImageConfiguration(
      secureBaseURL: url,
      backdropSizes: response.images.backdropSizes,
      logoSizes: response.images.logoSizes,
      posterSizes: response.images.posterSizes,
      profileSizes: response.images.profileSizes,
      stillSizes: response.images.stillSizes
    )
  }

  private func searchDirect(
    identifier: LocalMetadataExternalID,
    query: MediaMatchQuery
  ) async throws -> [MediaMetadataCandidate] {
    guard let id = Int64(identifier.value), id > 0 else {
      throw SDKError(code: .parseFailure, message: "TMDB identifier is invalid")
    }
    do {
      switch query.kind {
      case .movie:
        let details = try await movieDetails(id: id)
        return [try makeCandidate(details: details, attachedIDs: [identifier])]
      case .episode:
        guard let season = query.season, let episode = query.episode else { return [] }
        _ = try await episodeDetails(seriesID: id, season: season, episode: episode)
        let details = try await seriesDetails(id: id)
        return [
          try makeCandidate(
            details: details,
            attachedIDs: [identifier],
            availableEpisodes: [try MediaEpisodeCoordinate(season: season, episode: episode)]
          )
        ]
      case .series, .season, .extra, .unknown:
        return []
      }
    } catch let error as SDKError where error.code == .metadataNotFound {
      return []
    }
  }

  private func searchExternal(
    identifier: LocalMetadataExternalID,
    query: MediaMatchQuery
  ) async throws -> [MediaMetadataCandidate] {
    guard let externalSource = Self.externalSource(for: identifier.provider) else { return [] }
    let response: TMDBRawFindResponse = try await get(
      path: ["find", identifier.value],
      query: [
        URLQueryItem(name: "external_source", value: externalSource),
        URLQueryItem(name: "language", value: configuration.language),
      ]
    )
    var candidates: [MediaMetadataCandidate] = []
    switch query.kind {
    case .movie:
      for result in response.movieResults.prefix(configuration.maximumSearchResults) {
        candidates.append(
          try makeCandidate(raw: result, kind: .movie, attachedIDs: [identifier])
        )
      }
    case .episode:
      let coordinate = try MediaEpisodeCoordinate(
        season: query.season ?? 0,
        episode: query.episode ?? 0
      )
      for result in response.tvEpisodeResults.prefix(configuration.maximumSearchResults)
      where result.seasonNumber == query.season && result.episodeNumber == query.episode {
        candidates.append(
          try makeCandidate(
            raw: result,
            kind: .episode,
            attachedIDs: [identifier],
            availableEpisodes: [coordinate]
          )
        )
      }
      let remaining = max(0, configuration.maximumSearchResults - candidates.count)
      for result in response.tvResults.prefix(remaining) {
        if try await episodeExists(
          seriesID: result.id,
          season: query.season ?? 0,
          episode: query.episode ?? 0
        ) {
          candidates.append(
            try makeCandidate(
              raw: result,
              kind: .series,
              attachedIDs: [identifier],
              availableEpisodes: [coordinate]
            )
          )
        }
      }
    case .series, .season, .extra, .unknown:
      break
    }
    return deduplicated(candidates)
  }

  private func searchTitle(_ title: String, query: MediaMatchQuery) async throws
    -> [MediaMetadataCandidate]
  {
    let endpoint = query.kind == .movie ? "movie" : "tv"
    var items = [
      URLQueryItem(name: "query", value: title),
      URLQueryItem(name: "language", value: configuration.language),
      URLQueryItem(name: "include_adult", value: configuration.includeAdult ? "true" : "false"),
      URLQueryItem(name: "page", value: "1"),
    ]
    if let year = query.year {
      items.append(
        URLQueryItem(
          name: query.kind == .movie ? "primary_release_year" : "first_air_date_year",
          value: String(year)
        )
      )
    }
    let response: TMDBRawSearchResponse = try await get(
      path: ["search", endpoint],
      query: items
    )
    let results = response.results.prefix(configuration.maximumSearchResults)
    if query.kind == .movie {
      return try results.map { try makeCandidate(raw: $0, kind: .movie) }
    }
    let coordinate = try MediaEpisodeCoordinate(
      season: query.season ?? 0,
      episode: query.episode ?? 0
    )
    var candidates: [MediaMetadataCandidate] = []
    for result in results {
      if try await episodeExists(
        seriesID: result.id,
        season: query.season ?? 0,
        episode: query.episode ?? 0
      ) {
        candidates.append(
          try makeCandidate(
            raw: result,
            kind: .series,
            availableEpisodes: [coordinate]
          )
        )
      }
    }
    return candidates
  }

  private func episodeExists(seriesID: Int64, season: Int, episode: Int) async throws -> Bool {
    do {
      let _: TMDBRawMedia = try await get(
        path: ["tv", String(seriesID), "season", String(season), "episode", String(episode)],
        query: [URLQueryItem(name: "language", value: configuration.language)]
      )
      return true
    } catch let error as SDKError where error.code == .metadataNotFound {
      return false
    }
  }

  private func makeCandidate(
    details: TMDBMediaDetails,
    attachedIDs: [LocalMetadataExternalID] = [],
    availableEpisodes: [MediaEpisodeCoordinate] = []
  ) throws -> MediaMetadataCandidate {
    guard let title = details.metadata.title ?? details.metadata.seriesTitle else {
      throw SDKError(code: .parseFailure, message: "TMDB candidate title is missing")
    }
    return try MediaMetadataCandidate(
      provider: "tmdb",
      candidateID: details.providerID,
      kind: details.kind,
      title: title,
      originalTitle: details.metadata.originalTitle,
      aliases: details.aliases,
      year: details.metadata.year,
      availableEpisodes: availableEpisodes,
      externalIDs: mergedExternalIDs(details.metadata.externalIDs + attachedIDs),
      popularity: 0
    )
  }

  private func makeCandidate(
    raw: TMDBRawMedia,
    kind: ParsedMediaKind,
    attachedIDs: [LocalMetadataExternalID] = [],
    availableEpisodes: [MediaEpisodeCoordinate] = []
  ) throws -> MediaMetadataCandidate {
    guard raw.id > 0 else {
      throw SDKError(code: .parseFailure, message: "TMDB candidate identifier is invalid")
    }
    let title = raw.title ?? raw.name
    guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw SDKError(code: .parseFailure, message: "TMDB candidate title is missing")
    }
    var identifiers = attachedIDs
    identifiers.append(
      try LocalMetadataExternalID(
        provider: "tmdb",
        namespace: Self.namespace(for: kind),
        value: String(raw.id),
        isPrimary: true
      )
    )
    if kind == .episode, let seriesID = raw.showID {
      identifiers.append(
        try LocalMetadataExternalID(
          provider: "tmdb",
          namespace: "series",
          value: String(seriesID),
          isPrimary: true
        )
      )
    }
    return try MediaMetadataCandidate(
      provider: "tmdb",
      candidateID: String(raw.id),
      kind: kind,
      title: title,
      originalTitle: raw.originalTitle ?? raw.originalName,
      year: Self.year(from: raw.releaseDate ?? raw.firstAirDate ?? raw.airDate),
      availableEpisodes: availableEpisodes,
      externalIDs: mergedExternalIDs(identifiers),
      popularity: max(0, raw.popularity ?? 0)
    )
  }

  private func makeDetails(
    _ raw: TMDBRawMedia,
    kind: ParsedMediaKind,
    seriesID: Int64? = nil
  ) throws -> TMDBMediaDetails {
    guard raw.id > 0 else {
      throw SDKError(code: .parseFailure, message: "TMDB details identifier is invalid")
    }
    let title = raw.title ?? raw.name
    guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw SDKError(code: .parseFailure, message: "TMDB details title is missing")
    }
    var externalIDs = try makeExternalIDs(raw.externalIDs, namespace: Self.namespace(for: kind))
    externalIDs.append(
      try LocalMetadataExternalID(
        provider: "tmdb",
        namespace: Self.namespace(for: kind),
        value: String(raw.id),
        isPrimary: true
      )
    )
    if let seriesID {
      externalIDs.append(
        try LocalMetadataExternalID(
          provider: "tmdb",
          namespace: "series",
          value: String(seriesID),
          isPrimary: true
        )
      )
    }
    let artwork = try makeArtwork(raw)
    let metadataArtwork = try artwork.map {
      try LocalMetadataArtwork(kind: $0.kind, location: $0.remotePath)
    }
    let runtimeMilliseconds = try Self.runtimeMilliseconds(
      from: raw.runtime ?? raw.episodeRunTime?.first
    )
    let document = try LocalMetadataDocument(
      kind: kind,
      title: title,
      originalTitle: raw.originalTitle ?? raw.originalName,
      year: Self.year(from: raw.releaseDate ?? raw.firstAirDate ?? raw.airDate),
      overview: raw.overview,
      tagline: raw.tagline,
      releaseDate: raw.releaseDate ?? raw.firstAirDate ?? raw.airDate,
      runtimeMilliseconds: runtimeMilliseconds,
      season: kind == .episode ? raw.seasonNumber : nil,
      episode: kind == .episode ? raw.episodeNumber : nil,
      externalIDs: mergedExternalIDs(externalIDs),
      artwork: metadataArtwork
    )
    return try TMDBMediaDetails(
      providerID: String(raw.id),
      kind: kind,
      metadata: document,
      aliases: raw.alternativeTitles?.values ?? [],
      artwork: artwork
    )
  }

  private func makeExternalIDs(
    _ raw: TMDBRawExternalIDs?,
    namespace: String
  ) throws -> [LocalMetadataExternalID] {
    guard let raw else { return [] }
    if let tvdbID = raw.tvdbID, tvdbID <= 0 {
      throw SDKError(code: .parseFailure, message: "TMDB external identifier is invalid")
    }
    return try [
      ("imdb", raw.imdbID),
      ("tvdb", raw.tvdbID.map(String.init)),
      ("wikidata", raw.wikidataID),
    ].compactMap { provider, value in
      guard let value, !value.isEmpty else { return nil }
      return try LocalMetadataExternalID(
        provider: provider,
        namespace: namespace,
        value: value
      )
    }
  }

  private func makeArtwork(_ raw: TMDBRawMedia) throws -> [TMDBArtworkImage] {
    var values: [(LocalMetadataArtworkKind, TMDBRawImage)] = []
    if let images = raw.images {
      values += images.posters.map { (.poster, $0) }
      values += images.backdrops.map { (.backdrop, $0) }
      values += images.logos.map { (.logo, $0) }
      values += images.stills.map { (.thumbnail, $0) }
    }
    if values.isEmpty {
      if let path = raw.posterPath {
        values.append((.poster, TMDBRawImage(filePath: path)))
      }
      if let path = raw.backdropPath {
        values.append((.backdrop, TMDBRawImage(filePath: path)))
      }
      if let path = raw.stillPath {
        values.append((.thumbnail, TMDBRawImage(filePath: path)))
      }
    }
    var seen: Set<String> = []
    return try values.compactMap { kind, image in
      let key = "\(kind.rawValue)\0\(image.filePath)"
      guard seen.insert(key).inserted else { return nil }
      return try TMDBArtworkImage(
        kind: kind,
        remotePath: image.filePath,
        language: image.language,
        width: image.width,
        height: image.height,
        score: max(0, image.voteAverage ?? 0)
      )
    }.sorted {
      ($0.kind.rawValue, -$0.score, $0.remotePath)
        < ($1.kind.rawValue, -$1.score, $1.remotePath)
    }
  }

  private func mergedExternalIDs(_ values: [LocalMetadataExternalID]) -> [LocalMetadataExternalID] {
    var seen: Set<String> = []
    return values.filter {
      seen.insert("\($0.provider.lowercased())\0\($0.namespace.lowercased())\0\($0.value)")
        .inserted
    }
  }

  private func deduplicated(_ values: [MediaMetadataCandidate]) -> [MediaMetadataCandidate] {
    var seen: Set<String> = []
    return values.filter { seen.insert("\($0.kind.rawValue)\0\($0.candidateID)").inserted }
  }

  private func directTMDBIdentifier(for query: MediaMatchQuery) -> LocalMetadataExternalID? {
    let namespace = query.kind == .movie ? "movie" : "series"
    return query.externalIDs.first {
      $0.provider.caseInsensitiveCompare("tmdb") == .orderedSame
        && ($0.namespace.caseInsensitiveCompare(namespace) == .orderedSame
          || (namespace == "series" && $0.namespace.caseInsensitiveCompare("tv") == .orderedSame))
    }
  }

  private func supportedExternalIdentifier(for query: MediaMatchQuery) -> LocalMetadataExternalID? {
    query.externalIDs
      .filter { Self.externalSource(for: $0.provider) != nil }
      .sorted {
        ($0.provider.lowercased(), $0.namespace.lowercased(), $0.value)
          < ($1.provider.lowercased(), $1.namespace.lowercased(), $1.value)
      }
      .first
  }

  private static func externalSource(for provider: String) -> String? {
    switch provider.lowercased() {
    case "imdb": "imdb_id"
    case "tvdb": "tvdb_id"
    case "wikidata": "wikidata_id"
    default: nil
    }
  }

  private static func namespace(for kind: ParsedMediaKind) -> String {
    switch kind {
    case .movie: "movie"
    case .series: "series"
    case .episode: "episode"
    case .season: "season"
    case .extra: "extra"
    case .unknown: "unknown"
    }
  }

  private static func year(from date: String?) -> Int? {
    guard let date, date.count >= 4, let year = Int(date.prefix(4)), (1000...9999).contains(year)
    else { return nil }
    return year
  }

  private static func runtimeMilliseconds(from minutes: Int?) throws -> Int64? {
    guard let minutes else { return nil }
    guard minutes >= 0, Int64(minutes) <= Int64.max / 60_000 else {
      throw SDKError(code: .parseFailure, message: "TMDB runtime is invalid")
    }
    return Int64(minutes) * 60_000
  }

  private var detailsQuery: [URLQueryItem] {
    [
      URLQueryItem(name: "language", value: configuration.language),
      URLQueryItem(
        name: "append_to_response",
        value: "external_ids,images,alternative_titles"
      ),
      URLQueryItem(name: "include_image_language", value: includeImageLanguage),
    ]
  }

  private var includeImageLanguage: String {
    let primary =
      configuration.artworkLanguage.split(separator: "-", maxSplits: 1)
      .first.map(String.init)?.lowercased() ?? "en"
    return Array(Set([primary, "en", "null"])).sorted().joined(separator: ",")
  }

  private func validateID(_ id: Int64) throws {
    guard id > 0 else {
      throw SDKError(code: .invalidConfiguration, message: "TMDB identifier is invalid")
    }
  }

  private func get<Response: Decodable>(
    path: [String],
    query: [URLQueryItem]
  ) async throws -> Response {
    let request = try makeRequest(path: path, query: query)
    let response: TMDBHTTPResponse
    do {
      response = try await transport.send(request)
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .remoteUnavailable, message: "TMDB transport failed")
    }
    guard response.body.count <= Self.maximumResponseBytes else {
      throw SDKError(code: .parseFailure, message: "TMDB response exceeds size limit")
    }
    switch response.statusCode {
    case 200...299:
      do {
        return try JSONDecoder().decode(Response.self, from: response.body)
      } catch {
        throw SDKError(code: .parseFailure, message: "TMDB response JSON is invalid")
      }
    case 401:
      throw SDKError(code: .unauthorized, message: "TMDB authorization failed")
    case 403:
      throw SDKError(code: .forbidden, message: "TMDB request is forbidden")
    case 404:
      throw SDKError(code: .metadataNotFound, message: "TMDB metadata was not found")
    case 429:
      throw SDKError(
        code: .rateLimited,
        message: "TMDB rate limit exceeded",
        retryAfterMilliseconds: Self.retryAfterMilliseconds(response.headers)
      )
    case 500...599:
      throw SDKError(code: .remoteUnavailable, message: "TMDB service is unavailable")
    default:
      throw SDKError(code: .remoteUnavailable, message: "TMDB request failed")
    }
  }

  private func makeRequest(path: [String], query: [URLQueryItem]) throws -> TMDBHTTPRequest {
    var url = Self.apiRoot
    for component in path {
      guard !component.isEmpty, !component.contains("\0"), !component.contains("/") else {
        throw SDKError(code: .invalidConfiguration, message: "TMDB request path is invalid")
      }
      url.appendPathComponent(component)
    }
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw SDKError(code: .invalidConfiguration, message: "TMDB request URL is invalid")
    }
    var authenticatedQuery = query
    var headers = [
      "Accept": "application/json",
      "User-Agent": "StellarUserMediaSDK/0.1",
    ]
    switch credential.authentication {
    case .readAccessToken(let token):
      headers["Authorization"] = "Bearer \(token)"
    case .apiKey(let apiKey):
      guard
        !authenticatedQuery.contains(where: {
          $0.name.caseInsensitiveCompare("api_key") == .orderedSame
        })
      else {
        throw SDKError(code: .invalidConfiguration, message: "TMDB authentication query is invalid")
      }
      authenticatedQuery.append(URLQueryItem(name: "api_key", value: apiKey))
    }
    components.queryItems = authenticatedQuery.sorted {
      ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "")
    }
    guard let requestURL = components.url else {
      throw SDKError(code: .invalidConfiguration, message: "TMDB request URL is invalid")
    }
    return TMDBHTTPRequest(
      method: "GET",
      url: requestURL,
      headers: headers
    )
  }

  private static func retryAfterMilliseconds(_ headers: [String: String]) -> Int64? {
    guard
      let value = headers.first(where: {
        $0.key.caseInsensitiveCompare("retry-after") == .orderedSame
      })?.value, let seconds = Double(value), seconds.isFinite, seconds >= 0
    else { return nil }
    let milliseconds = seconds * 1_000
    guard milliseconds <= Double(Int64.max) else { return nil }
    return Int64(milliseconds.rounded(.up))
  }

  private static let apiRoot = URL(string: "https://api.themoviedb.org/3")!
  private static let maximumResponseBytes = 8 * 1_024 * 1_024
}

private final class TMDBNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  static let shared = TMDBNoRedirectDelegate()

  func urlSession(
    _: URLSession,
    task _: URLSessionTask,
    willPerformHTTPRedirection _: HTTPURLResponse,
    newRequest _: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

private struct TMDBRawSearchResponse: Decodable, Sendable {
  let results: [TMDBRawMedia]
}

private struct TMDBRawFindResponse: Decodable, Sendable {
  let movieResults: [TMDBRawMedia]
  let tvResults: [TMDBRawMedia]
  let tvEpisodeResults: [TMDBRawMedia]

  private enum CodingKeys: String, CodingKey {
    case movieResults = "movie_results"
    case tvResults = "tv_results"
    case tvEpisodeResults = "tv_episode_results"
  }
}

private struct TMDBRawMedia: Decodable, Sendable {
  let id: Int64
  let title: String?
  let name: String?
  let originalTitle: String?
  let originalName: String?
  let releaseDate: String?
  let firstAirDate: String?
  let airDate: String?
  let overview: String?
  let tagline: String?
  let runtime: Int?
  let episodeRunTime: [Int]?
  let seasonNumber: Int?
  let episodeNumber: Int?
  let showID: Int64?
  let popularity: Double?
  let posterPath: String?
  let backdropPath: String?
  let stillPath: String?
  let externalIDs: TMDBRawExternalIDs?
  let images: TMDBRawImages?
  let alternativeTitles: TMDBRawAlternativeTitles?

  private enum CodingKeys: String, CodingKey {
    case id
    case title
    case name
    case originalTitle = "original_title"
    case originalName = "original_name"
    case releaseDate = "release_date"
    case firstAirDate = "first_air_date"
    case airDate = "air_date"
    case overview
    case tagline
    case runtime
    case episodeRunTime = "episode_run_time"
    case seasonNumber = "season_number"
    case episodeNumber = "episode_number"
    case showID = "show_id"
    case popularity
    case posterPath = "poster_path"
    case backdropPath = "backdrop_path"
    case stillPath = "still_path"
    case externalIDs = "external_ids"
    case images
    case alternativeTitles = "alternative_titles"
  }
}

private struct TMDBRawExternalIDs: Decodable, Sendable {
  let imdbID: String?
  let tvdbID: Int64?
  let wikidataID: String?

  private enum CodingKeys: String, CodingKey {
    case imdbID = "imdb_id"
    case tvdbID = "tvdb_id"
    case wikidataID = "wikidata_id"
  }
}

private struct TMDBRawImages: Decodable, Sendable {
  let posters: [TMDBRawImage]
  let backdrops: [TMDBRawImage]
  let logos: [TMDBRawImage]
  let stills: [TMDBRawImage]

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    posters = try container.decodeIfPresent([TMDBRawImage].self, forKey: .posters) ?? []
    backdrops = try container.decodeIfPresent([TMDBRawImage].self, forKey: .backdrops) ?? []
    logos = try container.decodeIfPresent([TMDBRawImage].self, forKey: .logos) ?? []
    stills = try container.decodeIfPresent([TMDBRawImage].self, forKey: .stills) ?? []
  }

  private enum CodingKeys: String, CodingKey {
    case posters
    case backdrops
    case logos
    case stills
  }
}

private struct TMDBRawImage: Decodable, Sendable {
  let filePath: String
  let language: String?
  let width: Int?
  let height: Int?
  let voteAverage: Double?

  init(
    filePath: String,
    language: String? = nil,
    width: Int? = nil,
    height: Int? = nil,
    voteAverage: Double? = 0
  ) {
    self.filePath = filePath
    self.language = language
    self.width = width
    self.height = height
    self.voteAverage = voteAverage
  }

  private enum CodingKeys: String, CodingKey {
    case filePath = "file_path"
    case language = "iso_639_1"
    case width
    case height
    case voteAverage = "vote_average"
  }
}

private struct TMDBRawAlternativeTitles: Decodable, Sendable {
  let values: [String]

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let titles =
      try container.decodeIfPresent([TMDBRawAlternativeTitle].self, forKey: .titles) ?? []
    let results =
      try container.decodeIfPresent([TMDBRawAlternativeTitle].self, forKey: .results) ?? []
    var seen: Set<String> = []
    values = (titles + results).map(\.title).filter { !$0.isEmpty && seen.insert($0).inserted }
  }

  private enum CodingKeys: String, CodingKey {
    case titles
    case results
  }
}

private struct TMDBRawAlternativeTitle: Decodable, Sendable {
  let title: String
}

private struct TMDBRawConfiguration: Decodable, Sendable {
  let images: TMDBRawImageConfiguration
}

private struct TMDBRawImageConfiguration: Decodable, Sendable {
  let secureBaseURL: String
  let backdropSizes: [String]
  let logoSizes: [String]
  let posterSizes: [String]
  let profileSizes: [String]
  let stillSizes: [String]

  private enum CodingKeys: String, CodingKey {
    case secureBaseURL = "secure_base_url"
    case backdropSizes = "backdrop_sizes"
    case logoSizes = "logo_sizes"
    case posterSizes = "poster_sizes"
    case profileSizes = "profile_sizes"
    case stillSizes = "still_sizes"
  }
}

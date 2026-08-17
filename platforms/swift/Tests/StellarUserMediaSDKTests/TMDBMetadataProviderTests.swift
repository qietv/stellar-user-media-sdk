import Foundation
import StellarCore
import StellarMediaLibrary
import Testing

@Suite("TMDB metadata provider")
struct TMDBMetadataProviderTests {
  @Test("Movie search sends a runtime API key while fixture matching stays sanitized")
  func movieSearch() async throws {
    let transport = try FixtureTMDBTransport(loadFixture())
    let provider = try makeProvider(transport: transport)
    let query = try MediaMatchQuery(kind: .movie, title: "Arrival", year: 2016)

    let candidates = try await provider.search(query)

    #expect(candidates.count == 2)
    #expect(candidates[0].candidateID == "329865")
    #expect(candidates[0].kind == .movie)
    #expect(candidates[0].title == "Arrival")
    #expect(candidates[0].year == 2016)
    let hasTMDBMovieID = candidates[0].externalIDs.contains {
      $0.provider == "tmdb" && $0.namespace == "movie" && $0.value == "329865"
    }
    #expect(hasTMDBMovieID)

    let requests = await transport.sentRequests()
    let request = try #require(requests.first)
    let queryItems = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems
    #expect(queryItems?.first(where: { $0.name == "api_key" })?.value == fixtureAPIKey)
    #expect(request.headers["Authorization"] == nil)
    #expect(request.description == "<TMDBHTTPRequest method=GET redacted>")
    #expect(!request.description.contains("Arrival"))
    #expect(!request.description.contains(fixtureAPIKey))
  }

  @Test("External IDs use find and remain exact scoring evidence")
  func externalIDFind() async throws {
    let transport = try FixtureTMDBTransport(loadFixture())
    let provider = try makeBearerProvider(transport: transport)
    let imdbID = try LocalMetadataExternalID(
      provider: "imdb",
      namespace: "movie",
      value: "tt2543164",
      isPrimary: true
    )
    let query = try MediaMatchQuery(kind: .movie, externalIDs: [imdbID])

    let candidates = try await provider.search(query)
    let candidate = try #require(candidates.first)
    let scored = try #require(
      MediaMetadataCandidateScorer().rank(query: query, candidates: candidates).first
    )

    #expect(candidate.externalIDs.contains(imdbID))
    #expect(scored.score == 1)
    #expect(scored.decision == .automatic)
    let paths = await transport.sentRequests().map(\.url.path)
    #expect(paths.first == "/3/find/tt2543164")
    let request = try #require(await transport.sentRequests().first)
    #expect(request.headers["Authorization"] == "Bearer fixture-read-token")
    #expect(request.url.query?.contains("api_key") == false)
  }

  @Test("Episode title search validates that the requested coordinate exists")
  func episodeSearch() async throws {
    let transport = try FixtureTMDBTransport(loadFixture())
    let provider = try makeProvider(transport: transport)
    let query = try MediaMatchQuery(
      kind: .episode,
      title: "Wednesday",
      year: 2022,
      season: 2,
      episode: 3
    )

    let candidates = try await provider.search(query)
    let candidate = try #require(candidates.first)

    #expect(candidates.count == 1)
    #expect(candidate.kind == .series)
    #expect(candidate.candidateID == "119051")
    #expect(candidate.availableEpisodes == [try MediaEpisodeCoordinate(season: 2, episode: 3)])
    let paths = await transport.sentRequests().map(\.url.path)
    #expect(paths == ["/3/search/tv", "/3/tv/119051/season/2/episode/3"])
  }

  @Test("Details and image configuration normalize recorded response models")
  func detailsAndImages() async throws {
    let transport = try FixtureTMDBTransport(loadFixture())
    let provider = try makeProvider(transport: transport)

    let details = try await provider.movieDetails(id: 329865)
    let configuration = try await provider.imageConfiguration()

    #expect(details.providerID == "329865")
    #expect(details.kind == .movie)
    #expect(details.metadata.title == "Arrival")
    #expect(details.metadata.year == 2016)
    #expect(details.metadata.runtimeMilliseconds == 6_960_000)
    #expect(details.aliases == ["異星入境", "降临"])
    #expect(details.artwork.count == 2)
    let hasPoster = details.artwork.contains {
      $0.kind == .poster && $0.remotePath == "/arrival-poster.jpg" && $0.width == 1_000
    }
    let hasIMDbMovieID = details.metadata.externalIDs.contains {
      $0.provider == "imdb" && $0.namespace == "movie" && $0.value == "tt2543164"
    }
    #expect(hasPoster)
    #expect(hasIMDbMovieID)
    #expect(
      try configuration.imageURL(
        remotePath: "/arrival-poster.jpg",
        kind: .poster,
        size: "w780"
      ).absoluteString == "https://image.tmdb.org/t/p/w780/arrival-poster.jpg"
    )
    #expect(throws: SDKError.self) {
      try configuration.imageURL(
        remotePath: "/arrival-poster.jpg?token=secret",
        kind: .poster,
        size: "w780"
      )
    }
  }

  @Test("Credentials, configuration, HTTP errors, and response bounds fail safely")
  func safeFailures() async throws {
    #expect(throws: SDKError.self) { try TMDBCredential(readAccessToken: "token\nleak") }
    #expect(throws: SDKError.self) { try TMDBCredential(apiKey: "not-a-v3-api-key") }
    #expect(throws: SDKError.self) {
      try TMDBProviderConfiguration(language: "not a locale value")
    }
    let credential = try TMDBCredential(readAccessToken: "fixture-read-token")
    #expect(credential.description == "<TMDBCredential redacted>")

    let query = try MediaMatchQuery(kind: .movie, title: "Arrival")
    let rateLimited = TMDBMetadataProvider(
      credential: credential,
      configuration: try TMDBProviderConfiguration(),
      transport: StaticTMDBTransport(
        response: TMDBHTTPResponse(
          statusCode: 429,
          headers: ["Retry-After": "1.25"]
        )
      )
    )
    do {
      _ = try await rateLimited.search(query)
      Issue.record("Expected rate limit error")
    } catch let error as SDKError {
      #expect(error.code == .rateLimited)
      #expect(error.retryAfterMilliseconds == 1_250)
    }

    let oversized = TMDBMetadataProvider(
      credential: credential,
      configuration: try TMDBProviderConfiguration(),
      transport: StaticTMDBTransport(
        response: TMDBHTTPResponse(
          statusCode: 200,
          body: Data(repeating: 0, count: 8 * 1_024 * 1_024 + 1)
        )
      )
    )
    do {
      _ = try await oversized.search(query)
      Issue.record("Expected bounded response failure")
    } catch let error as SDKError {
      #expect(error.code == .parseFailure)
    }
  }

  private func makeProvider(transport: any TMDBTransport) throws -> TMDBMetadataProvider {
    TMDBMetadataProvider(
      credential: try TMDBCredential(apiKey: fixtureAPIKey),
      configuration: try TMDBProviderConfiguration(
        language: "zh-CN",
        artworkLanguage: "zh-Hans",
        maximumSearchResults: 5
      ),
      transport: transport
    )
  }

  private func makeBearerProvider(transport: any TMDBTransport) throws -> TMDBMetadataProvider {
    TMDBMetadataProvider(
      credential: try TMDBCredential(readAccessToken: "fixture-read-token"),
      configuration: try TMDBProviderConfiguration(
        language: "zh-CN",
        artworkLanguage: "zh-Hans",
        maximumSearchResults: 5
      ),
      transport: transport
    )
  }

  private func loadFixture() throws -> Data {
    let fixtureURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("specs/fixtures/media-library/tmdb-provider-v1.json")
    return try Data(contentsOf: fixtureURL)
  }
}

private actor FixtureTMDBTransport: TMDBTransport {
  private let exchanges: [FixtureTMDBExchange]
  private var requests: [TMDBHTTPRequest] = []

  init(_ data: Data) throws {
    guard
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      root["schema_version"] as? Int == 1,
      let rawExchanges = root["exchanges"] as? [[String: Any]]
    else {
      throw SDKError(code: .parseFailure, message: "TMDB fixture is invalid")
    }
    exchanges = try rawExchanges.map(FixtureTMDBExchange.init)
  }

  func send(_ request: TMDBHTTPRequest) async throws -> TMDBHTTPResponse {
    requests.append(request)
    let query =
      URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?
      .filter { $0.name.caseInsensitiveCompare("api_key") != .orderedSame }
      .reduce(into: [String: String]()) { result, item in result[item.name] = item.value ?? "" }
      ?? [:]
    guard
      let exchange = exchanges.first(where: {
        $0.method == request.method && $0.path == request.url.path && $0.query == query
      })
    else {
      throw SDKError(code: .metadataNotFound, message: "TMDB fixture request is missing")
    }
    return exchange.response
  }

  func sentRequests() -> [TMDBHTTPRequest] { requests }
}

private let fixtureAPIKey = "0123456789abcdef0123456789abcdef"

private struct FixtureTMDBExchange: Sendable {
  let method: String
  let path: String
  let query: [String: String]
  let response: TMDBHTTPResponse

  init(_ object: [String: Any]) throws {
    guard let request = object["request"] as? [String: Any],
      let method = request["method"] as? String,
      let path = request["path"] as? String,
      let query = request["query"] as? [String: String],
      let response = object["response"] as? [String: Any],
      let statusCode = response["status_code"] as? Int,
      let headers = response["headers"] as? [String: String],
      let body = response["body"], JSONSerialization.isValidJSONObject(body)
    else {
      throw SDKError(code: .parseFailure, message: "TMDB fixture exchange is invalid")
    }
    self.method = method
    self.path = path
    self.query = query
    self.response = try TMDBHTTPResponse(
      statusCode: statusCode,
      headers: headers,
      body: JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    )
  }
}

private struct StaticTMDBTransport: TMDBTransport {
  let response: TMDBHTTPResponse

  func send(_: TMDBHTTPRequest) async throws -> TMDBHTTPResponse { response }
}

import Foundation
import StellarUserMediaSDK
import Testing

@testable import DemoMetadata

@Suite("Detail metadata contracts", .serialized)
struct MediaInfoTests {
  @Test func nullableMediaAndPersonFields() throws {
    let movie: MediaInfoEntity = try decode(
      """
      {"object_id":"movie-1","object_kind":"movie","title":"A Movie","original_title":"Movie",
      "overview":"Story","release_date":"2020-01-02","runtime_minutes":null,"genres":[{"name":"Drama"}]}
      """)
    #expect(movie.runtimeMinutes == nil)
    #expect(movie.genres?.first?.name == "Drama")
    #expect(movie.date == "2020-01-02")
    let person: MediaInfoEntity = try decode(
      """
      {"object_id":"person-1","object_kind":"person","name":"An Actor","biography":"Bio",
      "birth_date":null,"death_date":null,"known_for_department":"Acting","place_of_birth":null}
      """)
    #expect(person.displayTitle == "An Actor")
    #expect(person.title == nil)
    #expect(person.birthDate == nil)
  }

  @Test func completeAggregateCreditsAndTruncatedFilmography() throws {
    let cast = (0..<60).map { i in
      """
      {"person_id":"person-\(i)","name":"Actor \(i)","character":null,"order":\(i),
      "roles":[{"character":"One","episode_count":3},{"character":"Two","episode_count":1}]}
      """
    }.joined(separator: ",")
    let credits: MediaInfoCredits = try decode(
      """
      {"owner_id":"series-1","cast":[\(cast)],"crew":[{"person_id":"director-1","name":"Director",
      "department":"Directing","job":null,"order":0,"jobs":[{"department":"Directing","job":"Director","episode_count":4}]}]}
      """)
    #expect(credits.cast.count == 60)
    #expect(credits.cast.last?.subtitle == "One / Two")
    #expect(credits.crew.first?.subtitle == "Director")
    let filmography: MediaInfoFilmography = try decode(
      """
      {"person_id":"person-1","source_count":120,"truncated":true,"items":[
      {"media_id":"movie-1","media_kind":"movie","title":"Movie","character":"Actor","order":0},
      {"media_id":"movie-1","media_kind":"movie","title":"Movie","job":"Producer","order":1}]}
      """)
    #expect(filmography.truncated)
    #expect(filmography.sourceCount == 120)
    #expect(Set(filmography.items.map(\.id)).count == 2)
  }

  @Test func paginationRejectsChangedGenerationAndCursorLoops() throws {
    var pages = MediaInfoPageAccumulator<MediaInfoEpisodeEntry>(maximumItems: 512)
    #expect(try pages.append(page(version: "v1", cursor: "next", ordinal: 0)) == "next")
    #expect(throws: MediaInfoPaginationError.self) {
      try pages.append(page(version: "v2", cursor: nil, ordinal: 1))
    }
    #expect(pages.items.count == 1)
    #expect(throws: MediaInfoPaginationError.self) {
      try pages.append(page(version: "v1", cursor: "next", ordinal: 1))
    }
    #expect(try pages.append(page(version: "v1", cursor: nil, ordinal: 1)) == nil)
    #expect(pages.items.count == 2)
    var bounded = MediaInfoPageAccumulator<MediaInfoEpisodeEntry>(maximumItems: 1)
    _ = try bounded.append(page(version: "v1", cursor: "next", ordinal: 0))
    #expect(throws: MediaInfoPaginationError.self) {
      try bounded.append(page(version: "v1", cursor: nil, ordinal: 1))
    }
  }

  @Test func alternateOrderUsesAiredIdentityIncludingSpecials() throws {
    let aired: MediaInfoEpisodeEntry = try decode(entryJSON(id: "special", season: 0, episode: 0))
    let alternate: MediaInfoEpisodeEntry = try decode(
      entryJSON(id: "special", season: 1, episode: 10))
    let unknown: MediaInfoEpisodeEntry = try decode(entryJSON(id: "unknown", season: 0, episode: 0))
    let index = MediaInfoEpisodeIndex(airedEntries: [aired])
    #expect(index.airedCoordinate(for: alternate) == MediaInfoCoordinate(season: 0, episode: 0))
    #expect(index.airedCoordinate(for: unknown) == nil)
  }

  @Test func clientReadsAllPagesAndReusesPersistentCache() async throws {
    let (client, folder) = try await makeClient()
    defer { try? FileManager.default.removeItem(at: folder) }
    MockProtocol.state.configure { request in
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let isSecond = query.contains { $0.name == "cursor" && $0.value == "page+2/=" }
      return MockResponse(
        json: """
          {"metadata_version":"v1","items":[\(entryJSON(id: isSecond ? "ep-2" : "ep-1", season: 1, episode: isSecond ? 2 : 1))],
          "next_cursor":\(isSecond ? "null" : "\"page+2/=\"")}
          """)
    }
    let entries = try await client.episodeEntries(seriesID: "series-1", orderID: "order-1")
    #expect(entries.map(\.episodeNumber) == [1, 2])
    #expect(MockProtocol.state.requestCount == 2)
    _ = try await client.episodeEntries(seriesID: "series-1", orderID: "order-1")
    #expect(MockProtocol.state.requestCount == 2)
    #expect(MockProtocol.state.urls.allSatisfy { $0.host == "dev-api-st.2dland.cn" })
  }

  @Test func cancellingOneSubscriberDoesNotCancelSharedRequest() async throws {
    let (client, folder) = try await makeClient()
    defer { try? FileManager.default.removeItem(at: folder) }
    MockProtocol.state.configure { _ in MockResponse(json: entityJSON("shared"), delay: 0.3) }
    let first = Task { try await client.entity(id: "shared") }
    let second = Task { try await client.entity(id: "shared") }
    try await Task.sleep(for: .milliseconds(100))
    first.cancel()
    let surviving = try await second.value
    #expect(surviving.objectID == "shared")
    #expect(MockProtocol.state.requestCount == 1)
    do {
      _ = try await first.value
      Issue.record("Cancelled subscriber returned a value")
    } catch { #expect(error is CancellationError) }
  }

  @Test func artworkUsesKindAndAnAppropriateHTTPSVariant() async throws {
    let (client, folder) = try await makeClient()
    defer { try? FileManager.default.removeItem(at: folder) }
    MockProtocol.state.configure { request in
      if request.url!.path.hasSuffix("variants") {
        return MockResponse(
          json: """
            {"items":[{"url":"https://images.example/large","width":2000,"height":3000},
            {"url":"http://images.example/insecure","width":300,"height":450},
            {"url":"https://images.example/profile","width":342,"height":513}]}
            """)
      }
      #expect(request.url!.query?.contains("kind=profile") == true)
      return MockResponse(
        json: """
          {"items":[{"artwork_id":"image-1","artwork_kind":"profile"}]}
          """)
    }
    let url = try await client.artworkURL(ownerID: "person-1", kind: "profile")
    #expect(url?.absoluteString == "https://images.example/profile")
  }

  @Test func networkRequestsAreBoundedAndIdentityIsChecked() async throws {
    let (client, folder) = try await makeClient()
    defer { try? FileManager.default.removeItem(at: folder) }
    MockProtocol.state.configure { request in
      MockResponse(json: entityJSON(request.url!.lastPathComponent), delay: 0.6)
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
      for i in 0..<8 { group.addTask { _ = try await client.entity(id: "movie-\(i)") } }
      try await group.waitForAll()
    }
    #expect(MockProtocol.state.maximumConcurrent <= 4)
    #expect(MockProtocol.state.maximumConcurrent > 1)
    MockProtocol.state.configure { _ in MockResponse(json: entityJSON("wrong")) }
    await #expect(throws: SDKError.self) { try await client.entity(id: "expected") }
    await #expect(throws: SDKError.self) { try await client.entity(id: "../escape") }
    #expect(MockProtocol.state.requestCount == 1)
  }

  @Test func cachedAiredOrderOnlyUsesTheVerifiedSeriesIdentity() async throws {
    let (client, folder) = try await makeClient()
    defer { try? FileManager.default.removeItem(at: folder) }
    MockProtocol.state.configure { _ in
      MockResponse(
        json: """
          {"parsed_candidates":[],"selected":{"object_id":"ep-1","object_kind":"episode",
          "series_id":"series-1","title":"Pilot","coordinate":{"order_id":"aired-1","order_kind":"aired"}}}
          """)
    }
    _ = try await client.resolve(path: "Show.S01E01.mkv")
    #expect(
      await client.cachedAiredOrderID(seriesID: "series-1", paths: ["Show.S01E01.mkv"]) == "aired-1"
    )
    #expect(
      await client.cachedAiredOrderID(seriesID: "different-series", paths: ["Show.S01E01.mkv"])
        == nil)
    #expect(MockProtocol.state.requestCount == 1)
  }

  @Test func unavailableResponsesRetryWithoutPoisoningTheCache() async throws {
    let (client, folder) = try await makeClient()
    defer { try? FileManager.default.removeItem(at: folder) }
    MockProtocol.state.configure { _ in
      MockProtocol.state.requestCount < 3
        ? MockResponse(json: "{}", status: 503) : MockResponse(json: entityJSON("retry"))
    }
    let result = try await client.entity(id: "retry")
    #expect(result.objectID == "retry")
    #expect(MockProtocol.state.requestCount == 3)
    _ = try await client.entity(id: "retry")
    #expect(MockProtocol.state.requestCount == 3)
  }

  private func page(version: String, cursor: String?, ordinal: Int) throws -> MediaInfoPage<
    MediaInfoEpisodeEntry
  > {
    try decode(
      """
      {"metadata_version":"\(version)","items":[\(entryJSON(id: "ep-\(ordinal)", season: 1, episode: ordinal))],
      "next_cursor":\(cursor.map { "\"\($0)\"" } ?? "null")}
      """)
  }
}

private func decode<T: Decodable>(_ json: String) throws -> T {
  try JSONDecoder().decode(T.self, from: Data(json.utf8))
}
private func entryJSON(id: String, season: Int, episode: Int) -> String {
  """
  {"episode_id":"\(id)","season_id":"season-\(season)","ordinal":\(episode),"season_number":\(season),"episode_number":\(episode)}
  """
}
private func entityJSON(_ id: String) -> String {
  "{\"object_id\":\"\(id)\",\"object_kind\":\"movie\",\"title\":\"Movie\"}"
}

private func makeClient() async throws -> (TestMediaInfoClient, URL) {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
    "stellar-details-tests-\(UUID())")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let database = try await StorageDatabase.open(
    kind: .metadataCache, at: folder.appendingPathComponent("cache.sqlite"))
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [MockProtocol.self]
  return (
    TestMediaInfoClient(
      cacheStore: try MetadataCacheStore(database: database), configuration: configuration), folder
  )
}

private struct MockResponse: Sendable {
  let json: String
  var delay: Double = 0
  var status = 200
}

private final class MockState: @unchecked Sendable {
  private let lock = NSLock()
  private var handler: @Sendable (URLRequest) -> MockResponse = { _ in MockResponse(json: "{}") }
  private var requests: [URL] = []
  private var active = 0
  private var maximum = 0
  func configure(_ value: @escaping @Sendable (URLRequest) -> MockResponse) {
    lock.withLock {
      handler = value
      requests = []
      active = 0
      maximum = 0
    }
  }
  func start(_ request: URLRequest) -> MockResponse {
    let callback = lock.withLock {
      requests.append(request.url!)
      active += 1
      maximum = max(maximum, active)
      return handler
    }
    return callback(request)
  }
  func finish() { lock.withLock { active -= 1 } }
  var requestCount: Int { lock.withLock { requests.count } }
  var maximumConcurrent: Int { lock.withLock { maximum } }
  var urls: [URL] { lock.withLock { requests } }
}

private final class MockProtocol: URLProtocol, @unchecked Sendable {
  static let state = MockState()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let result = Self.state.start(request)
    DispatchQueue.global().asyncAfter(deadline: .now() + result.delay) { [self] in
      Self.state.finish()
      let response = HTTPURLResponse(
        url: request.url!, statusCode: result.status, httpVersion: nil, headerFields: nil)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(result.json.utf8))
      client?.urlProtocolDidFinishLoading(self)
    }
  }
  override func stopLoading() {}
}

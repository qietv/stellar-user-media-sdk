import Foundation
import StellarUserMediaSDK

actor TestMediaInfoClient {
  private static let baseURL = URL(string: "https://dev-api-st.2dland.cn/v1/media-info/")!
  private static let allowedHost = "dev-api-st.2dland.cn"
  private static let provider = ResolvedPosterMetadata.provider
  private static let resolveTTLMilliseconds: Int64 = 24 * 60 * 60 * 1_000
  private static let entityTTLMilliseconds: Int64 = 7 * 24 * 60 * 60 * 1_000
  private static let negativeTTLMilliseconds: Int64 = 60 * 60 * 1_000
  private static let minimumRequestIntervalMilliseconds: Int64 = 100
  private static let maximumAttempts = 3
  private static let maximumResponseBytes = 8 * 1_024 * 1_024

  private let cacheStore: MetadataCacheStore
  private let redirectBlocker: TestMediaInfoRedirectBlocker
  private let session: URLSession
  private var inFlight: [String: Task<Data, Error>] = [:]
  private var nextRequestAtMilliseconds: Int64 = 0
  private var suspendedError: SDKError?
  private var activeRequests = 0
  private var requestWaiters: [CheckedContinuation<Void, Never>] = []

  init(cacheStore: MetadataCacheStore, configuration: URLSessionConfiguration = .default) {
    self.cacheStore = cacheStore
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 45
    configuration.requestCachePolicy = .useProtocolCachePolicy
    configuration.urlCache = URLCache(
      memoryCapacity: 8 * 1_024 * 1_024,
      diskCapacity: 64 * 1_024 * 1_024
    )
    let redirectBlocker = TestMediaInfoRedirectBlocker()
    self.redirectBlocker = redirectBlocker
    session = URLSession(
      configuration: configuration,
      delegate: redirectBlocker,
      delegateQueue: nil
    )
  }

  func entity(id: String) async throws -> MediaInfoEntity {
    let result: MediaInfoEntity = try await get(
      pathComponents: ["entities", id], queryItems: Self.localizedQuery, locale: "zh-CN")
    guard result.objectID == id else {
      throw SDKError(code: .parseFailure, message: "Entity identity does not match")
    }
    return result
  }

  func credits(id: String) async throws -> MediaInfoCredits {
    let result: MediaInfoCredits = try await get(
      pathComponents: ["entities", id, "credits"], queryItems: Self.localizedQuery, locale: "zh-CN")
    guard result.ownerID == id else {
      throw SDKError(code: .parseFailure, message: "Credits identity does not match")
    }
    return result
  }

  func filmography(id: String) async throws -> MediaInfoFilmography {
    let result: MediaInfoFilmography = try await get(
      pathComponents: ["persons", id, "filmography"], queryItems: Self.localizedQuery,
      locale: "zh-CN")
    guard result.personID == id else {
      throw SDKError(code: .parseFailure, message: "Filmography identity does not match")
    }
    return result
  }

  func cachedAiredOrderID(seriesID: String, paths: [String]) async -> String? {
    // resolve already returns an aired order ID. Reuse that accepted identity when the order
    // menu is temporarily unavailable because an unrelated alternate order is still building.
    for path in paths.prefix(8) {
      guard !Task.isCancelled,
        let resolution = await cachedResolution(path: path),
        let selected = resolution.selected, selected.seriesID == seriesID,
        let coordinate = selected.coordinate, coordinate.orderKind == "aired"
      else { continue }
      return coordinate.orderID
    }
    return nil
  }

  func episodeOrders(seriesID: String) async throws -> [MediaInfoEpisodeOrder] {
    let orders: [MediaInfoEpisodeOrder] = try await allPages(
      path: ["series", seriesID, "episode-orders"], maximumItems: 32)
    guard orders.allSatisfy({ $0.seriesID == seriesID }) else {
      throw SDKError(code: .parseFailure, message: "Episode order belongs to another series")
    }
    return orders
  }

  func episodeEntries(seriesID: String, orderID: String) async throws -> [MediaInfoEpisodeEntry] {
    try await allPages(
      path: ["series", seriesID, "episode-orders", orderID, "entries"], maximumItems: 512)
  }

  private func allPages<Item: Decodable & Sendable>(path: [String], maximumItems: Int) async throws
    -> [Item]
  {
    var accumulator = MediaInfoPageAccumulator<Item>(maximumItems: maximumItems)
    var cursor: String?
    repeat {
      try Task.checkCancellation()
      var query = [URLQueryItem(name: "limit", value: "100")]
      if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
      let page: MediaInfoPage<Item> = try await get(
        pathComponents: path, queryItems: query, locale: "und")
      cursor = try accumulator.append(page)
    } while cursor != nil
    return accumulator.items
  }

  func artworkURL(ownerID: String, kind: String) async throws -> URL? {
    let page: MediaInfoArtworkPage = try await get(
      pathComponents: ["entities", ownerID, "artworks"],
      queryItems: [
        URLQueryItem(name: "kind", value: kind), URLQueryItem(name: "limit", value: "1"),
      ],
      locale: "und")
    guard let artwork = page.items.first(where: { $0.artworkKind == kind }) else { return nil }
    let variants: MediaInfoArtworkVariantPage = try await get(
      pathComponents: ["artworks", artwork.artworkID, "variants"],
      queryItems: [URLQueryItem(name: "limit", value: "100")], locale: "und")
    // Prefer the smallest adequate rendition over downloading original-sized backdrops per cell.
    let targetWidth =
      kind == "profile" ? 300 : (kind == "still" ? 640 : (kind == "poster" ? 500 : 1280))
    let candidates = variants.items.filter {
      guard let url = URL(string: $0.url) else { return false }
      return url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil
    }.sorted { ($0.width ?? Int.max) < ($1.width ?? Int.max) }
    let selected = candidates.first(where: { ($0.width ?? 0) >= targetWidth }) ?? candidates.last
    return selected.flatMap { URL(string: $0.url) }
  }

  private static var localizedQuery: [URLQueryItem] {
    [URLQueryItem(name: "locale", value: "zh-CN")]
  }

  func resetProviderSuspension() {
    suspendedError = nil
  }

  func resolve(path: String) async throws -> MediaInfoResolution {
    let request = try Self.resolveRequest(path: path)
    return try await send(
      request,
      endpoint: "resolve",
      locale: "zh-CN",
      ttlMilliseconds: Self.resolveTTLMilliseconds
    )
  }

  func primaryMetadata(from resolution: MediaInfoResolution) async throws -> ResolvedPosterMetadata?
  {
    guard let selected = resolution.selected else { return nil }
    if selected.objectKind == "episode" {
      guard let seriesID = selected.seriesID else { return nil }
      let fallback = ResolvedPosterMetadata(
        rootObjectID: seriesID,
        kind: .series,
        title: resolution.primaryCandidate?.title ?? selected.title,
        originalTitle: nil,
        overview: nil,
        year: resolution.primaryCandidate?.year
      )
      do {
        let resolvedEntity: MediaInfoEntity = try await get(
          pathComponents: ["entities", seriesID],
          queryItems: [URLQueryItem(name: "locale", value: "zh-CN")],
          locale: "zh-CN"
        )
        return ResolvedPosterMetadata(
          rootObjectID: seriesID,
          kind: .series,
          title: resolvedEntity.title ?? fallback.title,
          originalTitle: resolvedEntity.originalTitle,
          overview: resolvedEntity.overview,
          year: Self.year(from: resolvedEntity.firstAirDate) ?? fallback.year
        )
      } catch {
        if Self.isCancellation(error) { throw error }
        return fallback
      }
    }

    return ResolvedPosterMetadata(
      rootObjectID: selected.objectID,
      kind: selected.objectKind == "series" ? .series : .movie,
      title: selected.title,
      originalTitle: selected.originalTitle,
      overview: selected.overview,
      year: selected.year
    )
  }

  func bestArtwork(for target: LibraryRemoteArtworkTarget, path: String) async throws
    -> ResolvedArtworkVariant?
  {
    guard target.provider == Self.provider else {
      throw SDKError(code: .invalidConfiguration, message: "artwork provider is unsupported")
    }
    if let artworkID = await cachedArtworkID(path: path, target: target) {
      return try await bestArtwork(artworkID: artworkID)
    }
    let artworkPage: MediaInfoArtworkPage = try await get(
      pathComponents: ["entities", target.providerID, "artworks"],
      queryItems: [
        URLQueryItem(name: "locale", value: "zh-CN"),
        URLQueryItem(name: "limit", value: "100"),
      ],
      locale: "zh-CN"
    )
    guard
      let artworkID = artworkPage.items.first(where: {
        $0.artworkKind == "poster"
      })?.artworkID
    else { return nil }
    return try await bestArtwork(artworkID: artworkID)
  }

  private func cachedArtworkID(
    path: String,
    target: LibraryRemoteArtworkTarget
  ) async -> String? {
    guard
      let resolution = await cachedResolution(path: path),
      let selected = resolution.selected,
      selected.artworkID != nil
    else { return nil }
    switch target.kind {
    case .movie:
      guard selected.objectKind == "movie", selected.objectID == target.providerID else {
        return nil
      }
    case .series:
      guard selected.objectKind == "series", selected.objectID == target.providerID else {
        return nil
      }
    }
    return selected.artworkID
  }

  private func cachedResolution(path: String) async -> MediaInfoResolution? {
    guard let current = try? Self.resolveRequest(path: path),
      let encodedPath = try? JSONEncoder().encode(path)
    else { return nil }
    var legacy = current
    // Before sortedKeys was enabled, JSONEncoder could persist either property order.
    legacy.httpBody = Data(
      ("{\"path\":" + String(decoding: encodedPath, as: UTF8.self)
        + ",\"locale\":\"zh-CN\"}").utf8)
    for request in [current, legacy] {
      let fingerprint = Self.requestFingerprint(request)
      let requestKey = "\(Self.provider)-\(Self.fnv1a(fingerprint))"
      guard
        let cached = try? await cacheStore.providerResponse(
          requestKey: requestKey, requestFingerprint: fingerprint),
        let json = cached.responseJSON,
        let result: MediaInfoResolution = try? Self.decode(Data(json.utf8))
      else { continue }
      return result
    }
    return nil
  }

  private func bestArtwork(artworkID: String) async throws -> ResolvedArtworkVariant? {
    let page: MediaInfoArtworkVariantPage = try await get(
      pathComponents: ["artworks", artworkID, "variants"],
      queryItems: [URLQueryItem(name: "limit", value: "50")],
      locale: "und"
    )
    return page.items.compactMap { item -> ResolvedArtworkVariant? in
      guard let url = URL(string: item.url), url.scheme == "https" else { return nil }
      return ResolvedArtworkVariant(url: url, width: item.width, height: item.height)
    }.max { $0.pixelArea < $1.pixelArea }
  }

  private func get<Response: Decodable & Sendable>(
    pathComponents: [String],
    queryItems: [URLQueryItem],
    locale: String
  ) async throws -> Response {
    var url = Self.baseURL
    for component in pathComponents {
      guard !component.isEmpty, component != ".", component != "..",
        !component.contains("/"), !component.contains("\0")
      else {
        throw SDKError(code: .invalidConfiguration, message: "media service path is invalid")
      }
      url.appendPathComponent(component)
    }
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw SDKError(code: .invalidConfiguration, message: "media service URL is invalid")
    }
    components.queryItems = queryItems
    guard let requestURL = components.url else {
      throw SDKError(code: .invalidConfiguration, message: "media service URL is invalid")
    }
    return try await send(
      URLRequest(url: requestURL),
      endpoint: pathComponents.joined(separator: "/"),
      locale: locale,
      ttlMilliseconds: Self.entityTTLMilliseconds
    )
  }

  private func send<Response: Decodable & Sendable>(
    _ request: URLRequest,
    endpoint: String,
    locale: String,
    ttlMilliseconds: Int64
  ) async throws -> Response {
    do {
      guard request.url?.scheme == "https", request.url?.host == Self.allowedHost else {
        throw SDKError(
          code: .invalidConfiguration,
          message: "only the test media service origin is allowed"
        )
      }
      let fingerprint = Self.requestFingerprint(request)
      let requestKey = "\(Self.provider)-\(Self.fnv1a(fingerprint))"
      if let existing = inFlight[requestKey] {
        return try Self.decode(try await Self.awaitData(existing))
      }
      let task = Task {
        try await self.loadData(
          request,
          requestKey: requestKey,
          fingerprint: fingerprint,
          endpoint: endpoint,
          locale: locale,
          ttlMilliseconds: ttlMilliseconds
        )
      }
      inFlight[requestKey] = task
      defer { inFlight[requestKey] = nil }
      let data = try await Self.awaitData(task)
      try Task.checkCancellation()
      return try Self.decode(data)
    } catch let error as SDKError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw SDKError(code: .networkUnavailable, message: "test media service is unavailable")
    }
  }

  private func loadData(
    _ originalRequest: URLRequest,
    requestKey: String,
    fingerprint: String,
    endpoint: String,
    locale: String,
    ttlMilliseconds: Int64
  ) async throws -> Data {
    let now = Self.nowMilliseconds()
    let cached = try? await cacheStore.providerResponse(
      requestKey: requestKey,
      requestFingerprint: fingerprint
    )
    if let cached, cached.isFresh(at: now) {
      guard let responseJSON = cached.responseJSON else {
        throw SDKError(code: .metadataNotFound, message: "media service cached no match")
      }
      return Data(responseJSON.utf8)
    }
    if let suspendedError { throw suspendedError }

    var request = originalRequest
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if request.httpMethod == nil || request.httpMethod == "GET" {
      if let entityTag = cached?.entityTag {
        request.setValue(entityTag, forHTTPHeaderField: "If-None-Match")
      }
      if let lastModified = cached?.lastModified {
        request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
      }
    }

    var lastError = SDKError(
      code: .remoteUnavailable,
      message: "test media service is unavailable"
    )
    for attempt in 0..<Self.maximumAttempts {
      try Task.checkCancellation()
      do {
        let (data, rawResponse) = try await performRequest(request)
        guard let response = rawResponse as? HTTPURLResponse else {
          throw SDKError(code: .remoteUnavailable, message: "media service response is invalid")
        }
        let status = response.statusCode
        if status == 304, let cached, let responseJSON = cached.responseJSON {
          let refreshed = try MetadataProviderResponseCacheEntry(
            requestKey: requestKey,
            provider: Self.provider,
            endpoint: endpoint,
            requestFingerprint: fingerprint,
            locale: locale,
            httpStatus: cached.httpStatus,
            entityTag: response.value(forHTTPHeaderField: "ETag") ?? cached.entityTag,
            lastModified: response.value(forHTTPHeaderField: "Last-Modified")
              ?? cached.lastModified,
            responseJSON: responseJSON,
            fetchedAtMilliseconds: now,
            expiresAtMilliseconds: now + ttlMilliseconds
          )
          try? await cacheStore.storeProviderResponse(refreshed)
          return Data(responseJSON.utf8)
        }
        if (200...299).contains(status) {
          guard data.count <= Self.maximumResponseBytes else {
            throw SDKError(
              code: .parseFailure,
              message: "media service response exceeds the size limit"
            )
          }
          guard let responseJSON = String(data: data, encoding: .utf8) else {
            throw SDKError(code: .parseFailure, message: "media service response is invalid")
          }
          let storedAt = Self.nowMilliseconds()
          let entry = try MetadataProviderResponseCacheEntry(
            requestKey: requestKey,
            provider: Self.provider,
            endpoint: endpoint,
            requestFingerprint: fingerprint,
            locale: locale,
            httpStatus: status,
            entityTag: response.value(forHTTPHeaderField: "ETag"),
            lastModified: response.value(forHTTPHeaderField: "Last-Modified"),
            responseJSON: responseJSON,
            fetchedAtMilliseconds: storedAt,
            expiresAtMilliseconds: storedAt + ttlMilliseconds
          )
          try? await cacheStore.storeProviderResponse(entry)
          return data
        }
        if status == 404 {
          let storedAt = Self.nowMilliseconds()
          let entry = try MetadataProviderResponseCacheEntry(
            requestKey: requestKey,
            provider: Self.provider,
            endpoint: endpoint,
            requestFingerprint: fingerprint,
            locale: locale,
            httpStatus: status,
            fetchedAtMilliseconds: storedAt,
            expiresAtMilliseconds: storedAt + Self.negativeTTLMilliseconds
          )
          try? await cacheStore.storeProviderResponse(entry)
          throw SDKError(code: .metadataNotFound, message: "media service returned no match")
        }
        if status == 401 || status == 403 {
          let error = SDKError(
            code: status == 401 ? .unauthorized : .forbidden,
            message: "test media service returned HTTP \(status)"
          )
          suspendedError = error
          throw error
        }

        let retryAfter = Self.retryAfterMilliseconds(response)
        let code: SDKErrorCode = status == 429 ? .rateLimited : .remoteUnavailable
        lastError = SDKError(
          code: code,
          message: "test media service returned HTTP \(status)",
          retryAfterMilliseconds: retryAfter
        )
        guard status == 429 || (500...599).contains(status),
          attempt + 1 < Self.maximumAttempts
        else { throw lastError }
        try await backOff(attempt: attempt, retryAfterMilliseconds: retryAfter)
      } catch let error as SDKError {
        if ![.networkUnavailable, .remoteUnavailable, .rateLimited].contains(error.code) {
          throw error
        }
        lastError = error
        guard attempt + 1 < Self.maximumAttempts else { throw error }
        try await backOff(
          attempt: attempt,
          retryAfterMilliseconds: error.retryAfterMilliseconds
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        lastError = SDKError(
          code: .networkUnavailable,
          message: "test media service is unavailable"
        )
        guard attempt + 1 < Self.maximumAttempts else { throw lastError }
        try await backOff(attempt: attempt, retryAfterMilliseconds: nil)
      }
    }
    throw lastError
  }

  private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
    if activeRequests >= 4 {
      await withCheckedContinuation { requestWaiters.append($0) }
    } else {
      activeRequests += 1
    }
    defer {
      if requestWaiters.isEmpty {
        activeRequests -= 1
      } else {
        requestWaiters.removeFirst().resume()
      }
    }
    try Task.checkCancellation()
    try await waitForRequestSlot()
    return try await session.data(for: request)
  }

  private func waitForRequestSlot() async throws {
    let now = Self.nowMilliseconds()
    let scheduledAt = max(now, nextRequestAtMilliseconds)
    nextRequestAtMilliseconds = scheduledAt + Self.minimumRequestIntervalMilliseconds
    if scheduledAt > now {
      try await Task.sleep(for: .milliseconds(scheduledAt - now))
    }
  }

  private func backOff(attempt: Int, retryAfterMilliseconds: Int64?) async throws {
    let exponential = Int64(500 * (1 << attempt))
    let jitter = Int64.random(in: 0...250)
    let delay = max(retryAfterMilliseconds ?? 0, exponential + jitter)
    nextRequestAtMilliseconds = max(
      nextRequestAtMilliseconds,
      Self.nowMilliseconds() + delay
    )
    try await Task.sleep(for: .milliseconds(delay))
  }

  private static func decode<Response: Decodable & Sendable>(_ data: Data) throws -> Response {
    guard data.count <= maximumResponseBytes else {
      throw SDKError(
        code: .parseFailure,
        message: "media service response exceeds the size limit"
      )
    }
    do {
      return try JSONDecoder().decode(Response.self, from: data)
    } catch {
      throw SDKError(code: .parseFailure, message: "media service response is invalid")
    }
  }

  private static func awaitData(_ task: Task<Data, Error>) async throws -> Data {
    let data = try await task.value
    try Task.checkCancellation()
    return data
  }

  private static func requestFingerprint(_ request: URLRequest) -> String {
    let method = request.httpMethod ?? "GET"
    let url = request.url?.absoluteString ?? ""
    let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
    return "\(method)\n\(url)\n\(body)"
  }

  private static func resolveRequest(path: String) throws -> URLRequest {
    var request = URLRequest(url: baseURL.appendingPathComponent("resolve"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    request.httpBody = try encoder.encode(MediaInfoResolveRequest(path: path, locale: "zh-CN"))
    return request
  }

  private static func fnv1a(_ value: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return String(hash, radix: 16)
  }

  private static func retryAfterMilliseconds(_ response: HTTPURLResponse) -> Int64? {
    guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
    if let seconds = Double(value), seconds >= 0 {
      return Int64((seconds * 1_000).rounded(.up))
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
    guard let date = formatter.date(from: value) else { return nil }
    return max(0, Int64((date.timeIntervalSinceNow * 1_000).rounded(.up)))
  }

  private static func nowMilliseconds() -> Int64 {
    Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
  }

  private static func year(from date: String?) -> Int? {
    guard let date, date.count >= 4 else { return nil }
    return Int(date.prefix(4))
  }

  private static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    return (error as? SDKError)?.code == .cancelled
  }
}

private final class TestMediaInfoRedirectBlocker: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable
{
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

private struct MediaInfoResolveRequest: Encodable, Sendable {
  let path: String
  let locale: String
}

struct MediaInfoResolution: Decodable, Sendable {
  let parsedCandidates: [MediaInfoParsedCandidate]
  let selected: MediaInfoSelectedMatch?

  var primaryCandidate: MediaInfoParsedCandidate? { parsedCandidates.first }

  func makeMatchQuery() throws -> MediaMatchQuery {
    guard let candidate = primaryCandidate else {
      throw SDKError(code: .metadataNotFound, message: "media service returned no parsed candidate")
    }
    if candidate.kind == "movie" {
      return try MediaMatchQuery(kind: .movie, title: candidate.title, year: candidate.year)
    }
    guard let season = candidate.season, let episode = candidate.episode else {
      throw SDKError(code: .metadataNotFound, message: "series file has no episode coordinate")
    }
    return try MediaMatchQuery(
      kind: .episode,
      title: candidate.title,
      year: candidate.year,
      season: season,
      episode: episode
    )
  }

  private enum CodingKeys: String, CodingKey {
    case parsedCandidates = "parsed_candidates"
    case selected
  }
}

struct MediaInfoParsedCandidate: Decodable, Sendable {
  let kind: String
  let title: String
  let year: Int?
  let season: Int?
  let episode: Int?
}

struct MediaInfoSelectedMatch: Decodable, Sendable {
  let objectID: String
  let objectKind: String
  let seriesID: String?
  let title: String
  let originalTitle: String?
  let year: Int?
  let overview: String?
  let artworkID: String?
  let coordinate: MediaInfoResolvedCoordinate?

  private enum CodingKeys: String, CodingKey {
    case objectID = "object_id"
    case objectKind = "object_kind"
    case seriesID = "series_id"
    case title
    case originalTitle = "original_title"
    case year
    case overview
    case artworkID = "artwork_id"
    case coordinate
  }
}

private struct MediaInfoArtworkPage: Decodable, Sendable {
  let items: [MediaInfoArtworkSummary]
}

private struct MediaInfoArtworkSummary: Decodable, Sendable {
  let artworkID: String
  let artworkKind: String

  private enum CodingKeys: String, CodingKey {
    case artworkID = "artwork_id"
    case artworkKind = "artwork_kind"
  }
}

private struct MediaInfoArtworkVariantPage: Decodable, Sendable {
  let items: [MediaInfoArtworkVariant]
}

private struct MediaInfoArtworkVariant: Decodable, Sendable {
  let url: String
  let width: Int?
  let height: Int?
}

struct ResolvedArtworkVariant: Sendable {
  let url: URL
  let width: Int?
  let height: Int?

  var pixelArea: Int64 {
    Int64(width ?? 0) * Int64(height ?? 0)
  }
}

struct ResolvedPosterMetadata: Sendable {
  static let provider = "stellar-media-info-test"

  let rootObjectID: String
  let kind: PosterWallMediaKind
  let title: String
  let originalTitle: String?
  let overview: String?
  let year: Int?

  func makeCandidate(for query: MediaMatchQuery) throws -> MediaMetadataCandidate {
    let parsedKind: ParsedMediaKind = kind == .movie ? .movie : .series
    let availableEpisodes: [MediaEpisodeCoordinate]
    if query.kind == .episode, let season = query.season, let episode = query.episode {
      availableEpisodes = [try MediaEpisodeCoordinate(season: season, episode: episode)]
    } else {
      availableEpisodes = []
    }
    return try MediaMetadataCandidate(
      provider: Self.provider,
      candidateID: rootObjectID,
      kind: parsedKind,
      title: query.title ?? title,
      originalTitle: originalTitle,
      aliases: title == query.title ? [] : [title],
      year: year,
      availableEpisodes: availableEpisodes,
      popularity: 1
    )
  }
}

struct MediaInfoResolvedCoordinate: Decodable, Sendable {
  let orderID: String
  let orderKind: String
  enum CodingKeys: String, CodingKey {
    case orderID = "order_id"
    case orderKind = "order_kind"
  }
}

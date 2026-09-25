import Foundation
import StellarCore
import StellarMediaLibrary
import StellarRemoteMedia
import Testing

@testable import StellarWebDAV

@Suite("WebDAV media source contracts")
struct WebDAVMediaSourceContractTests {
  @Test(
    "Streaming transport enforces body limits with and without Content-Length",
    arguments: [false, true])
  func streamingByteBudget(declaredLength: Bool) async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BudgetWebDAVProtocol.self]
    let transport = URLSessionWebDAVTransport(configuration: configuration)
    let url = URL(string: "https://budget.test/" + (declaredLength ? "declared" : "chunked"))!
    await expectSDKError(.resourceLimitExceeded) {
      _ = try await transport.send(
        WebDAVHTTPRequest(method: "PROPFIND", url: url, maximumResponseBytes: 1_024))
    }
  }

  @Test("WebDAV connector validates, paginates, stats, and range-reads")
  func connectorOperations() async throws {
    let transport = FixtureWebDAVTransport()
    let credential = try WebDAVCredential(username: "alice", password: "secret")
    let configuration = try WebDAVMediaSourceConfiguration(
      sourceUID: "webdav-fixture-1",
      baseURL: URL(string: "https://dav.example.test/media/")!,
      credential: credential
    )
    let connector = WebDAVMediaSourceConnector(
      configuration: configuration,
      transport: transport
    )
    let session = try await connector.connect()
    let root = try RemoteLocator(sourceUID: configuration.sourceUID, path: RemotePath())
    let firstPage = try await session.listDirectory(
      RemoteDirectoryPageRequest(directory: root, limit: 1)
    )
    let secondPage = try await session.listDirectory(
      RemoteDirectoryPageRequest(
        directory: root,
        cursor: firstPage.nextCursor,
        limit: 1
      )
    )
    let arrival = try RemoteLocator(
      sourceUID: configuration.sourceUID,
      path: RemotePath("Movies/Arrival.mkv")
    )
    let stat = try await session.stat(arrival)
    let bytes = try await session.read(
      at: arrival,
      range: RemoteByteRange(offset: 1, length: 3)
    )
    await session.disconnect()

    #expect(credential.description == "<WebDAVCredential redacted>")
    #expect(configuration.description.contains("dav.example.test") == false)
    #expect(firstPage.items.map(\.locator.path.relativePath) == ["Notes.txt"])
    #expect(firstPage.nextCursor != nil)
    #expect(secondPage.items.map(\.locator.path.relativePath) == ["Movies"])
    #expect(secondPage.nextCursor == nil)
    #expect(stat.kind == .file)
    #expect(stat.size == 7)
    #expect(stat.entityTag == "\"arrival-v1\"")
    #expect(String(decoding: bytes, as: UTF8.self) == "rri")
    #expect(await transport.sawAuthorizationHeader)
    #expect(await transport.methods.allSatisfy { ["PROPFIND", "GET"].contains($0) })
    #expect(await transport.depthOnePaths.filter { $0 == "/media" || $0 == "/media/" }.count == 1)
  }

  @Test("In-memory PROPFIND preserves source order, independent cursors, and late markers")
  func inMemoryDirectory() async throws {
    let executor = MemoryWebDAVExecutor(count: 2_001)
    let configuration = try WebDAVMediaSourceConfiguration(
      sourceUID: "memory-dav", baseURL: URL(string: "https://dav.example.test/media/")!
    )
    let connector = WebDAVMediaSourceConnector(
      configuration: configuration, transport: URLSessionWebDAVTransport(executor: executor))
    let session = try await connector.connect()
    let root = try RemoteLocator(sourceUID: configuration.sourceUID, path: RemotePath())
    var names: [String] = []
    var cursor: String?
    var firstCursor: String?
    repeat {
      let page = try await session.listDirectory(
        RemoteDirectoryPageRequest(directory: root, cursor: cursor, limit: 73))
      #expect(page.items.count <= 73)
      if firstCursor == nil {
        firstCursor = page.nextCursor
        let independent = try await session.listDirectory(
          RemoteDirectoryPageRequest(directory: root, limit: 10_000))
        #expect(independent.items.count == 2_001 && independent.nextCursor == nil)
      }
      names.append(contentsOf: page.items.map(\.locator.path.name))
      cursor = page.nextCursor
    } while cursor != nil
    #expect(names == (0..<2_001).reversed().map { "Video-\($0).mkv" })
    #expect(await executor.requestCount == 3)
    await session.disconnect()
    let resumed = try await connector.connect()
    let expiredCursor = firstCursor
    await expectSDKError(.conflict) {
      _ = try await resumed.listDirectory(
        RemoteDirectoryPageRequest(directory: root, cursor: expiredCursor, limit: 73))
    }
    await resumed.disconnect()

    let markerExecutor = MemoryWebDAVExecutor(
      count: 2_001, suffix: response(href: "/media/.nomedia", size: 0))
    let marked = try await WebDAVMediaSourceConnector(
      configuration: configuration, transport: URLSessionWebDAVTransport(executor: markerExecutor)
    ).connect()
    let page = try await marked.listDirectory(
      RemoteDirectoryPageRequest(directory: root, limit: 1),
      options: RemoteDirectoryEnumerationOptions(exclusionMarkerFileNames: [".nomedia"])
    )
    #expect(page.items.isEmpty && page.nextCursor == nil)
    await marked.disconnect()
  }

  @Test("Truncated or partly failed PROPFIND cannot publish an apparently complete directory")
  func incompleteXML() async throws {
    let configuration = try WebDAVMediaSourceConfiguration(
      sourceUID: "partial-dav", baseURL: URL(string: "https://dav.example.test/media/")!
    )
    for malformed in [true, false] {
      let executor = MemoryWebDAVExecutor(
        count: 5,
        suffix: malformed
          ? "<d:response>"
          : "<d:response><d:href>/media/missing.mkv</d:href><d:status>HTTP/1.1 403 Forbidden</d:status></d:response>"
      )
      let session = try await WebDAVMediaSourceConnector(
        configuration: configuration, transport: URLSessionWebDAVTransport(executor: executor)
      ).connect()
      await expectSDKError(malformed ? .parseFailure : .remoteUnavailable) {
        _ = try await session.listDirectory(
          RemoteDirectoryPageRequest(
            directory: RemoteLocator(sourceUID: configuration.sourceUID, path: RemotePath()),
            limit: 1
          ))
      }
      await session.disconnect()
    }
  }

  @Test(
    "Directory limits distinguish below, exact, and over-limit responses", arguments: [2, 3, 4])
  func directoryLimitBoundary(count: Int) throws {
    let configuration = try WebDAVMediaSourceConfiguration(
      sourceUID: "bounded", baseURL: URL(string: "https://dav.example.test/media/")!)
    let root = try RemoteLocator(sourceUID: configuration.sourceUID, path: RemotePath())
    // A late self response must not consume one of the three child slots.
    let body = multistatus(
      (0..<count).map { response(href: "/media/\($0)", collection: $0 == 1) }
        + [response(href: "/media/", collection: true)])
    let listing = try WebDAVDirectoryListing.parse(
      body, directory: root, baseURL: configuration.baseURL,
      semantics: configuration.pathSemantics, options: RemoteDirectoryEnumerationOptions(),
      maximumEntries: 3)
    #expect(listing.entries.map(\.locator.path.name) == (0..<min(count, 3)).map(String.init))
    #expect(listing.isTruncated == (count > 3))
  }

  @Test("Markers beyond the directory limit and the remaining XML are ignored")
  func ignoredDirectoryTail() throws {
    let configuration = try WebDAVMediaSourceConfiguration(
      sourceUID: "bounded", baseURL: URL(string: "https://dav.example.test/media/")!)
    let root = try RemoteLocator(sourceUID: configuration.sourceUID, path: RemotePath())
    let body = Data(
      ("<d:multistatus xmlns:d=\"DAV:\">"
        + response(href: "/media/keep.mkv")
        + response(href: "/media/.nomedia")
        + "<invalid-and-unclosed").utf8)
    let listing = try WebDAVDirectoryListing.parse(
      body, directory: root, baseURL: configuration.baseURL,
      semantics: configuration.pathSemantics,
      options: RemoteDirectoryEnumerationOptions(exclusionMarkerFileNames: [".nomedia"]),
      maximumEntries: 1)
    #expect(listing.entries.map(\.locator.path.name) == ["keep.mkv"])
    #expect(listing.isTruncated)
  }

  @Test("Large PROPFIND responses hit the byte budget before object materialization")
  func productionDirectoryLimit() async throws {
    let executor = MemoryWebDAVExecutor(count: 655_361)
    let configuration = try WebDAVMediaSourceConfiguration(
      sourceUID: "large-dav", baseURL: URL(string: "https://dav.example.test/media/")!)
    let session = try await WebDAVMediaSourceConnector(
      configuration: configuration, transport: URLSessionWebDAVTransport(executor: executor)
    ).connect()
    let root = try RemoteLocator(sourceUID: configuration.sourceUID, path: RemotePath())
    await expectSDKError(.resourceLimitExceeded) {
      _ = try await session.listDirectory(
        RemoteDirectoryPageRequest(directory: root, limit: 10_000))
    }
    await session.disconnect()
  }

  @Test("A failed optional-property propstat does not hide a valid collection")
  func partialPropertyFailure() async throws {
    let body = Data(
      """
      <?xml version="1.0" encoding="utf-8"?>
      <d:multistatus xmlns:d="DAV:"><d:response><d:href>/media/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><d:getlastmodified>Sun, 16 Aug 2026 00:00:00 GMT</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat><d:propstat><d:prop><d:getcontentlength/><d:getetag/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response></d:multistatus>
      """.utf8
    )
    let configuration = try WebDAVMediaSourceConfiguration(
      sourceUID: "webdav-partial-properties",
      baseURL: URL(string: "https://dav.example.test/media/")!
    )
    let connector = WebDAVMediaSourceConnector(
      configuration: configuration,
      transport: ConstantWebDAVTransport(
        response: WebDAVHTTPResponse(statusCode: 207, body: body)
      )
    )

    let session = try await connector.connect()
    let root = try RemoteLocator(sourceUID: configuration.sourceUID, path: RemotePath())
    let entry = try await session.stat(root)

    #expect(entry.kind == .directory)
    #expect(entry.size == nil)
  }

  @Test("Range GET follows a cross-origin HTTPS redirect without forwarding credentials")
  func rangeReadRedirect() async throws {
    let executor = ScriptedWebDAVRequestExecutor(responses: [
      WebDAVHTTPResponse(
        statusCode: 302,
        headers: ["Location": "https://cdn.example.test/signed/arrival.mkv?token=opaque"]
      ),
      WebDAVHTTPResponse(
        statusCode: 206,
        headers: ["Content-Range": "bytes 1-3/7"],
        body: Data("rri".utf8)
      ),
    ])
    let transport = URLSessionWebDAVTransport(executor: executor)

    let response = try await transport.send(
      WebDAVHTTPRequest(
        method: "GET",
        url: URL(string: "https://dav.example.test/media/Movies/Arrival.mkv")!,
        headers: [
          "Authorization": "Basic source-secret",
          "Cookie": "session=source-secret",
          "Host": "dav.example.test",
          "Proxy-Authorization": "Basic proxy-secret",
          "Range": "bytes=1-3",
        ]
      )
    )

    #expect(response.statusCode == 206)
    #expect(response.body == Data("rri".utf8))
    let requests = await executor.recordedRequests
    #expect(requests.count == 2)
    let redirected = try #require(requests.last)
    #expect(redirected.method == "GET")
    #expect(redirected.url.host == "cdn.example.test")
    #expect(header("Range", in: redirected) == "bytes=1-3")
    #expect(header("Authorization", in: redirected) == nil)
    #expect(header("Cookie", in: redirected) == nil)
    #expect(header("Host", in: redirected) == nil)
    #expect(header("Proxy-Authorization", in: redirected) == nil)
  }

  @Test("Same-origin redirects preserve WebDAV method, body, and authentication")
  func metadataRedirect() async throws {
    for statusCode in [301, 302, 307, 308] {
      let executor = ScriptedWebDAVRequestExecutor(responses: [
        WebDAVHTTPResponse(statusCode: statusCode, headers: ["location": "/media/"]),
        WebDAVHTTPResponse(statusCode: 207, body: Data("multistatus".utf8)),
      ])
      let transport = URLSessionWebDAVTransport(executor: executor)
      let body = Data("propfind-body".utf8)

      let response = try await transport.send(
        WebDAVHTTPRequest(
          method: "PROPFIND",
          url: URL(string: "https://dav.example.test/media")!,
          headers: [
            "Authorization": "Basic source-secret",
            "Content-Type": "application/xml",
            "Depth": "1",
          ],
          body: body
        )
      )

      #expect(response.statusCode == 207)
      let requests = await executor.recordedRequests
      #expect(requests.count == 2)
      let redirected = try #require(requests.last)
      #expect(redirected.method == "PROPFIND")
      #expect(redirected.url.absoluteString == "https://dav.example.test/media/")
      #expect(redirected.body == body)
      #expect(header("Depth", in: redirected) == "1")
      #expect(header("Authorization", in: redirected) == "Basic source-secret")
    }
  }

  @Test("Redirects reject downgrade, cross-origin metadata, and loops")
  func redirectSafety() async {
    let downgradeExecutor = ScriptedWebDAVRequestExecutor(responses: [
      WebDAVHTTPResponse(
        statusCode: 302,
        headers: ["Location": "http://cdn.example.test/arrival.mkv"]
      )
    ])
    await expectSDKError(.forbidden) {
      _ = try await URLSessionWebDAVTransport(executor: downgradeExecutor).send(
        WebDAVHTTPRequest(
          method: "GET",
          url: URL(string: "https://dav.example.test/media/Arrival.mkv")!
        )
      )
    }

    let metadataExecutor = ScriptedWebDAVRequestExecutor(responses: [
      WebDAVHTTPResponse(
        statusCode: 301,
        headers: ["Location": "https://other.example.test/media/"]
      )
    ])
    await expectSDKError(.forbidden) {
      _ = try await URLSessionWebDAVTransport(executor: metadataExecutor).send(
        WebDAVHTTPRequest(
          method: "PROPFIND",
          url: URL(string: "https://dav.example.test/media/")!
        )
      )
    }

    let loopExecutor = ScriptedWebDAVRequestExecutor(responses: [
      WebDAVHTTPResponse(statusCode: 302, headers: ["Location": "/second"]),
      WebDAVHTTPResponse(statusCode: 302, headers: ["Location": "/first"]),
    ])
    await expectSDKError(.remoteUnavailable) {
      _ = try await URLSessionWebDAVTransport(executor: loopExecutor).send(
        WebDAVHTTPRequest(
          method: "GET",
          url: URL(string: "https://dav.example.test/first")!
        )
      )
    }
    #expect(await loopExecutor.recordedRequests.count == 2)

    let limitExecutor = ScriptedWebDAVRequestExecutor(
      responses: (1...6).map {
        WebDAVHTTPResponse(statusCode: 302, headers: ["Location": "/redirect-\($0)"])
      }
    )
    await expectSDKError(.remoteUnavailable) {
      _ = try await URLSessionWebDAVTransport(executor: limitExecutor).send(
        WebDAVHTTPRequest(
          method: "GET",
          url: URL(string: "https://dav.example.test/redirect-0")!
        )
      )
    }
    #expect(await limitExecutor.recordedRequests.count == 6)
  }

  @Test("The shared scanner recursively scans the fake WebDAV transport")
  func scannerIntegration() async throws {
    let transport = FixtureWebDAVTransport()
    let configuration = try WebDAVMediaSourceConfiguration(
      sourceUID: "webdav-scanner-fixture",
      baseURL: URL(string: "https://dav.example.test/media/")!
    )
    let connector = WebDAVMediaSourceConnector(
      configuration: configuration,
      transport: transport
    )
    let root = try RemoteLocator(sourceUID: configuration.sourceUID, path: RemotePath())
    let request = try MediaScanRequest(
      runUID: "webdav-full-scan",
      sourceUID: configuration.sourceUID,
      mode: .full,
      roots: [root]
    )
    let sink = WebDAVScannerSink()
    let scanner = MediaScanner(
      configuration: try MediaScannerConfiguration(
        pageSize: 1,
        maxConcurrentDirectoryRequests: 2
      )
    )

    let result = try await scanner.scan(request, using: connector, sink: sink)

    #expect(result.checkpoint.phase == .completed)
    #expect(result.checkpoint.discoveredEntryCount == 3)
    #expect(result.checkpoint.processedPageCount == 3)
    #expect(result.completion.reconcileMissingEligible)
    #expect(await sink.paths == ["Movies", "Movies/Arrival.mkv", "Notes.txt"])
    #expect(await transport.depthOnePaths == ["/media", "/media/Movies"])
  }

  @Test("Authentication, TLS, and escaped href failures remain non-authoritative")
  func failureMapping() async throws {
    let baseURL = URL(string: "https://dav.example.test/media/")!
    #expect(throws: SDKError.self) {
      _ = try WebDAVMediaSourceConfiguration(
        sourceUID: "insecure",
        baseURL: URL(string: "http://dav.example.test/media/")!
      )
    }
    #expect(throws: SDKError.self) {
      _ = try WebDAVMediaSourceConfiguration(
        sourceUID: "userinfo",
        baseURL: URL(string: "https://alice:secret@dav.example.test/media/")!
      )
    }

    let configuration = try WebDAVMediaSourceConfiguration(
      sourceUID: "webdav-failure-fixture",
      baseURL: baseURL
    )
    let unauthorized = WebDAVMediaSourceConnector(
      configuration: configuration,
      transport: ConstantWebDAVTransport(response: WebDAVHTTPResponse(statusCode: 401))
    )
    await #expect(throws: SDKError.self) {
      _ = try await unauthorized.connect()
    }

    let tlsFailure = WebDAVMediaSourceConnector(
      configuration: configuration,
      transport: FailingWebDAVTransport(
        error: SDKError(code: .forbidden, message: "WebDAV TLS validation failed")
      )
    )
    await #expect(throws: SDKError.self) {
      _ = try await tlsFailure.connect()
    }

    let escapedTransport = EscapedHrefWebDAVTransport()
    let escapedConnector = WebDAVMediaSourceConnector(
      configuration: configuration,
      transport: escapedTransport
    )
    let escapedSession = try await escapedConnector.connect()
    let root = try RemoteLocator(sourceUID: configuration.sourceUID, path: RemotePath())
    await #expect(throws: SDKError.self) {
      _ = try await escapedSession.listDirectory(
        RemoteDirectoryPageRequest(directory: root, limit: 10)
      )
    }

    let sink = WebDAVScannerSink()
    let scanner = MediaScanner()
    await #expect(throws: SDKError.self) {
      _ = try await scanner.scan(
        MediaScanRequest(
          runUID: "webdav-escaped-scan",
          sourceUID: configuration.sourceUID,
          mode: .full,
          roots: [root]
        ),
        using: escapedConnector,
        sink: sink
      )
    }
    #expect(await sink.completion == nil)
  }
}

private actor ScriptedWebDAVRequestExecutor: WebDAVRequestExecutor {
  private var responses: [WebDAVHTTPResponse]
  private(set) var recordedRequests: [WebDAVHTTPRequest] = []

  init(responses: [WebDAVHTTPResponse]) {
    self.responses = responses
  }

  func execute(_ request: WebDAVHTTPRequest) async throws -> WebDAVHTTPResponse {
    recordedRequests.append(request)
    guard !responses.isEmpty else {
      throw SDKError(code: .remoteUnavailable, message: "WebDAV test response is missing")
    }
    return responses.removeFirst()
  }
}

private func header(_ name: String, in request: WebDAVHTTPRequest) -> String? {
  request.headers.first(where: {
    $0.key.caseInsensitiveCompare(name) == .orderedSame
  })?.value
}

private func expectSDKError(
  _ expectedCode: SDKErrorCode,
  operation: @Sendable () async throws -> Void
) async {
  do {
    try await operation()
    Issue.record("Expected SDKError with code \(expectedCode.rawValue)")
  } catch let error as SDKError {
    #expect(error.code == expectedCode)
  } catch {
    Issue.record("Expected SDKError but received \(type(of: error))")
  }
}

private actor FixtureWebDAVTransport: WebDAVTransport {
  private(set) var methods: [String] = []
  private(set) var depthOnePaths: [String] = []
  private(set) var sawAuthorizationHeader = false

  func send(_ request: WebDAVHTTPRequest) async throws -> WebDAVHTTPResponse {
    methods.append(request.method)
    if request.headers["Authorization"]?.hasPrefix("Basic ") == true {
      sawAuthorizationHeader = true
    }
    let path = request.url.path
    if request.method == "GET", path == "/media/Movies/Arrival.mkv" {
      return WebDAVHTTPResponse(statusCode: 206, body: Data("rri".utf8))
    }
    guard request.method == "PROPFIND" else {
      return WebDAVHTTPResponse(statusCode: 405)
    }
    let depth = request.headers["Depth"]
    if depth == "1" {
      depthOnePaths.append(path)
    }
    switch (path, depth) {
    case ("/media/", "0"), ("/media", "0"):
      return WebDAVHTTPResponse(statusCode: 207, body: Self.rootStatXML)
    case ("/media/", "1"), ("/media", "1"):
      return WebDAVHTTPResponse(statusCode: 207, body: Self.rootListXML)
    case ("/media/Movies", "1"), ("/media/Movies/", "1"):
      return WebDAVHTTPResponse(statusCode: 207, body: Self.moviesListXML)
    case ("/media/Movies/Arrival.mkv", "0"):
      return WebDAVHTTPResponse(statusCode: 207, body: Self.arrivalStatXML)
    default:
      return WebDAVHTTPResponse(statusCode: 404)
    }
  }

  private static let rootStatXML = multistatus([
    response(href: "/media/", collection: true)
  ])
  private static let rootListXML = multistatus([
    response(href: "/media/", collection: true),
    response(href: "/media/Notes.txt", size: 5, etag: "notes-v1"),
    response(href: "/media/Movies/", collection: true),
  ])
  private static let moviesListXML = multistatus([
    response(href: "/media/Movies/", collection: true),
    response(href: "/media/Movies/Arrival.mkv", size: 7, etag: "arrival-v1"),
  ])
  private static let arrivalStatXML = multistatus([
    response(href: "/media/Movies/Arrival.mkv", size: 7, etag: "arrival-v1")
  ])
}

private struct ConstantWebDAVTransport: WebDAVTransport {
  let response: WebDAVHTTPResponse

  func send(_: WebDAVHTTPRequest) async throws -> WebDAVHTTPResponse { response }
}

private struct FailingWebDAVTransport: WebDAVTransport {
  let error: SDKError

  func send(_: WebDAVHTTPRequest) async throws -> WebDAVHTTPResponse { throw error }
}

private actor EscapedHrefWebDAVTransport: WebDAVTransport {
  private var requestCount = 0

  func send(_ request: WebDAVHTTPRequest) async throws -> WebDAVHTTPResponse {
    requestCount += 1
    if request.headers["Depth"] == "0" {
      return WebDAVHTTPResponse(
        statusCode: 207,
        body: multistatus([response(href: "/media/", collection: true)])
      )
    }
    return WebDAVHTTPResponse(
      statusCode: 207,
      body: multistatus([
        response(href: "/media/", collection: true),
        response(href: "https://evil.example.test/stolen.mkv", size: 7),
      ])
    )
  }
}

private actor WebDAVScannerSink: MediaScanSink {
  private var entries: [String: RemoteEntry] = [:]
  private(set) var completion: MediaScanCompletion?

  var paths: [String] {
    entries.values.map(\.locator.path.relativePath).sorted()
  }

  func commit(_ batch: MediaScanBatch) async throws {
    for entry in batch.entries {
      entries[entry.locator.path.relativePath] = entry
    }
    if let completion = batch.completion {
      self.completion = completion
    }
  }
}

private func multistatus(_ responses: [String]) -> Data {
  Data(
    """
    <?xml version="1.0" encoding="utf-8"?>
    <d:multistatus xmlns:d="DAV:">\(responses.joined())</d:multistatus>
    """.utf8
  )
}

private func response(
  href: String,
  collection: Bool = false,
  size: Int? = nil,
  etag: String? = nil
) -> String {
  let resourceType =
    collection ? "<d:resourcetype><d:collection/></d:resourcetype>" : "<d:resourcetype/>"
  let contentLength = size.map { "<d:getcontentlength>\($0)</d:getcontentlength>" } ?? ""
  let entityTag = etag.map { "<d:getetag>&quot;\($0)&quot;</d:getetag>" } ?? ""
  return """
    <d:response><d:href>\(href)</d:href><d:propstat><d:prop>\(resourceType)\(contentLength)<d:getlastmodified>Sun, 16 Aug 2026 00:00:00 GMT</d:getlastmodified>\(entityTag)</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
    """
}

private actor MemoryWebDAVExecutor: WebDAVRequestExecutor {
  let count: Int
  let suffix: String
  private(set) var requestCount = 0

  init(count: Int, suffix: String = "") {
    self.count = count
    self.suffix = suffix
  }

  func execute(_ request: WebDAVHTTPRequest) async throws -> WebDAVHTTPResponse {
    requestCount += 1
    var data = Data("<d:multistatus xmlns:d=\"DAV:\">".utf8)
    data.append(Data(response(href: "/media/", collection: true).utf8))
    if request.headers["Depth"] == "1" {
      for index in (0..<count).reversed() {
        // No date parsing is needed for the real 655,360-entry boundary test.
        data.append(
          Data(
            "<d:response><d:href>/media/Video-\(index).mkv</d:href><d:status>HTTP/1.1 200 OK</d:status></d:response>"
              .utf8))
      }
      data.append(Data(suffix.utf8))
    }
    data.append(Data("</d:multistatus>".utf8))
    return WebDAVHTTPResponse(statusCode: 207, body: data)
  }
}

private final class BudgetWebDAVProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let headers = request.url?.lastPathComponent == "declared" ? ["Content-Length": "8192"] : [:]
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 207, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 8_192))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

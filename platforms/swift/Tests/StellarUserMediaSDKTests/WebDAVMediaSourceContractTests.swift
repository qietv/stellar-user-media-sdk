import Foundation
import StellarCore
import StellarMediaLibrary
import StellarRemoteMedia
import StellarWebDAV
import Testing

@Suite("WebDAV media source contracts")
struct WebDAVMediaSourceContractTests {
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
    #expect(firstPage.items.map(\.locator.path.relativePath) == ["Movies"])
    #expect(firstPage.nextCursor != nil)
    #expect(secondPage.items.map(\.locator.path.relativePath) == ["Notes.txt"])
    #expect(secondPage.nextCursor == nil)
    #expect(stat.kind == .file)
    #expect(stat.size == 7)
    #expect(stat.entityTag == "\"arrival-v1\"")
    #expect(String(decoding: bytes, as: UTF8.self) == "rri")
    #expect(await transport.sawAuthorizationHeader)
    #expect(await transport.methods.allSatisfy { ["PROPFIND", "GET"].contains($0) })
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

private actor FixtureWebDAVTransport: WebDAVTransport {
  private(set) var methods: [String] = []
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

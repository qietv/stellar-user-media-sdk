import Foundation
import StellarCore
import StellarRemoteMedia

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
#if canImport(FoundationXML)
  import FoundationXML
#endif

/// An ephemeral WebDAV username and password that always renders as redacted.
public struct WebDAVCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  fileprivate let authorizationValue: String

  public init(username: String, password: String) throws {
    guard !username.isEmpty, !username.contains("\0"), !password.contains("\0"),
      !username.contains(":")
    else {
      throw SDKError(code: .invalidConfiguration, message: "WebDAV credential is invalid")
    }
    authorizationValue = "Basic \(Data("\(username):\(password)".utf8).base64EncodedString())"
  }

  /// A representation that never contains credential material.
  public var description: String { "<WebDAVCredential redacted>" }

  /// A representation that never contains credential material.
  public var debugDescription: String { description }
}

/// Read-only configuration for one WebDAV collection root.
public struct WebDAVMediaSourceConfiguration: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let sourceUID: String
  public let baseURL: URL
  public let credential: WebDAVCredential?
  public let pathSemantics: RemotePathSemantics

  public init(
    sourceUID: String,
    baseURL: URL,
    credential: WebDAVCredential? = nil,
    allowsInsecureHTTP: Bool = false,
    pathSemantics: RemotePathSemantics = RemotePathSemantics(
      caseSensitivity: .unknown,
      unicodeNormalization: .preserve
    )
  ) throws {
    guard !sourceUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !sourceUID.contains("\0"),
      baseURL.user == nil,
      baseURL.password == nil,
      baseURL.query == nil,
      baseURL.fragment == nil,
      baseURL.host?.isEmpty == false,
      baseURL.scheme?.lowercased() == "https"
        || (allowsInsecureHTTP && baseURL.scheme?.lowercased() == "http")
    else {
      throw SDKError(
        code: .invalidConfiguration,
        message: "WebDAV media source configuration is invalid"
      )
    }
    self.sourceUID = sourceUID
    self.baseURL = baseURL.standardized
    self.credential = credential
    self.pathSemantics = pathSemantics
  }

  /// A representation that hides URL, source, and credential values.
  public var description: String { "<WebDAVMediaSourceConfiguration redacted>" }

  /// A representation that hides URL, source, and credential values.
  public var debugDescription: String { description }
}

/// A redacted HTTP request value used by the injectable WebDAV transport.
public struct WebDAVHTTPRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public let method: String
  public let url: URL
  public let headers: [String: String]
  public let body: Data?

  public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
  }

  /// A representation that hides URL, headers, and body.
  public var description: String { "<WebDAVHTTPRequest method=\(method) redacted>" }

  /// A representation that hides URL, headers, and body.
  public var debugDescription: String { description }
}

/// The transport response required by the read-only WebDAV connector.
public struct WebDAVHTTPResponse: Sendable {
  public let statusCode: Int
  public let headers: [String: String]
  public let body: Data

  public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
    self.statusCode = statusCode
    self.headers = headers
    self.body = body
  }
}

/// Injectable HTTP boundary for WebDAV connector and server-free contract tests.
public protocol WebDAVTransport: Sendable {
  func send(_ request: WebDAVHTTPRequest) async throws -> WebDAVHTTPResponse
}

protocol WebDAVRequestExecutor: Sendable {
  func execute(_ request: WebDAVHTTPRequest) async throws -> WebDAVHTTPResponse
}

/// Cross-platform URLSession transport with bounded, credential-safe redirect handling.
public struct URLSessionWebDAVTransport: WebDAVTransport {
  private let executor: any WebDAVRequestExecutor

  public init() {
    executor = FoundationWebDAVRequestExecutor()
  }

  init(executor: any WebDAVRequestExecutor) {
    self.executor = executor
  }

  public func send(_ request: WebDAVHTTPRequest) async throws -> WebDAVHTTPResponse {
    do {
      return try await sendFollowingRedirects(request)
    } catch let error as SDKError {
      throw error
    } catch let error as URLError {
      switch error.code {
      case .cancelled:
        throw SDKError(code: .cancelled, message: "WebDAV request cancelled")
      case .notConnectedToInternet, .networkConnectionLost:
        throw SDKError(code: .networkUnavailable, message: "WebDAV network is unavailable")
      case .serverCertificateHasBadDate, .serverCertificateUntrusted,
        .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
        .clientCertificateRejected, .clientCertificateRequired:
        throw SDKError(code: .forbidden, message: "WebDAV TLS validation failed")
      case .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
        throw SDKError(code: .remoteUnavailable, message: "WebDAV server is unavailable")
      default:
        throw SDKError(code: .remoteUnavailable, message: "WebDAV request failed")
      }
    } catch {
      throw SDKError(code: .remoteUnavailable, message: "WebDAV request failed")
    }
  }

  private func sendFollowingRedirects(_ request: WebDAVHTTPRequest) async throws
    -> WebDAVHTTPResponse
  {
    var currentRequest = request
    var visitedURLs: Set<String> = [Self.redirectIdentity(request.url)]
    var redirectCount = 0

    while true {
      let response = try await executor.execute(currentRequest)
      guard Self.redirectStatusCodes.contains(response.statusCode) else {
        return response
      }
      guard redirectCount < Self.maximumRedirectCount else {
        throw SDKError(code: .remoteUnavailable, message: "WebDAV redirect limit exceeded")
      }

      let redirectedRequest = try Self.redirectedRequest(
        from: currentRequest,
        response: response
      )
      guard visitedURLs.insert(Self.redirectIdentity(redirectedRequest.url)).inserted else {
        throw SDKError(code: .remoteUnavailable, message: "WebDAV redirect loop detected")
      }
      currentRequest = redirectedRequest
      redirectCount += 1
    }
  }

  private static func redirectedRequest(
    from request: WebDAVHTTPRequest,
    response: WebDAVHTTPResponse
  ) throws -> WebDAVHTTPRequest {
    guard
      let location = response.headers.first(where: {
        $0.key.caseInsensitiveCompare("Location") == .orderedSame
      })?.value,
      let targetURL = URL(string: location, relativeTo: request.url)?.absoluteURL,
      targetURL.host?.isEmpty == false,
      targetURL.user == nil,
      targetURL.password == nil,
      targetURL.fragment == nil
    else {
      throw SDKError(code: .remoteUnavailable, message: "WebDAV redirect target is invalid")
    }

    guard let sourceOrigin = origin(of: request.url),
      let targetOrigin = origin(of: targetURL)
    else {
      throw SDKError(code: .remoteUnavailable, message: "WebDAV redirect target is invalid")
    }
    let sameOrigin = sourceOrigin == targetOrigin
    let targetScheme = targetURL.scheme?.lowercased()
    let sourceScheme = request.url.scheme?.lowercased()
    guard targetScheme == "https" || (sameOrigin && sourceScheme == "http") else {
      throw SDKError(code: .forbidden, message: "WebDAV redirect is not secure")
    }

    let method = request.method.uppercased()
    guard sameOrigin || method == "GET" || method == "HEAD" else {
      throw SDKError(
        code: .forbidden,
        message: "WebDAV metadata redirect escaped the configured origin"
      )
    }

    let headers = request.headers.filter { name, _ in
      let normalizedName = name.lowercased()
      if normalizedName == "host" {
        return false
      }
      if !sameOrigin, sensitiveRedirectHeaders.contains(normalizedName) {
        return false
      }
      return true
    }
    return WebDAVHTTPRequest(
      method: request.method,
      url: targetURL,
      headers: headers,
      body: request.body
    )
  }

  private static func origin(of url: URL) -> WebDAVOrigin? {
    guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
      return nil
    }
    let port: Int?
    if let explicitPort = url.port {
      port = explicitPort
    } else if scheme == "https" {
      port = 443
    } else if scheme == "http" {
      port = 80
    } else {
      port = nil
    }
    return WebDAVOrigin(scheme: scheme, host: host, port: port)
  }

  private static func redirectIdentity(_ url: URL) -> String {
    url.standardized.absoluteString
  }

  private static let maximumRedirectCount = 5
  private static let redirectStatusCodes: Set<Int> = [301, 302, 307, 308]
  private static let sensitiveRedirectHeaders: Set<String> = [
    "authorization", "cookie", "cookie2", "proxy-authorization",
  ]
}

private struct WebDAVOrigin: Equatable {
  let scheme: String
  let host: String
  let port: Int?
}

private struct FoundationWebDAVRequestExecutor: WebDAVRequestExecutor {
  func execute(_ request: WebDAVHTTPRequest) async throws -> WebDAVHTTPResponse {
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = request.method
    urlRequest.httpBody = request.body
    for (name, value) in request.headers {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }
    let session = URLSession(
      configuration: .ephemeral,
      delegate: WebDAVNoRedirectDelegate.shared,
      delegateQueue: nil
    )
    defer { session.invalidateAndCancel() }
    let (data, response) = try await session.data(for: urlRequest)
    guard let response = response as? HTTPURLResponse else {
      throw SDKError(code: .remoteUnavailable, message: "WebDAV response is not HTTP")
    }
    var headers: [String: String] = [:]
    for (name, value) in response.allHeaderFields {
      headers[String(describing: name).lowercased()] = String(describing: value)
    }
    return WebDAVHTTPResponse(
      statusCode: response.statusCode,
      headers: headers,
      body: data
    )
  }
}

/// Connects a read-only WebDAV collection to the shared media scanner.
public struct WebDAVMediaSourceConnector: MediaSourceConnector {
  public let configuration: WebDAVMediaSourceConfiguration
  private let transport: any WebDAVTransport

  public init(
    configuration: WebDAVMediaSourceConfiguration,
    transport: any WebDAVTransport = URLSessionWebDAVTransport()
  ) {
    self.configuration = configuration
    self.transport = transport
  }

  public func connect() async throws -> any MediaSourceSession {
    let capabilities = try MediaSourceCapabilities(
      stableIDScope: .none,
      pathSemantics: configuration.pathSemantics,
      supportsRangeReads: true,
      supportsChangeCursor: false,
      deltaDeletionsComplete: false
    )
    let session = WebDAVMediaSourceSession(
      configuration: configuration,
      capabilities: capabilities,
      transport: transport
    )
    try await session.validateRoot()
    return session
  }
}

/// A connected, read-only WebDAV media source session.
public actor WebDAVMediaSourceSession: MediaSourceSession {
  public nonisolated let sourceUID: String
  public nonisolated let capabilities: MediaSourceCapabilities

  private let configuration: WebDAVMediaSourceConfiguration
  private let transport: any WebDAVTransport
  private var disconnected = false

  fileprivate init(
    configuration: WebDAVMediaSourceConfiguration,
    capabilities: MediaSourceCapabilities,
    transport: any WebDAVTransport
  ) {
    sourceUID = configuration.sourceUID
    self.configuration = configuration
    self.capabilities = capabilities
    self.transport = transport
  }

  fileprivate func validateRoot() async throws {
    let root = try RemoteLocator(sourceUID: sourceUID, path: RemotePath())
    let entry = try await stat(root)
    guard entry.kind == .directory else {
      throw SDKError(code: .invalidConfiguration, message: "WebDAV root is not a collection")
    }
  }

  public func listDirectory(_ request: RemoteDirectoryPageRequest) async throws
    -> CursorPage<RemoteEntry>
  {
    try requireConnected()
    let directoryURL = try url(for: request.directory)
    let response = try await sendPROPFIND(url: directoryURL, depth: "1")
    var entries = try WebDAVMultiStatusParser.parse(
      response.body,
      sourceUID: sourceUID,
      baseURL: configuration.baseURL
    )
    let directoryKey = request.directory.pathComparisonKey(using: capabilities.pathSemantics)
    entries.removeAll {
      $0.locator.pathComparisonKey(using: capabilities.pathSemantics) == directoryKey
    }
    entries.sort { left, right in
      let leftKey = left.locator.pathComparisonKey(using: capabilities.pathSemantics)
      let rightKey = right.locator.pathComparisonKey(using: capabilities.pathSemantics)
      if leftKey == rightKey {
        return left.locator.path.relativePath < right.locator.path.relativePath
      }
      return leftKey < rightKey
    }
    let fingerprint = fingerprint(entries)
    let offset: Int
    if let cursor = request.cursor {
      let parsed = try WebDAVDirectoryCursor(cursor)
      guard parsed.fingerprint == fingerprint, parsed.offset <= entries.count else {
        throw SDKError(code: .conflict, message: "WebDAV directory changed during pagination")
      }
      offset = parsed.offset
    } else {
      offset = 0
    }
    let count = min(request.limit, entries.count - offset)
    let upperBound = offset + count
    let pageEntries = Array(entries[offset..<upperBound])
    let nextCursor: String?
    if upperBound < entries.count {
      nextCursor =
        WebDAVDirectoryCursor(
          offset: upperBound,
          fingerprint: fingerprint
        ).rawValue
    } else {
      nextCursor = nil
    }
    return try CursorPage(items: pageEntries, nextCursor: nextCursor)
  }

  public func stat(_ locator: RemoteLocator) async throws -> RemoteEntry {
    try requireConnected()
    let targetURL = try url(for: locator)
    let response = try await sendPROPFIND(url: targetURL, depth: "0")
    let entries = try WebDAVMultiStatusParser.parse(
      response.body,
      sourceUID: sourceUID,
      baseURL: configuration.baseURL
    )
    guard let entry = entries.first(where: { $0.locator == locator }) else {
      throw SDKError(code: .metadataNotFound, message: "WebDAV entry was not found")
    }
    return entry
  }

  public func read(at locator: RemoteLocator, range: RemoteByteRange) async throws -> Data {
    try requireConnected()
    let upperBound = range.offset + Int64(range.length) - 1
    let response = try await transport.send(
      request(
        method: "GET",
        url: try url(for: locator),
        headers: ["Range": "bytes=\(range.offset)-\(upperBound)"]
      )
    )
    try validateStatus(response.statusCode, allowsMultiStatus: false, allowsPartialContent: true)
    guard response.statusCode == 206 else {
      throw SDKError(code: .remoteUnavailable, message: "WebDAV server ignored range request")
    }
    return response.body.count <= range.length
      ? response.body
      : response.body.prefix(range.length)
  }

  public func disconnect() async {
    disconnected = true
  }

  private func sendPROPFIND(url: URL, depth: String) async throws -> WebDAVHTTPResponse {
    let body = Data(
      """
      <?xml version="1.0" encoding="utf-8" ?>
      <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:getetag/></d:prop></d:propfind>
      """.utf8
    )
    let response = try await transport.send(
      request(
        method: "PROPFIND",
        url: url,
        headers: ["Depth": depth, "Content-Type": "application/xml; charset=utf-8"],
        body: body
      )
    )
    try validateStatus(response.statusCode, allowsMultiStatus: true, allowsPartialContent: false)
    return response
  }

  private func request(
    method: String,
    url: URL,
    headers: [String: String],
    body: Data? = nil
  ) -> WebDAVHTTPRequest {
    var headers = headers
    if let credential = configuration.credential {
      headers["Authorization"] = credential.authorizationValue
    }
    return WebDAVHTTPRequest(method: method, url: url, headers: headers, body: body)
  }

  private func validateStatus(
    _ statusCode: Int,
    allowsMultiStatus: Bool,
    allowsPartialContent: Bool
  ) throws {
    if (200...299).contains(statusCode),
      statusCode != 207 || allowsMultiStatus,
      statusCode != 206 || allowsPartialContent
    {
      return
    }
    switch statusCode {
    case 401:
      throw SDKError(code: .unauthorized, message: "WebDAV authentication failed")
    case 403:
      throw SDKError(code: .forbidden, message: "WebDAV access was denied")
    case 404:
      throw SDKError(code: .metadataNotFound, message: "WebDAV entry was not found")
    case 429:
      throw SDKError(code: .rateLimited, message: "WebDAV server rate limited the request")
    case 408, 500...599:
      throw SDKError(code: .remoteUnavailable, message: "WebDAV server is unavailable")
    default:
      throw SDKError(code: .remoteUnavailable, message: "WebDAV protocol operation failed")
    }
  }

  private func url(for locator: RemoteLocator) throws -> URL {
    guard locator.sourceUID == sourceUID else {
      throw SDKError(code: .invalidConfiguration, message: "WebDAV source UID does not match")
    }
    var result = configuration.baseURL
    for component in locator.path.components {
      result.appendPathComponent(component, isDirectory: false)
    }
    return result
  }

  private func requireConnected() throws {
    guard !disconnected else {
      throw SDKError(code: .remoteUnavailable, message: "WebDAV media session is disconnected")
    }
  }

  private func fingerprint(_ entries: [RemoteEntry]) -> String {
    Self.fingerprint(entries, semantics: capabilities.pathSemantics)
  }

  private static func fingerprint(
    _ entries: [RemoteEntry],
    semantics: RemotePathSemantics
  ) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for entry in entries {
      let fields = [
        entry.locator.pathComparisonKey(using: semantics),
        entry.kind.rawValue,
        entry.size.map(String.init) ?? "",
        entry.modifiedAtMilliseconds.map(String.init) ?? "",
        entry.entityTag ?? "",
      ]
      for byte in fields.joined(separator: "\u{1f}").utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
      }
      hash ^= 0xff
      hash &*= 1_099_511_628_211
    }
    return String(format: "%016llx", hash)
  }

  private struct WebDAVDirectoryCursor {
    let offset: Int
    let fingerprint: String

    var rawValue: String { "webdav-v1:\(offset):\(fingerprint)" }

    init(offset: Int, fingerprint: String) {
      self.offset = offset
      self.fingerprint = fingerprint
    }

    init(_ rawValue: String) throws {
      let components = rawValue.split(separator: ":", omittingEmptySubsequences: false)
      guard components.count == 3,
        components[0] == "webdav-v1",
        let offset = Int(components[1]),
        offset > 0,
        components[2].count == 16,
        components[2].allSatisfy({ $0.isHexDigit })
      else {
        throw SDKError(code: .invalidConfiguration, message: "WebDAV page cursor is invalid")
      }
      self.offset = offset
      fingerprint = String(components[2])
    }
  }
}

private final class WebDAVNoRedirectDelegate: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable
{
  static let shared = WebDAVNoRedirectDelegate()

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

private enum WebDAVMultiStatusParser {
  static func parse(
    _ data: Data,
    sourceUID: String,
    baseURL: URL
  ) throws -> [RemoteEntry] {
    let delegate = MultiStatusDelegate(sourceUID: sourceUID, baseURL: baseURL)
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse() else {
      throw SDKError(code: .parseFailure, message: "WebDAV multistatus XML is invalid")
    }
    return try delegate.entries.get()
  }

  private final class MultiStatusDelegate: NSObject, XMLParserDelegate, @unchecked Sendable {
    private let sourceUID: String
    private let baseURL: URL
    private var current: ResponseFields?
    private var currentPropstat: PropertyFields?
    private var elementStack: [String] = []
    private var text = ""
    fileprivate var entries: Result<[RemoteEntry], Error> = .success([])

    init(sourceUID: String, baseURL: URL) {
      self.sourceUID = sourceUID
      self.baseURL = baseURL
    }

    func parser(
      _: XMLParser,
      didStartElement elementName: String,
      namespaceURI _: String?,
      qualifiedName _: String?,
      attributes _: [String: String] = [:]
    ) {
      let name = localName(elementName)
      elementStack.append(name)
      text = ""
      if name == "response" {
        current = ResponseFields()
        currentPropstat = nil
      } else if name == "propstat" {
        currentPropstat = PropertyFields()
      } else if name == "collection" {
        currentPropstat?.isCollection = true
      }
    }

    func parser(_: XMLParser, foundCharacters string: String) {
      text += string
    }

    func parser(
      _: XMLParser,
      didEndElement elementName: String,
      namespaceURI _: String?,
      qualifiedName _: String?
    ) {
      let name = localName(elementName)
      let parentName = elementStack.dropLast().last
      let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
      defer {
        if elementStack.last == name {
          elementStack.removeLast()
        }
        text = ""
      }
      guard entries.isSuccess else { return }
      switch name {
      case "href" where parentName == "response":
        current?.href = value
      case "getcontentlength":
        currentPropstat?.size = Int64(value)
      case "getlastmodified":
        currentPropstat?.modifiedAtMilliseconds = Self.parseHTTPDate(value)
      case "getetag":
        currentPropstat?.entityTag = value.isEmpty ? nil : value
      case "status":
        if currentPropstat != nil {
          currentPropstat?.isSuccessful = Self.isSuccessfulStatus(value)
        } else {
          current?.isSuccessful = Self.isSuccessfulStatus(value)
        }
      case "propstat":
        if let currentPropstat {
          current?.include(currentPropstat)
        }
        currentPropstat = nil
      case "response":
        if let current, current.isSuccessful {
          do {
            let entry = try makeEntry(current)
            entries = entries.map { $0 + [entry] }
          } catch {
            entries = .failure(error)
          }
        }
        current = nil
        currentPropstat = nil
      default:
        break
      }
    }

    private func makeEntry(_ fields: ResponseFields) throws -> RemoteEntry {
      guard let href = fields.href,
        let hrefURL = URL(string: href, relativeTo: baseURL)?.absoluteURL,
        hrefURL.scheme?.lowercased() == baseURL.scheme?.lowercased(),
        hrefURL.host?.lowercased() == baseURL.host?.lowercased(),
        hrefURL.port == baseURL.port
      else {
        throw SDKError(code: .parseFailure, message: "WebDAV href is invalid")
      }
      let baseComponents = baseURL.pathComponents
      let hrefComponents = hrefURL.pathComponents
      guard hrefComponents.count >= baseComponents.count,
        hrefComponents.prefix(baseComponents.count).elementsEqual(baseComponents)
      else {
        throw SDKError(code: .forbidden, message: "WebDAV href escaped the configured root")
      }
      let relativeComponents = hrefComponents.dropFirst(baseComponents.count)
      let path = try RemotePath(relativeComponents.joined(separator: "/"))
      let locator = try RemoteLocator(sourceUID: sourceUID, path: path)
      return try RemoteEntry(
        locator: locator,
        kind: fields.isCollection ? .directory : .file,
        size: fields.isCollection ? nil : fields.size,
        modifiedAtMilliseconds: fields.modifiedAtMilliseconds,
        entityTag: fields.entityTag
      )
    }

    private func localName(_ name: String) -> String {
      name.split(separator: ":").last.map { $0.lowercased() } ?? name.lowercased()
    }

    private static func parseHTTPDate(_ value: String) -> Int64? {
      guard !value.isEmpty else { return nil }
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
      return formatter.date(from: value).map {
        Int64(($0.timeIntervalSince1970 * 1_000).rounded(.towardZero))
      }
    }

    private static func isSuccessfulStatus(_ value: String) -> Bool {
      let fields = value.split(whereSeparator: { $0.isWhitespace })
      guard fields.count >= 2, let statusCode = Int(fields[1]) else { return false }
      return (200...299).contains(statusCode)
    }

    private struct ResponseFields {
      var href: String?
      var isCollection = false
      var size: Int64?
      var modifiedAtMilliseconds: Int64?
      var entityTag: String?
      var isSuccessful = false

      mutating func include(_ properties: PropertyFields) {
        guard properties.isSuccessful else { return }
        isSuccessful = true
        isCollection = isCollection || properties.isCollection
        size = properties.size ?? size
        modifiedAtMilliseconds = properties.modifiedAtMilliseconds ?? modifiedAtMilliseconds
        entityTag = properties.entityTag ?? entityTag
      }
    }

    private struct PropertyFields {
      var isCollection = false
      var size: Int64?
      var modifiedAtMilliseconds: Int64?
      var entityTag: String?
      var isSuccessful = false
    }
  }
}

extension Result {
  fileprivate var isSuccess: Bool {
    if case .success = self { return true }
    return false
  }
}

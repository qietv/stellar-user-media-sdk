import Foundation
import StellarCore
import StellarRemoteMedia

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
    let session = makeSession()
    defer { session.invalidateAndCancel() }
    let (data, response) = try await session.data(for: urlRequest(request))
    return try httpResponse(response, body: data)
  }

  private func makeSession() -> URLSession {
    URLSession(
      configuration: .ephemeral, delegate: WebDAVNoRedirectDelegate.shared, delegateQueue: nil)
  }

  private func urlRequest(_ request: WebDAVHTTPRequest) -> URLRequest {
    var result = URLRequest(url: request.url)
    result.httpMethod = request.method
    result.httpBody = request.body
    for (name, value) in request.headers { result.setValue(value, forHTTPHeaderField: name) }
    return result
  }

  private func httpResponse(_ response: URLResponse, body: Data = Data()) throws
    -> WebDAVHTTPResponse
  {
    guard let response = response as? HTTPURLResponse else {
      throw SDKError(code: .remoteUnavailable, message: "WebDAV response is not HTTP")
    }
    var headers: [String: String] = [:]
    for (name, value) in response.allHeaderFields {
      headers[String(describing: name).lowercased()] = String(describing: value)
    }
    return WebDAVHTTPResponse(statusCode: response.statusCode, headers: headers, body: body)
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
      deltaDeletionsComplete: false,
      preferredDirectoryRequestConcurrency: 4
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
  private var directoryPages: [String: DirectoryPageState] = [:]
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
    let root = RemoteLocator(validatedSourceUID: sourceUID, path: try RemotePath())
    let entry = try await stat(root)
    guard entry.kind == .directory else {
      throw SDKError(code: .invalidConfiguration, message: "WebDAV root is not a collection")
    }
  }

  public func listDirectory(_ request: RemoteDirectoryPageRequest) async throws
    -> CursorPage<RemoteEntry>
  {
    try await listDirectory(
      request,
      options: RemoteDirectoryEnumerationOptions()
    )
  }

  public func listDirectory(
    _ request: RemoteDirectoryPageRequest,
    options: RemoteDirectoryEnumerationOptions
  ) async throws -> CursorPage<RemoteEntry> {
    try requireConnected()
    if let cursor = request.cursor {
      guard let state = directoryPages[cursor], state.directory == request.directory else {
        throw SDKError(code: .conflict, message: "directory cursor expired; restart discovery")
      }
      directoryPages.removeValue(forKey: cursor)
      return try page(state, limit: request.limit)
    }
    let data = try await sendPROPFIND(url: url(for: request.directory), depth: "1")
    let listing = try WebDAVDirectoryListing.parse(
      data, directory: request.directory, baseURL: configuration.baseURL,
      semantics: capabilities.pathSemantics, options: options)
    try requireConnected()
    return try page(
      DirectoryPageState(directory: request.directory, listing: listing, offset: 0),
      limit: request.limit)
  }

  private struct DirectoryPageState {
    let directory: RemoteLocator
    let listing: WebDAVDirectoryListing
    var offset: Int
  }

  private func page(_ state: DirectoryPageState, limit: Int) throws -> CursorPage<RemoteEntry> {
    var state = state
    let end = min(state.offset + limit, state.listing.entries.count)
    let items = Array(state.listing.entries[state.offset..<end])
    state.offset = end
    let cursor = end < state.listing.entries.count ? RemoteDirectorySessionCursor.make() : nil
    if let cursor { directoryPages[cursor] = state }
    return try CursorPage(
      items: items, nextCursor: cursor, isTruncated: state.listing.isTruncated)
  }

  public func stat(_ locator: RemoteLocator) async throws -> RemoteEntry {
    try requireConnected()
    var result: RemoteEntry?
    let xml = try await sendPROPFIND(url: try url(for: locator), depth: "0")
    _ = try WebDAVMultiStatusParser.parse(
      xml, sourceUID: sourceUID, baseURL: configuration.baseURL
    ) { entry in
      if entry.locator == locator { result = entry }
      return true
    }
    guard let result else {
      throw SDKError(code: .metadataNotFound, message: "WebDAV entry was not found")
    }
    return result
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
    directoryPages.removeAll()
    disconnected = true
  }

  private func sendPROPFIND(url: URL, depth: String) async throws -> Data {
    let body = Data(
      """
      <?xml version="1.0" encoding="utf-8" ?>
      <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:getetag/></d:prop></d:propfind>
      """.utf8
    )
    let request = request(
      method: "PROPFIND", url: url,
      headers: ["Depth": depth, "Content-Type": "application/xml; charset=utf-8"], body: body
    )
    let response = try await transport.send(request)
    try validateStatus(response.statusCode, allowsMultiStatus: true, allowsPartialContent: false)
    return response.body
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

/// A bounded, source-order directory result. The XML response itself still arrives in full.
struct WebDAVDirectoryListing: Sendable {
  static let maximumEntryCount = 655_360

  let entries: [RemoteEntry]
  let isTruncated: Bool

  static func parse(
    _ data: Data,
    directory: RemoteLocator,
    baseURL: URL,
    semantics: RemotePathSemantics,
    options: RemoteDirectoryEnumerationOptions,
    maximumEntries: Int = maximumEntryCount
  ) throws -> Self {
    precondition(maximumEntries > 0)
    var entries: [RemoteEntry] = []
    var childCount = 0
    var excluded = false
    let directoryKey = directory.path.comparisonKey(using: semantics)
    let complete = try WebDAVMultiStatusParser.parse(
      data, sourceUID: directory.sourceUID, baseURL: baseURL
    ) { entry in
      // The PROPFIND self response does not consume a child slot, wherever it appears.
      if entry.locator.path.comparisonKey(using: semantics) == directoryKey { return true }
      guard entry.locator.path.parent?.comparisonKey(using: semantics) == directoryKey else {
        throw SDKError(
          code: .parseFailure, message: "WebDAV entry is outside the requested directory")
      }
      // Inspect one extra child to distinguish an exact-size directory from a truncated one.
      // It is never retained, indexed, or traversed; the rest of the XML is ignored.
      guard childCount < maximumEntries else { return false }
      childCount += 1
      if entry.kind == .file,
        options.exclusionMarkerFileNames.contains(where: {
          semantics.caseSensitivity == .insensitive
            ? $0.lowercased() == entry.locator.path.name.lowercased()
            : $0 == entry.locator.path.name
        })
      {
        excluded = true
        entries.removeAll()
      }
      if !excluded { entries.append(entry) }
      return true
    }
    return Self(entries: entries, isTruncated: !excluded && !complete)
  }
}

private enum WebDAVMultiStatusParser {
  static func parse(
    _ data: Data,
    sourceUID: String,
    baseURL: URL,
    onEntry: @escaping (RemoteEntry) throws -> Bool
  ) throws -> Bool {
    let delegate = MultiStatusDelegate(sourceUID: sourceUID, baseURL: baseURL, onEntry: onEntry)
    let parser = XMLParser(data: data)
    parser.shouldResolveExternalEntities = false
    parser.delegate = delegate
    let success = parser.parse()
    if let error = delegate.parsingError { throw error }
    if delegate.stoppedEarly { return false }
    guard success else {
      throw SDKError(code: .parseFailure, message: "WebDAV multistatus XML is invalid")
    }
    return true
  }

  private final class MultiStatusDelegate: NSObject, XMLParserDelegate, @unchecked Sendable {
    private let sourceUID: String
    private let baseURL: URL
    private let baseScheme: String?
    private let baseHost: String?
    private let basePort: Int?
    private let basePathComponents: [String]
    private let httpDateFormatter: DateFormatter
    private var current: ResponseFields?
    private var currentPropstat: PropertyFields?
    private var elementStack: [String] = []
    private var text = ""
    private let onEntry: (RemoteEntry) throws -> Bool
    fileprivate var parsingError: Error?
    fileprivate var stoppedEarly = false

    init(sourceUID: String, baseURL: URL, onEntry: @escaping (RemoteEntry) throws -> Bool) {
      self.onEntry = onEntry
      self.sourceUID = sourceUID
      self.baseURL = baseURL
      baseScheme = baseURL.scheme?.lowercased()
      baseHost = baseURL.host?.lowercased()
      basePort = baseURL.port
      basePathComponents = baseURL.pathComponents
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
      httpDateFormatter = formatter
    }

    func parser(
      _ parser: XMLParser,
      didStartElement elementName: String,
      namespaceURI _: String?,
      qualifiedName _: String?,
      attributes _: [String: String] = [:]
    ) {
      guard !stoppedEarly, parsingError == nil else { return }
      guard elementStack.count < 64 else {
        fail(parser, SDKError(code: .parseFailure, message: "WebDAV XML nesting exceeds the limit"))
        return
      }
      let name = localName(elementName)
      guard !elementStack.isEmpty || name == "multistatus" else {
        fail(
          parser, SDKError(code: .parseFailure, message: "WebDAV response is not multistatus XML"))
        return
      }
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

    func parser(_ parser: XMLParser, foundCharacters string: String) {
      guard !stoppedEarly, parsingError == nil else { return }
      guard text.utf8.count + string.utf8.count <= 1_048_576 else {
        fail(parser, SDKError(code: .parseFailure, message: "WebDAV XML field exceeds the limit"))
        return
      }
      text += string
    }

    private func fail(_ parser: XMLParser, _ error: Error) {
      parsingError = error
      parser.abortParsing()
    }

    func parser(
      _ parser: XMLParser,
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
      guard !stoppedEarly, parsingError == nil else { return }
      switch name {
      case "href" where parentName == "response":
        current?.href = value
      case "getcontentlength":
        currentPropstat?.size = Int64(value)
      case "getlastmodified":
        currentPropstat?.modifiedAtMilliseconds = parseHTTPDate(value)
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
            try Task.checkCancellation()
            if try !onEntry(makeEntry(current)) {
              stoppedEarly = true
              parser.abortParsing()
            }
          } catch {
            fail(parser, error)
          }
        } else {
          fail(
            parser,
            SDKError(
              code: .remoteUnavailable, message: "WebDAV directory response contains a failed entry"
            ))
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
        hrefURL.scheme?.lowercased() == baseScheme,
        hrefURL.host?.lowercased() == baseHost,
        hrefURL.port == basePort
      else {
        throw SDKError(code: .parseFailure, message: "WebDAV href is invalid")
      }
      let hrefComponents = hrefURL.pathComponents
      guard hrefComponents.count >= basePathComponents.count,
        hrefComponents.prefix(basePathComponents.count).elementsEqual(basePathComponents)
      else {
        throw SDKError(code: .forbidden, message: "WebDAV href escaped the configured root")
      }
      let relativeComponents = hrefComponents.dropFirst(basePathComponents.count)
      let path = try RemotePath(relativeComponents.joined(separator: "/"))
      let locator = RemoteLocator(validatedSourceUID: sourceUID, path: path)
      return try RemoteEntry(
        locator: locator,
        kind: fields.isCollection ? .directory : .file,
        size: fields.isCollection ? nil : fields.size,
        modifiedAtMilliseconds: fields.modifiedAtMilliseconds,
        entityTag: fields.entityTag
      )
    }

    private func localName(_ name: String) -> String {
      guard let separator = name.utf8.lastIndex(of: 58) else { return name.lowercased() }
      return name[name.index(after: separator)...].lowercased()
    }

    private func parseHTTPDate(_ value: String) -> Int64? {
      guard !value.isEmpty else { return nil }
      return httpDateFormatter.date(from: value).map {
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

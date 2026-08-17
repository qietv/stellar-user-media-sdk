import Foundation
import StellarCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct OAuthHTTPRequest: Sendable {
  enum Method: String, Sendable {
    case get = "GET"
    case post = "POST"
  }

  let method: Method
  let url: URL
  let headers: [String: String]
  let body: Data?
}

struct OAuthHTTPResponse: Sendable {
  let statusCode: Int
  let headers: [String: String]
  let body: Data

  func header(_ name: String) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }
}

protocol OAuthHTTPTransport: Sendable {
  func send(_ request: OAuthHTTPRequest) async throws -> OAuthHTTPResponse
}

final class URLSessionOAuthHTTPTransport: OAuthHTTPTransport, @unchecked Sendable {
  private let session: URLSession

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 15
    session = URLSession(
      configuration: configuration,
      delegate: OAuthNoRedirectDelegate(),
      delegateQueue: nil
    )
  }

  func send(_ request: OAuthHTTPRequest) async throws -> OAuthHTTPResponse {
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = request.method.rawValue
    urlRequest.httpBody = request.body
    for (name, value) in request.headers {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }
    let (body, response) = try await session.data(for: urlRequest)
    guard let response = response as? HTTPURLResponse else {
      throw SDKError(code: .networkUnavailable, message: "OAuth server response is invalid")
    }
    guard body.count <= GatewayOAuthProtocolClient.maximumResponseBytes else {
      throw SDKError(code: .parseFailure, message: "OAuth server response is too large")
    }
    let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
      guard let name = entry.key as? String, let value = entry.value as? String else { return }
      result[name] = value
    }
    return OAuthHTTPResponse(statusCode: response.statusCode, headers: headers, body: body)
  }
}

private final class OAuthNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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

struct OAuthServerMetadata: Decodable, Equatable, Sendable {
  let issuer: String
  let authorizationEndpoint: String
  let tokenEndpoint: String
  let revocationEndpoint: String
  let scopesSupported: [String]
  let responseTypesSupported: [String]
  let grantTypesSupported: [String]
  let tokenEndpointAuthMethodsSupported: [String]
  let revocationEndpointAuthMethodsSupported: [String]
  let codeChallengeMethodsSupported: [String]

  private enum CodingKeys: String, CodingKey {
    case issuer
    case authorizationEndpoint = "authorization_endpoint"
    case tokenEndpoint = "token_endpoint"
    case revocationEndpoint = "revocation_endpoint"
    case scopesSupported = "scopes_supported"
    case responseTypesSupported = "response_types_supported"
    case grantTypesSupported = "grant_types_supported"
    case tokenEndpointAuthMethodsSupported = "token_endpoint_auth_methods_supported"
    case revocationEndpointAuthMethodsSupported = "revocation_endpoint_auth_methods_supported"
    case codeChallengeMethodsSupported = "code_challenge_methods_supported"
  }
}

struct OAuthTokenBundle: Equatable, Sendable {
  let accessToken: String
  let refreshToken: String
  let scopes: [String]
  let expiresAtMilliseconds: Int64
}

struct OAuthRemoteProfile: Equatable, Sendable {
  let subject: String
  let displayName: String?
  let avatarURL: String?
}

enum OAuthProtocolFailure: Error, Equatable, Sendable {
  case server(code: String, retryAfterMilliseconds: Int64?)
  case invalidResponse
}

struct GatewayOAuthProtocolClient: Sendable {
  static let maximumResponseBytes = 64 << 10

  private let configuration: StellarOAuthConfiguration
  private let transport: any OAuthHTTPTransport
  private let clock: any SDKClock

  init(
    configuration: StellarOAuthConfiguration,
    transport: any OAuthHTTPTransport,
    clock: any SDKClock
  ) {
    self.configuration = configuration
    self.transport = transport
    self.clock = clock
  }

  func discover() async throws -> OAuthServerMetadata {
    let endpoint = configuration.issuer.appendingPathComponent(
      ".well-known/oauth-authorization-server"
    )
    let response = try await transport.send(
      OAuthHTTPRequest(
        method: .get,
        url: endpoint,
        headers: ["Accept": "application/json"],
        body: nil
      )
    )
    guard response.statusCode == 200, isJSON(response.header("Content-Type")) else {
      throw OAuthProtocolFailure.invalidResponse
    }
    let metadata: OAuthServerMetadata = try decodeJSON(response.body)
    try validate(metadata)
    return metadata
  }

  func exchangeAuthorizationCode(
    _ code: String,
    verifier: String,
    metadata: OAuthServerMetadata
  ) async throws -> OAuthTokenBundle {
    try await requestToken(
      metadata: metadata,
      parameters: [
        "grant_type": "authorization_code",
        "code": code,
        "client_id": configuration.clientID,
        "code_verifier": verifier,
      ],
      allowedScopes: configuration.scopes
    )
  }

  func refresh(
    refreshToken: String,
    scopes: [String],
    metadata: OAuthServerMetadata
  ) async throws -> OAuthTokenBundle {
    try await requestToken(
      metadata: metadata,
      parameters: [
        "grant_type": "refresh_token",
        "refresh_token": refreshToken,
        "client_id": configuration.clientID,
      ],
      allowedScopes: scopes
    )
  }

  func profile(accessToken: String) async throws -> OAuthRemoteProfile {
    let response = try await transport.send(
      OAuthHTTPRequest(
        method: .get,
        url: configuration.profileEndpoint,
        headers: [
          "Accept": "application/json",
          "Authorization": "Bearer \(accessToken)",
        ],
        body: nil
      )
    )
    guard response.statusCode == 200, isJSON(response.header("Content-Type")) else {
      if isJSON(response.header("Content-Type")),
        let error = try? decodeJSON(response.body, as: OAuthErrorResponse.self),
        isSafeError(error.error)
      {
        throw OAuthProtocolFailure.server(
          code: error.error,
          retryAfterMilliseconds: retryAfterMilliseconds(response)
        )
      }
      throw OAuthProtocolFailure.invalidResponse
    }
    let payload = try decodeJSON(response.body, as: OAuthProfileResponse.self)
    guard UUID(uuidString: payload.subjectID) != nil,
      payload.nickname.utf8.count <= 1_024,
      payload.avatarURL.map({ $0.utf8.count <= 4_096 && isValidHTTPSURL($0) }) ?? true
    else {
      throw OAuthProtocolFailure.invalidResponse
    }
    return OAuthRemoteProfile(
      subject: payload.subjectID.lowercased(),
      displayName: payload.nickname.isEmpty ? nil : payload.nickname,
      avatarURL: payload.avatarURL
    )
  }

  func revoke(refreshToken: String, metadata: OAuthServerMetadata) async throws {
    let endpoint = try trustedEndpoint(metadata.revocationEndpoint, path: "/oauth/revoke")
    let response = try await transport.send(
      OAuthHTTPRequest(
        method: .post,
        url: endpoint,
        headers: [
          "Accept": "application/json",
          "Content-Type": "application/x-www-form-urlencoded",
        ],
        body: formData([
          "token": refreshToken,
          "token_type_hint": "refresh_token",
          "client_id": configuration.clientID,
        ])
      )
    )
    guard response.statusCode == 200, response.body.isEmpty else {
      if isJSON(response.header("Content-Type")),
        let error = try? decodeJSON(response.body, as: OAuthErrorResponse.self),
        isSafeError(error.error)
      {
        throw OAuthProtocolFailure.server(
          code: error.error,
          retryAfterMilliseconds: retryAfterMilliseconds(response)
        )
      }
      throw OAuthProtocolFailure.invalidResponse
    }
  }

  private func requestToken(
    metadata: OAuthServerMetadata,
    parameters: [String: String],
    allowedScopes: [String]
  ) async throws -> OAuthTokenBundle {
    let endpoint = try trustedEndpoint(metadata.tokenEndpoint, path: "/oauth/token")
    let response = try await transport.send(
      OAuthHTTPRequest(
        method: .post,
        url: endpoint,
        headers: [
          "Accept": "application/json",
          "Content-Type": "application/x-www-form-urlencoded",
        ],
        body: formData(parameters)
      )
    )
    guard isJSON(response.header("Content-Type")) else {
      throw OAuthProtocolFailure.invalidResponse
    }
    guard response.statusCode == 200 else {
      let error = try decodeJSON(response.body, as: OAuthErrorResponse.self)
      guard isSafeError(error.error) else { throw OAuthProtocolFailure.invalidResponse }
      throw OAuthProtocolFailure.server(
        code: error.error,
        retryAfterMilliseconds: retryAfterMilliseconds(response)
      )
    }
    let payload = try decodeJSON(response.body, as: OAuthTokenResponse.self)
    let scopes = try parseScopes(payload.scope)
    let allowed = Set(allowedScopes)
    let now = clock.nowMilliseconds()
    guard
      !payload.accessToken.isEmpty,
      payload.accessToken.utf8.count <= 8_192,
      !payload.refreshToken.isEmpty,
      payload.refreshToken.utf8.count <= 8_192,
      payload.tokenType == "Bearer",
      (1...900).contains(payload.expiresIn),
      !scopes.isEmpty,
      Set(scopes).isSubset(of: allowed),
      now >= 0,
      payload.expiresIn <= (Int64.max - now) / 1_000
    else {
      throw OAuthProtocolFailure.invalidResponse
    }
    return OAuthTokenBundle(
      accessToken: payload.accessToken,
      refreshToken: payload.refreshToken,
      scopes: scopes,
      expiresAtMilliseconds: now + payload.expiresIn * 1_000
    )
  }

  private func validate(_ metadata: OAuthServerMetadata) throws {
    let issuer = configuration.issuer.absoluteString
    guard
      metadata.issuer == issuer,
      metadata.authorizationEndpoint == issuer + "oauth/authorize",
      metadata.tokenEndpoint == issuer + "oauth/token",
      metadata.revocationEndpoint == issuer + "oauth/revoke",
      hasUniqueValues(metadata.scopesSupported),
      metadata.scopesSupported.allSatisfy(UserSession.isValidScope),
      hasUniqueValues(metadata.responseTypesSupported),
      hasUniqueValues(metadata.grantTypesSupported),
      hasUniqueValues(metadata.tokenEndpointAuthMethodsSupported),
      hasUniqueValues(metadata.revocationEndpointAuthMethodsSupported),
      hasUniqueValues(metadata.codeChallengeMethodsSupported),
      Set(configuration.scopes).isSubset(of: Set(metadata.scopesSupported)),
      metadata.responseTypesSupported.contains("code"),
      metadata.grantTypesSupported.contains("authorization_code"),
      metadata.grantTypesSupported.contains("refresh_token"),
      metadata.tokenEndpointAuthMethodsSupported.contains("none"),
      metadata.revocationEndpointAuthMethodsSupported.contains("none"),
      metadata.codeChallengeMethodsSupported.contains("S256")
    else {
      throw OAuthProtocolFailure.invalidResponse
    }
  }

  private func hasUniqueValues(_ values: [String]) -> Bool {
    !values.isEmpty && values.count == Set(values).count
  }

  private func trustedEndpoint(_ value: String, path: String) throws -> URL {
    guard value == configuration.issuer.absoluteString.dropLast() + path,
      let endpoint = URL(string: value)
    else {
      throw OAuthProtocolFailure.invalidResponse
    }
    return endpoint
  }

  private func parseScopes(_ value: String) throws -> [String] {
    guard value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
      throw OAuthProtocolFailure.invalidResponse
    }
    let scopes = value.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    guard scopes.allSatisfy(UserSession.isValidScope), scopes.count == Set(scopes).count else {
      throw OAuthProtocolFailure.invalidResponse
    }
    return scopes.sorted()
  }

  private func formData(_ parameters: [String: String]) -> Data {
    let encoded = parameters.keys.sorted().map { key in
      "\(formEncode(key))=\(formEncode(parameters[key]!))"
    }.joined(separator: "&")
    return Data(encoded.utf8)
  }

  private func formEncode(_ value: String) -> String {
    value.utf8.map { byte -> String in
      if (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
        || (0x30...0x39).contains(byte) || [0x2D, 0x2E, 0x5F, 0x7E].contains(byte)
      {
        return String(UnicodeScalar(byte))
      }
      if byte == 0x20 { return "+" }
      return String(format: "%%%02X", byte)
    }.joined()
  }

  private func decodeJSON<Value: Decodable>(_ data: Data, as _: Value.Type = Value.self) throws
    -> Value
  {
    guard data.count <= Self.maximumResponseBytes else {
      throw OAuthProtocolFailure.invalidResponse
    }
    do {
      return try JSONDecoder().decode(Value.self, from: data)
    } catch {
      throw OAuthProtocolFailure.invalidResponse
    }
  }

  private func isJSON(_ value: String?) -> Bool {
    guard let value else { return false }
    return value.lowercased().split(separator: ";", maxSplits: 1).first?
      .trimmingCharacters(in: .whitespaces) == "application/json"
  }

  private func isValidHTTPSURL(_ value: String) -> Bool {
    guard let components = URLComponents(string: value) else { return false }
    return components.scheme == "https" && components.host != nil && components.user == nil
      && components.password == nil
  }

  private func isSafeError(_ value: String) -> Bool {
    guard (1...64).contains(value.utf8.count) else { return false }
    return value.utf8.allSatisfy { byte in
      (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte) || byte == 0x5F
    }
  }

  private func retryAfterMilliseconds(_ response: OAuthHTTPResponse) -> Int64? {
    guard let value = response.header("Retry-After"), let seconds = Int64(value),
      (0...86_400).contains(seconds)
    else { return nil }
    return seconds * 1_000
  }
}

private struct OAuthTokenResponse: Decodable {
  let accessToken: String
  let tokenType: String
  let expiresIn: Int64
  let refreshToken: String
  let scope: String

  private enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case tokenType = "token_type"
    case expiresIn = "expires_in"
    case refreshToken = "refresh_token"
    case scope
  }
}

private struct OAuthErrorResponse: Decodable {
  let error: String
}

private struct OAuthProfileResponse: Decodable {
  let subjectID: String
  let nickname: String
  let avatarURL: String?

  private enum CodingKeys: String, CodingKey {
    case subjectID = "subject_id"
    case nickname
    case avatarURL = "avatar_url"
  }
}

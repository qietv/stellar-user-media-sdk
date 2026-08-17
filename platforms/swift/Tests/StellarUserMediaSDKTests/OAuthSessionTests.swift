import Foundation
import StellarCore
import Testing

@testable import StellarAuth

#if canImport(Security)
  import Security
#endif

@Suite("Stellar OAuth session")
struct OAuthSessionTests {
  #if canImport(Security)
    @Test("Keychain data results accept single and multi-item Security shapes")
    func keychainDataResultShapes() throws {
      let first = Data([0x01, 0x02])
      let second = Data([0x03])

      #expect(oauthKeychainDataValues(from: first) == [first])
      #expect(oauthKeychainDataValues(from: [first, second]) == [first, second])
      #expect(
        oauthKeychainDataValues(from: [
          [kSecValueData as String: first],
          [kSecValueData as String: second],
        ]) == [first, second]
      )
      #expect(oauthKeychainDataValues(from: [kSecValueData as String: first]) == [first])
      #expect(oauthKeychainDataValues(from: ["unexpected": first]) == nil)
    }
  #endif

  @Test("PKCE uses the RFC 7636 S256 vector and emits the Gateway request shape")
  func pkceRequest() throws {
    let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    let verifierBytes = try #require(base64URLDecode(verifier))
    let random = SequenceRandomGenerator(values: [Array(repeating: 0xA5, count: 32), verifierBytes])
    let configuration = try makeConfiguration()
    let attempt = try OAuthAuthorizationBuilder.makeAttempt(
      endpoint: URL(string: "https://dev-gateway.2dland.cn/oauth/authorize")!,
      configuration: configuration,
      random: random
    )
    let query = queryValues(attempt.presentationRequest.authorizationURL)

    #expect(attempt.verifier == verifier)
    #expect(attempt.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    #expect(query["response_type"] == ["code"])
    #expect(query["client_id"] == ["stellarplayer-desktop"])
    #expect(query["redirect_uri"] == [configuration.redirectURI.absoluteString])
    #expect(query["scope"] == ["profile.read"])
    #expect(query["state"] == [attempt.state])
    #expect(query["code_challenge"] == [attempt.challenge])
    #expect(query["code_challenge_method"] == ["S256"])
  }

  @Test("Callback validation rejects wrong state, duplicate fields, and unknown parameters")
  func callbackValidation() throws {
    let redirect = URL(string: "http://127.0.0.1:49152/oauth/callback")!
    let invalidCallbacks = [
      "http://127.0.0.1:49152/oauth/callback?code=fixture&state=wrong",
      "http://127.0.0.1:49152/oauth/callback?code=one&code=two&state=expected",
      "http://127.0.0.1:49152/oauth/callback?code=fixture&state=expected&token=leak",
      "http://127.0.0.1:49153/oauth/callback?code=fixture&state=expected",
    ]
    for value in invalidCallbacks {
      do {
        _ = try OAuthAuthorizationBuilder.authorizationCode(
          from: URL(string: value)!,
          redirectURI: redirect,
          expectedState: "expected"
        )
        Issue.record("Expected OAuth callback rejection")
      } catch let error as SDKError {
        #expect(error.code == .unauthorized)
      }
    }
  }

  @Test("Gateway fixture drives login without placing redirect URI in token exchange")
  @MainActor
  func loginAgainstGatewayContract() async throws {
    let fixture = try loadFixture()
    let configuration = try makeConfiguration()
    let transport = ScriptedOAuthTransport(fixture: fixture, initialExpiresIn: 600)
    let presenter = FixtureAuthorizationPresenter()
    let store = InMemoryOAuthCredentialStore()
    let manager = makeManager(
      configuration: configuration,
      presenter: presenter,
      transport: transport,
      store: store
    )

    let session = try await manager.signIn()

    #expect(session.accountUID == fixture.profile.subjectID)
    #expect(session.displayName == fixture.profile.nickname)
    #expect(session.scopes == ["profile.read"])
    #expect(await manager.state == .signedIn(session))
    #expect(try await manager.listAccounts() == [session])
    let form = await transport.authorizationCodeForm()
    #expect(form?["grant_type"] == "authorization_code")
    #expect(form?["client_id"] == "stellarplayer-desktop")
    #expect(form?["code"] == fixture.authorizationCallback.code)
    #expect(form?["code_verifier"]?.isEmpty == false)
    #expect(form?["redirect_uri"] == nil)
    #expect(form?["client_secret"] == nil)
  }

  @Test("Concurrent access token requests share one rotating refresh")
  @MainActor
  func refreshIsSingleFlight() async throws {
    let fixture = try loadFixture()
    let configuration = try makeConfiguration()
    let transport = ScriptedOAuthTransport(
      fixture: fixture,
      initialExpiresIn: 1,
      refreshDelayMilliseconds: 50
    )
    let manager = makeManager(
      configuration: configuration,
      presenter: FixtureAuthorizationPresenter(),
      transport: transport,
      store: InMemoryOAuthCredentialStore()
    )
    _ = try await manager.signIn()

    let tokens = try await withThrowingTaskGroup(of: String.self) { group in
      for _ in 0..<20 {
        group.addTask {
          try await manager.getAccessToken(minValidityMilliseconds: 60_000)
        }
      }
      var values: [String] = []
      for try await token in group { values.append(token) }
      return values
    }

    #expect(tokens.count == 20)
    #expect(Set(tokens) == ["fixture-access-token-rotated"])
    #expect(await transport.refreshRequestCount() == 1)
  }

  @Test("Profile refresh preserves the refresh token returned by rotation")
  @MainActor
  func profileRefreshPreservesRotatedCredential() async throws {
    let fixture = try loadFixture()
    let configuration = try makeConfiguration()
    let transport = ScriptedOAuthTransport(fixture: fixture, initialExpiresIn: 1)
    let store = InMemoryOAuthCredentialStore()
    let manager = makeManager(
      configuration: configuration,
      presenter: FixtureAuthorizationPresenter(),
      transport: transport,
      store: store
    )
    _ = try await manager.signIn()

    _ = try await manager.refreshProfile()

    let stored = await store.credentials()
    #expect(stored.count == 1)
    #expect(stored.first?.refreshToken == "fixture-refresh-token-rotated")
    #expect(await transport.refreshRequestCount() == 1)
  }

  @Test("Invalid refresh grant enters needs reauthentication without retrying")
  @MainActor
  func invalidGrantNeedsReauthentication() async throws {
    let fixture = try loadFixture()
    let configuration = try makeConfiguration()
    let clock = FixedOAuthClock(now: 1_700_000_000_000)
    let session = try UserSession(
      accountUID: fixture.profile.subjectID,
      subject: fixture.profile.subjectID,
      issuer: configuration.issuer.absoluteString,
      displayName: fixture.profile.nickname,
      avatarURL: fixture.profile.avatarURL,
      scopes: ["profile.read"],
      accessExpiresAtMilliseconds: clock.now
    )
    let credential = try StoredOAuthCredential(
      configuration: configuration,
      session: session,
      refreshToken: "fixture-expired-refresh-token"
    )
    let store = InMemoryOAuthCredentialStore()
    await store.save(credential)
    await store.setActiveAccountUID(session.accountUID)
    let transport = ScriptedOAuthTransport(fixture: fixture, refreshReturnsInvalidGrant: true)
    let manager = makeManager(
      configuration: configuration,
      presenter: FixtureAuthorizationPresenter(),
      transport: transport,
      store: store,
      clock: clock
    )

    do {
      _ = try await manager.restoreSession()
      Issue.record("Expected invalid refresh grant")
    } catch let error as SDKError {
      #expect(error.code == .unauthorized)
    }

    #expect(await manager.state == .needsReauthentication(session))
    #expect(await transport.refreshRequestCount() == 1)
  }

  @Test("A rotated token that cannot be persisted fails closed into reauthentication")
  @MainActor
  func rotatedTokenStorageFailureNeedsReauthentication() async throws {
    let fixture = try loadFixture()
    let configuration = try makeConfiguration()
    let clock = FixedOAuthClock(now: 1_700_000_000_000)
    let session = try UserSession(
      accountUID: fixture.profile.subjectID,
      subject: fixture.profile.subjectID,
      issuer: configuration.issuer.absoluteString,
      displayName: fixture.profile.nickname,
      avatarURL: fixture.profile.avatarURL,
      scopes: ["profile.read"],
      accessExpiresAtMilliseconds: clock.now
    )
    let credential = try StoredOAuthCredential(
      configuration: configuration,
      session: session,
      refreshToken: "fixture-refresh-token"
    )
    let transport = ScriptedOAuthTransport(fixture: fixture)
    let manager = OAuthSessionManager(
      configuration: configuration,
      authorizationPresenter: FixtureAuthorizationPresenter(),
      transport: transport,
      credentialStore: FailingRefreshSaveStore(credential: credential),
      random: SequenceRandomGenerator(values: []),
      clock: clock,
      uuidGenerator: SystemSDKUUIDGenerator()
    )

    do {
      _ = try await manager.restoreSession()
      Issue.record("Expected secure storage failure")
    } catch let error as SDKError {
      #expect(error.code == .storageFailure)
    }

    #expect(await manager.state == .needsReauthentication(session))
    #expect(await transport.refreshRequestCount() == 1)
  }

  @Test("Signing out an inactive account does not cancel active account restoration")
  @MainActor
  func inactiveLogoutDoesNotCancelRestore() async throws {
    let fixture = try loadFixture()
    let configuration = try makeConfiguration()
    let clock = FixedOAuthClock(now: 1_700_000_000_000)
    let activeSession = try UserSession(
      accountUID: fixture.profile.subjectID,
      subject: fixture.profile.subjectID,
      issuer: configuration.issuer.absoluteString,
      displayName: fixture.profile.nickname,
      avatarURL: fixture.profile.avatarURL,
      scopes: ["profile.read"],
      accessExpiresAtMilliseconds: clock.now
    )
    let inactiveUID = "1555b85f-7bb8-4406-9e2e-c32555209451"
    let inactiveSession = try UserSession(
      accountUID: inactiveUID,
      subject: inactiveUID,
      issuer: configuration.issuer.absoluteString,
      displayName: "Inactive User",
      avatarURL: nil,
      scopes: ["profile.read"],
      accessExpiresAtMilliseconds: clock.now
    )
    let store = InMemoryOAuthCredentialStore()
    await store.save(
      try StoredOAuthCredential(
        configuration: configuration,
        session: activeSession,
        refreshToken: "fixture-active-refresh-token"
      )
    )
    await store.save(
      try StoredOAuthCredential(
        configuration: configuration,
        session: inactiveSession,
        refreshToken: "fixture-inactive-refresh-token"
      )
    )
    await store.setActiveAccountUID(activeSession.accountUID)
    let transport = ScriptedOAuthTransport(
      fixture: fixture,
      refreshDelayMilliseconds: 50
    )
    let manager = makeManager(
      configuration: configuration,
      presenter: FixtureAuthorizationPresenter(),
      transport: transport,
      store: store,
      clock: clock
    )

    let restoration = Task { try await manager.restoreSession() }
    for _ in 0..<1_000 {
      if await transport.refreshRequestCount() > 0 { break }
      await Task.yield()
    }
    #expect(await transport.refreshRequestCount() == 1)
    try await manager.signOut(accountUID: inactiveUID, revokeRemote: false)
    let restored = try await restoration.value

    #expect(restored?.accountUID == activeSession.accountUID)
    #expect(await manager.state.session?.accountUID == activeSession.accountUID)
    #expect(try await manager.listAccounts().map(\.accountUID) == [activeSession.accountUID])
  }

  @Test("Active logout cancels an in-flight rotation without resurrecting credentials")
  @MainActor
  func activeLogoutWinsRefreshRace() async throws {
    let fixture = try loadFixture()
    let configuration = try makeConfiguration()
    let transport = ScriptedOAuthTransport(
      fixture: fixture,
      initialExpiresIn: 1,
      refreshDelayMilliseconds: 50
    )
    let store = InMemoryOAuthCredentialStore()
    let manager = makeManager(
      configuration: configuration,
      presenter: FixtureAuthorizationPresenter(),
      transport: transport,
      store: store
    )
    let session = try await manager.signIn()

    let tokenRequest = Task {
      try await manager.getAccessToken(minValidityMilliseconds: 60_000)
    }
    for _ in 0..<1_000 {
      if await transport.refreshRequestCount() > 0 { break }
      await Task.yield()
    }
    #expect(await transport.refreshRequestCount() == 1)
    try await manager.signOut(accountUID: session.accountUID, revokeRemote: false)
    do {
      _ = try await tokenRequest.value
      Issue.record("Expected the in-flight token request to be cancelled")
    } catch let error as SDKError {
      #expect(error.code == .cancelled)
    }

    #expect(await manager.state == .signedOut)
    #expect(try await manager.listAccounts().isEmpty)
  }

  @Test("Remote revocation failure never blocks local logout")
  @MainActor
  func logoutIsLocalFirst() async throws {
    let fixture = try loadFixture()
    let configuration = try makeConfiguration()
    let transport = ScriptedOAuthTransport(fixture: fixture, revocationFails: true)
    let store = InMemoryOAuthCredentialStore()
    let manager = makeManager(
      configuration: configuration,
      presenter: FixtureAuthorizationPresenter(),
      transport: transport,
      store: store
    )
    let session = try await manager.signIn()

    try await manager.signOut(accountUID: session.accountUID, revokeRemote: true)

    #expect(await manager.state == .signedOut)
    #expect(try await manager.listAccounts().isEmpty)
    #expect(await transport.revocationRequestCount() == 1)
  }

  private func makeManager(
    configuration: StellarOAuthConfiguration,
    presenter: FixtureAuthorizationPresenter,
    transport: ScriptedOAuthTransport,
    store: InMemoryOAuthCredentialStore,
    clock: FixedOAuthClock = FixedOAuthClock(now: 1_700_000_000_000)
  ) -> OAuthSessionManager {
    OAuthSessionManager(
      configuration: configuration,
      authorizationPresenter: presenter,
      transport: transport,
      credentialStore: store,
      random: SequenceRandomGenerator(values: [
        Array(repeating: 0x11, count: 32),
        Array(repeating: 0x22, count: 32),
      ]),
      clock: clock,
      uuidGenerator: SystemSDKUUIDGenerator()
    )
  }

  private func makeConfiguration() throws -> StellarOAuthConfiguration {
    try .developmentGatewayDesktop(
      redirectURI: URL(string: "http://127.0.0.1:49152/oauth/callback")!
    )
  }

  private func loadFixture() throws -> GatewayOAuthFixture {
    let fixtureURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("specs/fixtures/auth/gateway-oauth-v1.json")
    return try JSONDecoder().decode(
      GatewayOAuthFixture.self,
      from: Data(contentsOf: fixtureURL)
    )
  }
}

private struct GatewayOAuthFixture: Decodable, Sendable {
  struct Callback: Decodable, Sendable {
    let code: String
    let redirectURI: String

    private enum CodingKeys: String, CodingKey {
      case code
      case redirectURI = "redirect_uri"
    }
  }

  struct Profile: Decodable, Sendable {
    let subjectID: String
    let nickname: String
    let avatarURL: String?

    private enum CodingKeys: String, CodingKey {
      case subjectID = "subject_id"
      case nickname
      case avatarURL = "avatar_url"
    }
  }

  struct Token: Decodable, Sendable {
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

  let schemaVersion: Int
  let metadata: OAuthServerMetadata
  let authorizationCallback: Callback
  let profile: Profile
  let token: Token

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case metadata
    case authorizationCallback = "authorization_callback"
    case profile
    case token
  }
}

@MainActor
private final class FixtureAuthorizationPresenter: OAuthAuthorizationPresenting {
  private(set) var request: OAuthAuthorizationPresentationRequest?

  func authorize(_ request: OAuthAuthorizationPresentationRequest) async throws -> URL {
    self.request = request
    let state = try #require(queryValues(request.authorizationURL)["state"]?.first)
    var callback = URLComponents(url: request.redirectURI, resolvingAgainstBaseURL: false)
    callback?.queryItems = [
      URLQueryItem(name: "code", value: "fixture-authorization-code"),
      URLQueryItem(name: "state", value: state),
    ]
    return try #require(callback?.url)
  }
}

private actor ScriptedOAuthTransport: OAuthHTTPTransport {
  private let fixture: GatewayOAuthFixture
  private let metadataData: Data
  private let initialExpiresIn: Int64
  private let refreshDelayMilliseconds: Int64
  private let refreshReturnsInvalidGrant: Bool
  private let revocationFails: Bool
  private var authorizationForm: [String: String]?
  private var refreshCount = 0
  private var revocationCount = 0

  init(
    fixture: GatewayOAuthFixture,
    initialExpiresIn: Int64 = 600,
    refreshDelayMilliseconds: Int64 = 0,
    refreshReturnsInvalidGrant: Bool = false,
    revocationFails: Bool = false
  ) {
    self.fixture = fixture
    self.initialExpiresIn = initialExpiresIn
    self.refreshDelayMilliseconds = refreshDelayMilliseconds
    self.refreshReturnsInvalidGrant = refreshReturnsInvalidGrant
    self.revocationFails = revocationFails
    metadataData =
      (try? JSONSerialization.data(
        withJSONObject: [
          "issuer": fixture.metadata.issuer,
          "authorization_endpoint": fixture.metadata.authorizationEndpoint,
          "token_endpoint": fixture.metadata.tokenEndpoint,
          "revocation_endpoint": fixture.metadata.revocationEndpoint,
          "scopes_supported": fixture.metadata.scopesSupported,
          "response_types_supported": fixture.metadata.responseTypesSupported,
          "grant_types_supported": fixture.metadata.grantTypesSupported,
          "token_endpoint_auth_methods_supported": fixture.metadata
            .tokenEndpointAuthMethodsSupported,
          "revocation_endpoint_auth_methods_supported": fixture.metadata
            .revocationEndpointAuthMethodsSupported,
          "code_challenge_methods_supported": fixture.metadata.codeChallengeMethodsSupported,
        ], options: [.sortedKeys])) ?? Data()
  }

  func send(_ request: OAuthHTTPRequest) async throws -> OAuthHTTPResponse {
    switch (request.method, request.url.path) {
    case (.get, "/.well-known/oauth-authorization-server"):
      return jsonResponse(status: 200, data: metadataData)
    case (.post, "/oauth/token"):
      let form = parseForm(request.body)
      switch form["grant_type"] {
      case "authorization_code":
        authorizationForm = form
        return tokenResponse(
          accessToken: fixture.token.accessToken,
          refreshToken: fixture.token.refreshToken,
          expiresIn: initialExpiresIn
        )
      case "refresh_token":
        refreshCount += 1
        if refreshDelayMilliseconds > 0 {
          try await Task<Never, Never>.sleep(
            for: .milliseconds(refreshDelayMilliseconds)
          )
        }
        if refreshReturnsInvalidGrant {
          return jsonResponse(status: 400, json: ["error": "invalid_grant"])
        }
        return tokenResponse(
          accessToken: "fixture-access-token-rotated",
          refreshToken: "fixture-refresh-token-rotated",
          expiresIn: 600
        )
      default:
        return jsonResponse(status: 400, json: ["error": "invalid_request"])
      }
    case (.get, "/api/v1/me"):
      guard request.headers["Authorization"]?.hasPrefix("Bearer ") == true else {
        return jsonResponse(status: 401, json: ["error": "invalid_token"])
      }
      return jsonResponse(
        status: 200,
        json: [
          "subject_id": fixture.profile.subjectID,
          "nickname": fixture.profile.nickname,
          "avatar_url": fixture.profile.avatarURL as Any,
        ])
    case (.post, "/oauth/revoke"):
      revocationCount += 1
      if revocationFails {
        return jsonResponse(status: 500, json: ["error": "server_error"])
      }
      return OAuthHTTPResponse(statusCode: 200, headers: [:], body: Data())
    default:
      return jsonResponse(status: 404, json: ["error": "not_found"])
    }
  }

  func authorizationCodeForm() -> [String: String]? { authorizationForm }
  func refreshRequestCount() -> Int { refreshCount }
  func revocationRequestCount() -> Int { revocationCount }

  private func tokenResponse(
    accessToken: String,
    refreshToken: String,
    expiresIn: Int64
  ) -> OAuthHTTPResponse {
    jsonResponse(
      status: 200,
      json: [
        "access_token": accessToken,
        "token_type": fixture.token.tokenType,
        "expires_in": expiresIn,
        "refresh_token": refreshToken,
        "scope": fixture.token.scope,
      ])
  }

  private func jsonResponse(status: Int, json: [String: Any]) -> OAuthHTTPResponse {
    jsonResponse(
      status: status,
      data: (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    )
  }

  private func jsonResponse(status: Int, data: Data) -> OAuthHTTPResponse {
    OAuthHTTPResponse(
      statusCode: status,
      headers: ["Content-Type": "application/json; charset=utf-8"],
      body: data
    )
  }

  private func parseForm(_ data: Data?) -> [String: String] {
    guard let data, let value = String(data: data, encoding: .utf8),
      let components = URLComponents(string: "https://fixture.invalid/?\(value)")
    else { return [:] }
    return Dictionary(
      uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
        item.value.map { (item.name, $0) }
      })
  }
}

private final class SequenceRandomGenerator: OAuthRandomGenerating, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [[UInt8]]

  init(values: [[UInt8]]) {
    self.values = values
  }

  func randomBytes(count: Int) throws -> [UInt8] {
    lock.lock()
    defer { lock.unlock() }
    guard !values.isEmpty, values[0].count == count else {
      throw SDKError(code: .unknown, message: "fixture random input is unavailable")
    }
    return values.removeFirst()
  }
}

private actor FailingRefreshSaveStore: OAuthCredentialStoring {
  private let credential: StoredOAuthCredential

  init(credential: StoredOAuthCredential) {
    self.credential = credential
  }

  func credentials() -> [StoredOAuthCredential] { [credential] }
  func activeAccountUID() -> String? { credential.session.accountUID }

  func save(_: StoredOAuthCredential) throws {
    throw SDKError(code: .storageFailure, message: "fixture secure storage failure")
  }

  func remove(accountUID _: String) {}
  func setActiveAccountUID(_: String?) {}
}

private struct FixedOAuthClock: SDKClock {
  let now: Int64

  func nowMilliseconds() -> Int64 { now }
  func sleep(forMilliseconds _: Int64) async throws {}
}

private func queryValues(_ url: URL) -> [String: [String]] {
  Dictionary(
    grouping: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [], by: \.name
  )
  .mapValues { $0.compactMap(\.value) }
}

private func base64URLDecode(_ value: String) -> [UInt8]? {
  var encoded = value.replacingOccurrences(of: "-", with: "+")
    .replacingOccurrences(of: "_", with: "/")
  encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
  return Data(base64Encoded: encoded).map(Array.init)
}

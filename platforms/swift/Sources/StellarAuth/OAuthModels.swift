import Foundation
import StellarCore

/// The stable public states emitted by the Stellar OAuth session coordinator.
public enum OAuthSessionState: Equatable, Sendable {
  case signedOut
  case authorizing
  case signedIn(UserSession)
  case refreshing(UserSession)
  case needsReauthentication(UserSession)
  case signingOut(UserSession)

  /// Cross-platform wire value defined by the OAuth session contract.
  public var rawValue: String {
    switch self {
    case .signedOut: "signed_out"
    case .authorizing: "authorizing"
    case .signedIn: "signed_in"
    case .refreshing: "refreshing"
    case .needsReauthentication: "needs_reauth"
    case .signingOut: "signing_out"
    }
  }

  /// The account represented by this state, if one is known.
  public var session: UserSession? {
    switch self {
    case .signedIn(let session), .refreshing(let session),
      .needsReauthentication(let session), .signingOut(let session):
      session
    case .signedOut, .authorizing:
      nil
    }
  }
}

/// Non-secret account and OAuth grant information exposed to client applications.
public struct UserSession: Codable, Equatable, Sendable {
  public let accountUID: String
  public let subject: String
  public let issuer: String
  public let displayName: String?
  public let avatarURL: String?
  public let scopes: [String]
  public let accessExpiresAtMilliseconds: Int64
  public let profileRevision: String?
  public let schemaVersion: Int

  public init(
    accountUID: String,
    subject: String,
    issuer: String,
    displayName: String?,
    avatarURL: String?,
    scopes: [String],
    accessExpiresAtMilliseconds: Int64,
    profileRevision: String? = nil,
    schemaVersion: Int = 1
  ) throws {
    guard
      UUID(uuidString: accountUID) != nil,
      UUID(uuidString: subject) != nil,
      Self.isValidIssuer(issuer),
      !scopes.isEmpty,
      scopes == Array(Set(scopes)).sorted(),
      scopes.allSatisfy(Self.isValidScope),
      accessExpiresAtMilliseconds >= 0,
      displayName.map({ !$0.isEmpty && $0.utf8.count <= 1_024 }) ?? true,
      avatarURL.map({ $0.utf8.count <= 4_096 && Self.isValidAvatarURL($0) }) ?? true,
      profileRevision.map({ !$0.isEmpty && $0.utf8.count <= 1_024 }) ?? true,
      schemaVersion == 1
    else {
      throw SDKError(
        code: .invalidConfiguration,
        message: "OAuth user session is invalid"
      )
    }
    self.accountUID = accountUID.lowercased()
    self.subject = subject.lowercased()
    self.issuer = issuer
    self.displayName = displayName
    self.avatarURL = avatarURL
    self.scopes = scopes
    self.accessExpiresAtMilliseconds = accessExpiresAtMilliseconds
    self.profileRevision = profileRevision
    self.schemaVersion = schemaVersion
  }

  private enum CodingKeys: String, CodingKey {
    case accountUID = "account_uid"
    case subject
    case issuer
    case displayName = "display_name"
    case avatarURL = "avatar_url"
    case scopes
    case accessExpiresAtMilliseconds = "access_expires_at_ms"
    case profileRevision = "profile_revision"
    case schemaVersion = "schema_version"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      accountUID: container.decode(String.self, forKey: .accountUID),
      subject: container.decode(String.self, forKey: .subject),
      issuer: container.decode(String.self, forKey: .issuer),
      displayName: container.decodeIfPresent(String.self, forKey: .displayName),
      avatarURL: container.decodeIfPresent(String.self, forKey: .avatarURL),
      scopes: container.decode([String].self, forKey: .scopes),
      accessExpiresAtMilliseconds: container.decode(
        Int64.self,
        forKey: .accessExpiresAtMilliseconds
      ),
      profileRevision: container.decodeIfPresent(String.self, forKey: .profileRevision),
      schemaVersion: container.decode(Int.self, forKey: .schemaVersion)
    )
  }

  private static func isValidIssuer(_ value: String) -> Bool {
    guard let components = URLComponents(string: value) else { return false }
    return components.scheme == "https" && components.host != nil && components.path == "/"
      && components.user == nil && components.password == nil && components.query == nil
      && components.fragment == nil && value.hasSuffix("/")
  }

  static func isValidScope(_ value: String) -> Bool {
    guard !value.isEmpty else { return false }
    return value.utf8.allSatisfy { byte in
      byte == 0x21 || (0x23...0x5B).contains(byte) || (0x5D...0x7E).contains(byte)
    }
  }

  private static func isValidAvatarURL(_ value: String) -> Bool {
    guard let components = URLComponents(string: value) else { return false }
    return components.scheme == "https" && components.host != nil && components.user == nil
      && components.password == nil
  }
}

/// Observable OAuth and account events. Events never contain protocol credentials.
public struct OAuthSessionEvent: Equatable, Sendable {
  public enum Kind: String, Equatable, Sendable {
    case sessionStateChanged = "session_state_changed"
    case activeAccountChanged = "active_account_changed"
    case profileChanged = "profile_changed"
    case reauthenticationRequired = "reauthentication_required"
    case signedOut = "signed_out"
  }

  public let kind: Kind
  public let accountUID: String?
  public let occurredAtMilliseconds: Int64
  public let traceID: String

  public init(
    kind: Kind,
    accountUID: String?,
    occurredAtMilliseconds: Int64,
    traceID: String
  ) throws {
    guard accountUID.map({ UUID(uuidString: $0) != nil }) ?? true,
      occurredAtMilliseconds >= 0,
      UUID(uuidString: traceID) != nil
    else {
      throw SDKError(code: .invalidConfiguration, message: "OAuth session event is invalid")
    }
    self.kind = kind
    self.accountUID = accountUID?.lowercased()
    self.occurredAtMilliseconds = occurredAtMilliseconds
    self.traceID = traceID.lowercased()
  }
}

/// Fixed protocol and resource endpoints for one trusted Stellar OAuth deployment.
public struct StellarOAuthConfiguration: Equatable, Sendable {
  public let issuer: URL
  public let clientID: String
  public let redirectURI: URL
  public let scopes: [String]
  public let profileEndpoint: URL
  public let refreshLeewayMilliseconds: Int64

  public init(
    issuer: URL,
    clientID: String,
    redirectURI: URL,
    scopes: [String],
    profileEndpoint: URL,
    refreshLeewayMilliseconds: Int64 = 120_000
  ) throws {
    let normalizedScopes = Array(Set(scopes)).sorted()
    guard
      Self.isHTTPSRoot(issuer),
      Self.isValidClientID(clientID),
      Self.isValidRedirectURI(redirectURI),
      !normalizedScopes.isEmpty,
      normalizedScopes.count == scopes.count,
      normalizedScopes.allSatisfy(UserSession.isValidScope),
      Self.isValidProfileEndpoint(profileEndpoint),
      (0...300_000).contains(refreshLeewayMilliseconds)
    else {
      throw SDKError(code: .invalidConfiguration, message: "OAuth configuration is invalid")
    }
    self.issuer = issuer
    self.clientID = clientID
    self.redirectURI = redirectURI
    self.scopes = normalizedScopes
    self.profileEndpoint = profileEndpoint
    self.refreshLeewayMilliseconds = refreshLeewayMilliseconds
  }

  /// The currently deployed Gateway profile for the registered desktop public client.
  public static func developmentGatewayDesktop(
    redirectURI: URL,
    scopes: [String] = ["profile.read"]
  ) throws -> StellarOAuthConfiguration {
    guard Self.isDevelopmentDesktopRedirect(redirectURI) else {
      throw SDKError(
        code: .invalidConfiguration,
        message: "Gateway desktop redirect URI must use a dynamic IPv4 loopback port"
      )
    }
    return try StellarOAuthConfiguration(
      issuer: URL(string: "https://dev-gateway.2dland.cn/")!,
      clientID: "stellarplayer-desktop",
      redirectURI: redirectURI,
      scopes: scopes,
      profileEndpoint: URL(string: "https://dev-user-stellarplayer.2dland.cn/api/v1/me")!
    )
  }

  private static func isHTTPSRoot(_ value: URL) -> Bool {
    guard let components = URLComponents(url: value, resolvingAgainstBaseURL: false) else {
      return false
    }
    return components.scheme == "https" && components.host != nil && components.path == "/"
      && components.user == nil && components.password == nil && components.query == nil
      && components.fragment == nil && value.absoluteString.hasSuffix("/")
  }

  private static func isValidClientID(_ value: String) -> Bool {
    guard (1...128).contains(value.utf8.count) else { return false }
    return value.utf8.allSatisfy { byte in
      (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte)
        || (0x61...0x7A).contains(byte) || byte == 0x2D || byte == 0x2E || byte == 0x5F
    }
  }

  private static func isValidRedirectURI(_ value: URL) -> Bool {
    guard let components = URLComponents(url: value, resolvingAgainstBaseURL: false) else {
      return false
    }
    guard components.user == nil, components.password == nil, components.query == nil,
      components.fragment == nil, !components.path.isEmpty
    else { return false }
    if components.scheme == "https" {
      return components.host != nil
    }
    if components.scheme == "http" {
      return components.host == "127.0.0.1" && components.port != nil
    }
    return components.scheme?.contains(".") == true && components.host == nil
  }

  private static func isValidProfileEndpoint(_ value: URL) -> Bool {
    guard let components = URLComponents(url: value, resolvingAgainstBaseURL: false) else {
      return false
    }
    return components.scheme == "https" && components.host != nil && !components.path.isEmpty
      && components.user == nil && components.password == nil && components.query == nil
      && components.fragment == nil
  }

  private static func isDevelopmentDesktopRedirect(_ value: URL) -> Bool {
    guard let components = URLComponents(url: value, resolvingAgainstBaseURL: false) else {
      return false
    }
    return components.scheme == "http" && components.host == "127.0.0.1"
      && components.port.map({ (1...65_535).contains($0) }) == true
      && components.path == "/oauth/callback" && components.user == nil
      && components.password == nil && components.query == nil && components.fragment == nil
  }
}

/// A browser authorization request that contains no access or refresh token.
public struct OAuthAuthorizationPresentationRequest: Equatable, Sendable {
  public let authorizationURL: URL
  public let redirectURI: URL

  public init(authorizationURL: URL, redirectURI: URL) {
    self.authorizationURL = authorizationURL
    self.redirectURI = redirectURI
  }
}

/// Presents the authorization URL and returns the final registered callback URL.
public protocol OAuthAuthorizationPresenting: Sendable {
  @MainActor
  func authorize(_ request: OAuthAuthorizationPresentationRequest) async throws -> URL
}

/// Adapts a host application's system-browser implementation to the SDK authorization boundary.
public struct ClosureOAuthAuthorizationPresenter: OAuthAuthorizationPresenting {
  private let handler:
    @MainActor @Sendable (OAuthAuthorizationPresentationRequest) async throws -> URL

  public init(
    handler:
      @escaping @MainActor @Sendable (OAuthAuthorizationPresentationRequest) async throws -> URL
  ) {
    self.handler = handler
  }

  @MainActor
  public func authorize(_ request: OAuthAuthorizationPresentationRequest) async throws -> URL {
    try await handler(request)
  }
}

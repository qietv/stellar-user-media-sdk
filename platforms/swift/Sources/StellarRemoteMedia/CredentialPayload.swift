import Foundation
import StellarCore

/// The supported authentication shape inside a version 1 plaintext credential payload.
public enum CredentialAuthenticationType: String, Codable, Equatable, Sendable {
  case usernamePassword = "username_password"
  case oauthToken = "oauth_token"
  case apiToken = "api_token"
  case cookie
  case keyPair = "key_pair"
}

/// One bounded HTTP cookie inside a synchronized credential payload.
public struct CredentialCookie: Codable, Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let name: String
  public let value: String
  public let domain: String
  public let path: String
  public let secure: Bool
  public let httpOnly: Bool
  public let expiresAtMilliseconds: Int64?

  public init(
    name: String,
    value: String,
    domain: String,
    path: String = "/",
    secure: Bool = true,
    httpOnly: Bool = true,
    expiresAtMilliseconds: Int64? = nil
  ) throws {
    guard name.range(of: #"^[^\s=;]{1,256}$"#, options: .regularExpression) != nil,
      Self.validSecret(value, maximumUTF8Count: 8_192),
      Self.validDomain(domain),
      path.hasPrefix("/"), Self.validSecret(path, maximumUTF8Count: 2_048),
      expiresAtMilliseconds.map({ $0 >= 0 }) ?? true
    else {
      throw SDKError(code: .invalidConfiguration, message: "credential cookie is invalid")
    }
    self.name = name
    self.value = value
    self.domain = domain.lowercased()
    self.path = path
    self.secure = secure
    self.httpOnly = httpOnly
    self.expiresAtMilliseconds = expiresAtMilliseconds
  }

  public init(from decoder: Decoder) throws {
    let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
    let supportedKeys = Set(CodingKeys.allCases.map(\.rawValue))
    guard Set(dynamicContainer.allKeys.map(\.stringValue)).isSubset(of: supportedKeys) else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: decoder.codingPath,
          debugDescription: "credential cookie contains unsupported fields"
        )
      )
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        name: container.decode(String.self, forKey: .name),
        value: container.decode(String.self, forKey: .value),
        domain: container.decode(String.self, forKey: .domain),
        path: container.decodeIfPresent(String.self, forKey: .path) ?? "/",
        secure: container.decodeIfPresent(Bool.self, forKey: .secure) ?? true,
        httpOnly: container.decodeIfPresent(Bool.self, forKey: .httpOnly) ?? true,
        expiresAtMilliseconds: container.decodeIfPresent(
          Int64.self,
          forKey: .expiresAtMilliseconds
        )
      )
    } catch let error as SDKError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message)
      )
    }
  }

  /// A representation that never reveals cookie identity or value.
  public var description: String { "<CredentialCookie redacted>" }

  /// A representation that never reveals cookie identity or value.
  public var debugDescription: String { description }

  private static func validDomain(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 255
      && value.rangeOfCharacter(from: .controlCharacters) == nil
      && value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
      && !value.contains("/") && !value.contains("\\") && !value.contains("@")
      && !value.contains("://")
  }

  private static func validSecret(_ value: String, maximumUTF8Count: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maximumUTF8Count && !value.contains("\0")
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case name
    case value
    case domain
    case path
    case secure
    case httpOnly = "http_only"
    case expiresAtMilliseconds = "expires_at_ms"
  }

  private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
      self.stringValue = stringValue
      intValue = nil
    }

    init?(intValue: Int) {
      stringValue = String(intValue)
      self.intValue = intValue
    }
  }
}

/// A strict, versioned plaintext credential payload.
///
/// Only fields belonging to the selected authentication type are accepted when decoding. Ordinary
/// descriptions redact every field because usernames, cookie scope, and key metadata are all part
/// of the credential boundary.
public struct CredentialPayload: Codable, Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let authenticationType: CredentialAuthenticationType
  public let username: String?
  public let password: String?
  public let domain: String?
  public let refreshToken: String?
  public let accessToken: String?
  public let expiresAtMilliseconds: Int64?
  public let scope: String?
  public let token: String?
  public let cookies: [CredentialCookie]?
  public let privateKeyPEM: String?
  public let publicKeyPEM: String?
  public let passphrase: String?
  public let schemaVersion: Int

  public init(
    authenticationType: CredentialAuthenticationType,
    username: String? = nil,
    password: String? = nil,
    domain: String? = nil,
    refreshToken: String? = nil,
    accessToken: String? = nil,
    expiresAtMilliseconds: Int64? = nil,
    scope: String? = nil,
    token: String? = nil,
    cookies: [CredentialCookie]? = nil,
    privateKeyPEM: String? = nil,
    publicKeyPEM: String? = nil,
    passphrase: String? = nil,
    schemaVersion: Int = 1
  ) throws {
    guard schemaVersion == 1,
      Self.valid(
        authenticationType: authenticationType,
        username: username,
        password: password,
        domain: domain,
        refreshToken: refreshToken,
        accessToken: accessToken,
        expiresAtMilliseconds: expiresAtMilliseconds,
        scope: scope,
        token: token,
        cookies: cookies,
        privateKeyPEM: privateKeyPEM,
        publicKeyPEM: publicKeyPEM,
        passphrase: passphrase
      )
    else {
      throw SDKError(code: .invalidConfiguration, message: "credential payload is invalid")
    }
    self.authenticationType = authenticationType
    self.username = username
    self.password = password
    self.domain = domain
    self.refreshToken = refreshToken
    self.accessToken = accessToken
    self.expiresAtMilliseconds = expiresAtMilliseconds
    self.scope = scope
    self.token = token
    self.cookies = cookies
    self.privateKeyPEM = privateKeyPEM
    self.publicKeyPEM = publicKeyPEM
    self.passphrase = passphrase
    self.schemaVersion = schemaVersion
  }

  /// Parses one complete payload and rejects unknown keys, schemas, and authentication types.
  public init(jsonString: String) throws {
    guard !jsonString.isEmpty, jsonString.utf8.count <= 65_536 else {
      throw SDKError(code: .invalidConfiguration, message: "credential payload is invalid")
    }
    do {
      self = try JSONDecoder().decode(Self.self, from: Data(jsonString.utf8))
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .invalidConfiguration, message: "credential payload is invalid")
    }
  }

  public init(from decoder: Decoder) throws {
    let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let authenticationType = try container.decode(
      CredentialAuthenticationType.self,
      forKey: .authenticationType
    )
    let actualKeys = Set(dynamicContainer.allKeys.map(\.stringValue))
    guard actualKeys.isSubset(of: Self.allowedKeys(for: authenticationType)) else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: decoder.codingPath,
          debugDescription: "credential payload contains unsupported fields"
        )
      )
    }
    do {
      try self.init(
        authenticationType: authenticationType,
        username: container.decodeIfPresent(String.self, forKey: .username),
        password: container.decodeIfPresent(String.self, forKey: .password),
        domain: container.decodeIfPresent(String.self, forKey: .domain),
        refreshToken: container.decodeIfPresent(String.self, forKey: .refreshToken),
        accessToken: container.decodeIfPresent(String.self, forKey: .accessToken),
        expiresAtMilliseconds: container.decodeIfPresent(
          Int64.self,
          forKey: .expiresAtMilliseconds
        ),
        scope: container.decodeIfPresent(String.self, forKey: .scope),
        token: container.decodeIfPresent(String.self, forKey: .token),
        cookies: container.decodeIfPresent([CredentialCookie].self, forKey: .cookies),
        privateKeyPEM: container.decodeIfPresent(String.self, forKey: .privateKeyPEM),
        publicKeyPEM: container.decodeIfPresent(String.self, forKey: .publicKeyPEM),
        passphrase: container.decodeIfPresent(String.self, forKey: .passphrase),
        schemaVersion: container.decode(Int.self, forKey: .schemaVersion)
      )
    } catch let error as SDKError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message)
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(authenticationType, forKey: .authenticationType)
    try container.encodeIfPresent(username, forKey: .username)
    try container.encodeIfPresent(password, forKey: .password)
    try container.encodeIfPresent(domain, forKey: .domain)
    try container.encodeIfPresent(refreshToken, forKey: .refreshToken)
    try container.encodeIfPresent(accessToken, forKey: .accessToken)
    try container.encodeIfPresent(expiresAtMilliseconds, forKey: .expiresAtMilliseconds)
    try container.encodeIfPresent(scope, forKey: .scope)
    try container.encodeIfPresent(token, forKey: .token)
    try container.encodeIfPresent(cookies, forKey: .cookies)
    try container.encodeIfPresent(privateKeyPEM, forKey: .privateKeyPEM)
    try container.encodeIfPresent(publicKeyPEM, forKey: .publicKeyPEM)
    try container.encodeIfPresent(passphrase, forKey: .passphrase)
    try container.encode(schemaVersion, forKey: .schemaVersion)
  }

  /// Returns deterministic JSON suitable for `CredentialRecord.payload_json`.
  public func canonicalJSONString() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(self)
    guard data.count <= 65_536 else {
      throw SDKError(code: .invalidConfiguration, message: "credential payload is too large")
    }
    return String(decoding: data, as: UTF8.self)
  }

  /// The credential kind that must accompany this payload in a synchronized record.
  public var credentialKind: CredentialKind {
    switch authenticationType {
    case .usernamePassword: .password
    case .oauthToken: .oauthToken
    case .apiToken: .apiToken
    case .cookie: .cookie
    case .keyPair: .keyPair
    }
  }

  /// A representation that never reveals any payload field.
  public var description: String { "<CredentialPayload redacted>" }

  /// A representation that never reveals any payload field.
  public var debugDescription: String { description }

  private static func allowedKeys(
    for authenticationType: CredentialAuthenticationType
  ) -> Set<String> {
    let common = [CodingKeys.authenticationType.rawValue, CodingKeys.schemaVersion.rawValue]
    let specific: [String]
    switch authenticationType {
    case .usernamePassword:
      specific = [
        CodingKeys.username.rawValue, CodingKeys.password.rawValue, CodingKeys.domain.rawValue,
      ]
    case .oauthToken:
      specific = [
        CodingKeys.refreshToken.rawValue, CodingKeys.accessToken.rawValue,
        CodingKeys.expiresAtMilliseconds.rawValue, CodingKeys.scope.rawValue,
      ]
    case .apiToken:
      specific = [CodingKeys.token.rawValue, CodingKeys.username.rawValue]
    case .cookie:
      specific = [CodingKeys.cookies.rawValue]
    case .keyPair:
      specific = [
        CodingKeys.privateKeyPEM.rawValue, CodingKeys.publicKeyPEM.rawValue,
        CodingKeys.passphrase.rawValue,
      ]
    }
    return Set(common + specific)
  }

  private static func valid(
    authenticationType: CredentialAuthenticationType,
    username: String?,
    password: String?,
    domain: String?,
    refreshToken: String?,
    accessToken: String?,
    expiresAtMilliseconds: Int64?,
    scope: String?,
    token: String?,
    cookies: [CredentialCookie]?,
    privateKeyPEM: String?,
    publicKeyPEM: String?,
    passphrase: String?
  ) -> Bool {
    switch authenticationType {
    case .usernamePassword:
      return validText(username, maximumUTF8Count: 1_024)
        && validText(password, maximumUTF8Count: 32_768)
        && validOptionalText(domain, maximumUTF8Count: 1_024)
        && allNil(
          refreshToken, accessToken, expiresAtMilliseconds, scope, token, cookies,
          privateKeyPEM, publicKeyPEM, passphrase
        )
    case .oauthToken:
      return validText(refreshToken, maximumUTF8Count: 32_768)
        && validOptionalText(accessToken, maximumUTF8Count: 32_768)
        && ((accessToken == nil) == (expiresAtMilliseconds == nil))
        && (expiresAtMilliseconds.map({ $0 >= 0 }) ?? true)
        && validOptionalText(scope, maximumUTF8Count: 4_096)
        && allNil(
          username, password, domain, token, cookies, privateKeyPEM, publicKeyPEM, passphrase)
    case .apiToken:
      return validText(token, maximumUTF8Count: 32_768)
        && validOptionalText(username, maximumUTF8Count: 1_024)
        && allNil(
          password, domain, refreshToken, accessToken, expiresAtMilliseconds, scope,
          cookies, privateKeyPEM, publicKeyPEM, passphrase
        )
    case .cookie:
      guard let cookies, !cookies.isEmpty, cookies.count <= 128 else { return false }
      let identities = cookies.map { "\($0.name)\0\($0.domain)\0\($0.path)" }
      return Set(identities).count == identities.count
        && allNil(
          username, password, domain, refreshToken, accessToken, expiresAtMilliseconds,
          scope, token, privateKeyPEM, publicKeyPEM, passphrase
        )
    case .keyPair:
      return validText(privateKeyPEM, maximumUTF8Count: 49_152)
        && validOptionalText(publicKeyPEM, maximumUTF8Count: 49_152)
        && validOptionalText(passphrase, maximumUTF8Count: 32_768)
        && allNil(
          username, password, domain, refreshToken, accessToken, expiresAtMilliseconds,
          scope, token, cookies
        )
    }
  }

  private static func validText(_ value: String?, maximumUTF8Count: Int) -> Bool {
    guard let value else { return false }
    return !value.isEmpty && value.utf8.count <= maximumUTF8Count && !value.contains("\0")
  }

  private static func validOptionalText(_ value: String?, maximumUTF8Count: Int) -> Bool {
    value.map { !$0.isEmpty && $0.utf8.count <= maximumUTF8Count && !$0.contains("\0") } ?? true
  }

  private static func allNil(_ values: Any?...) -> Bool {
    values.allSatisfy { $0 == nil }
  }

  private enum CodingKeys: String, CodingKey {
    case authenticationType = "auth_type"
    case username
    case password
    case domain
    case refreshToken = "refresh_token"
    case accessToken = "access_token"
    case expiresAtMilliseconds = "expires_at_ms"
    case scope
    case token
    case cookies
    case privateKeyPEM = "private_key_pem"
    case publicKeyPEM = "public_key_pem"
    case passphrase
    case schemaVersion = "schema_version"
  }

  private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
      self.stringValue = stringValue
      intValue = nil
    }

    init?(intValue: Int) {
      stringValue = String(intValue)
      self.intValue = intValue
    }
  }
}

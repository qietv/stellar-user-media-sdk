import Foundation

/// The type of third-party credential carried by a synchronized record.
public enum CredentialKind: Equatable, Sendable {
  case password
  case oauthToken
  case apiToken
  case cookie
  case keyPair
  case unknown(String)
}

extension CredentialKind: Codable {
  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self =
      switch value {
      case "password": .password
      case "oauth_token": .oauthToken
      case "api_token": .apiToken
      case "cookie": .cookie
      case "key_pair": .keyPair
      default: .unknown(value)
      }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    let value =
      switch self {
      case .password: "password"
      case .oauthToken: "oauth_token"
      case .apiToken: "api_token"
      case .cookie: "cookie"
      case .keyPair: "key_pair"
      case .unknown(let value): value
      }
    try container.encode(value)
  }
}

/// The application-layer protection applied to a synchronized credential payload.
public enum CredentialProtectionMode: Equatable, Sendable {
  case plaintext
  case serverEncrypted
  case endToEndEncrypted
  case unknown(String)
}

extension CredentialProtectionMode: Codable {
  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self =
      switch value {
      case "plaintext": .plaintext
      case "server_encrypted": .serverEncrypted
      case "end_to_end_encrypted": .endToEndEncrypted
      default: .unknown(value)
      }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    let value =
      switch self {
      case .plaintext: "plaintext"
      case .serverEncrypted: "server_encrypted"
      case .endToEndEncrypted: "end_to_end_encrypted"
      case .unknown(let value): value
      }
    try container.encode(value)
  }
}

/// A versioned third-party credential that can be stored locally and synchronized.
///
/// Version 1 creates plaintext records. Optional protected-payload fields reserve a migration seam
/// and do not claim that server-managed or end-to-end encryption is implemented. Descriptions
/// always redact both plaintext and protected payload material.
public struct CredentialRecord: Codable, Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let credentialUID: String
  public let accountUID: String
  public let sourceUID: String
  public let kind: CredentialKind
  public let protectionMode: CredentialProtectionMode
  public let payloadJSON: String?
  public let algorithm: String?
  public let keyVersion: Int?
  public let nonceBase64: String?
  public let protectedPayloadBase64: String?
  public let authenticatedDataVersion: Int?
  public let revision: Int64
  public let updatedAtMilliseconds: Int64
  public let deletedAtMilliseconds: Int64?
  public let schemaVersion: Int

  public init(
    credentialUID: String,
    accountUID: String,
    sourceUID: String,
    kind: CredentialKind,
    protectionMode: CredentialProtectionMode = .plaintext,
    payloadJSON: String?,
    algorithm: String? = nil,
    keyVersion: Int? = nil,
    nonceBase64: String? = nil,
    protectedPayloadBase64: String? = nil,
    authenticatedDataVersion: Int? = nil,
    revision: Int64,
    updatedAtMilliseconds: Int64,
    deletedAtMilliseconds: Int64? = nil,
    schemaVersion: Int = 1
  ) {
    self.credentialUID = credentialUID
    self.accountUID = accountUID
    self.sourceUID = sourceUID
    self.kind = kind
    self.protectionMode = protectionMode
    self.payloadJSON = payloadJSON
    self.algorithm = algorithm
    self.keyVersion = keyVersion
    self.nonceBase64 = nonceBase64
    self.protectedPayloadBase64 = protectedPayloadBase64
    self.authenticatedDataVersion = authenticatedDataVersion
    self.revision = revision
    self.updatedAtMilliseconds = updatedAtMilliseconds
    self.deletedAtMilliseconds = deletedAtMilliseconds
    self.schemaVersion = schemaVersion
  }

  /// Keeps all credential payload material out of ordinary interpolation and logs.
  public var description: String {
    "CredentialRecord(credentialUID: \(credentialUID), sourceUID: \(sourceUID), payload: <redacted>)"
  }

  public var debugDescription: String { description }

  private enum CodingKeys: String, CodingKey {
    case credentialUID = "credential_uid"
    case accountUID = "account_uid"
    case sourceUID = "source_uid"
    case kind
    case protectionMode = "protection_mode"
    case payloadJSON = "payload_json"
    case algorithm
    case keyVersion = "key_version"
    case nonceBase64 = "nonce_b64"
    case protectedPayloadBase64 = "protected_payload_b64"
    case authenticatedDataVersion = "aad_version"
    case revision
    case updatedAtMilliseconds = "updated_at_ms"
    case deletedAtMilliseconds = "deleted_at_ms"
    case schemaVersion = "schema_version"
  }
}

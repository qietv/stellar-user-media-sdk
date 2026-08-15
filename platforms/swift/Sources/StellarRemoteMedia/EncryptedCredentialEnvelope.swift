import Foundation
import StellarCore

/// The type of third-party secret sealed inside a credential envelope.
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

/// A versioned encrypted value safe to persist in account SQLite and synchronize as ciphertext.
///
/// This type performs no cryptography. A platform `CredentialVault` implementation must seal and
/// open it using the algorithm and authenticated-data rules in `specs/security/credential-vault.md`.
public struct EncryptedCredentialEnvelope: Codable, Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let credentialUID: String
  public let accountUID: String
  public let sourceUID: String
  public let kind: CredentialKind
  public let algorithm: String
  public let keyVersion: Int
  public let nonceBase64: String
  public let ciphertextBase64: String
  public let authenticatedDataVersion: Int
  public let revision: Int64
  public let updatedAtMilliseconds: Int64
  public let deletedAtMilliseconds: Int64?
  public let schemaVersion: Int

  public init(
    credentialUID: String,
    accountUID: String,
    sourceUID: String,
    kind: CredentialKind,
    algorithm: String = "aes_256_gcm",
    keyVersion: Int,
    nonceBase64: String,
    ciphertextBase64: String,
    authenticatedDataVersion: Int = 1,
    revision: Int64,
    updatedAtMilliseconds: Int64,
    deletedAtMilliseconds: Int64? = nil,
    schemaVersion: Int = 1
  ) {
    self.credentialUID = credentialUID
    self.accountUID = accountUID
    self.sourceUID = sourceUID
    self.kind = kind
    self.algorithm = algorithm
    self.keyVersion = keyVersion
    self.nonceBase64 = nonceBase64
    self.ciphertextBase64 = ciphertextBase64
    self.authenticatedDataVersion = authenticatedDataVersion
    self.revision = revision
    self.updatedAtMilliseconds = updatedAtMilliseconds
    self.deletedAtMilliseconds = deletedAtMilliseconds
    self.schemaVersion = schemaVersion
  }

  /// Keeps encrypted payload material out of ordinary interpolation and logs.
  public var description: String {
    "EncryptedCredentialEnvelope(credentialUID: \(credentialUID), sourceUID: \(sourceUID), ciphertext: <redacted>)"
  }

  public var debugDescription: String { description }

  private enum CodingKeys: String, CodingKey {
    case credentialUID = "credential_uid"
    case accountUID = "account_uid"
    case sourceUID = "source_uid"
    case kind
    case algorithm
    case keyVersion = "key_version"
    case nonceBase64 = "nonce_b64"
    case ciphertextBase64 = "ciphertext_b64"
    case authenticatedDataVersion = "aad_version"
    case revision
    case updatedAtMilliseconds = "updated_at_ms"
    case deletedAtMilliseconds = "deleted_at_ms"
    case schemaVersion = "schema_version"
  }
}

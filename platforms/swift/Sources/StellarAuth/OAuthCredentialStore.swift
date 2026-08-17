import Foundation
import StellarCore

#if canImport(Security) && canImport(LocalAuthentication)
  import LocalAuthentication
  import Security
#endif

/// Device-bound Keychain accessibility used for the Stellar refresh token.
public enum OAuthTokenAccessibility: String, Sendable {
  case whenUnlockedThisDeviceOnly = "when_unlocked_this_device_only"
  case afterFirstUnlockThisDeviceOnly = "after_first_unlock_this_device_only"
}

struct StoredOAuthCredential: Codable, Equatable, Sendable {
  let issuer: String
  let clientID: String
  let session: UserSession
  let refreshToken: String
  let schemaVersion: Int

  init(
    configuration: StellarOAuthConfiguration,
    session: UserSession,
    refreshToken: String
  ) throws {
    guard session.issuer == configuration.issuer.absoluteString,
      !refreshToken.isEmpty,
      refreshToken.utf8.count <= 8_192
    else {
      throw SDKError(code: .invalidConfiguration, message: "Stored OAuth credential is invalid")
    }
    issuer = configuration.issuer.absoluteString
    clientID = configuration.clientID
    self.session = session
    self.refreshToken = refreshToken
    schemaVersion = 1
  }

  private enum CodingKeys: String, CodingKey {
    case issuer
    case clientID = "client_id"
    case session
    case refreshToken = "refresh_token"
    case schemaVersion = "schema_version"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let issuer = try container.decode(String.self, forKey: .issuer)
    let clientID = try container.decode(String.self, forKey: .clientID)
    let session = try container.decode(UserSession.self, forKey: .session)
    let refreshToken = try container.decode(String.self, forKey: .refreshToken)
    let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    guard issuer == session.issuer,
      !clientID.isEmpty,
      clientID.utf8.count <= 128,
      !refreshToken.isEmpty,
      refreshToken.utf8.count <= 8_192,
      schemaVersion == 1
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion,
        in: container,
        debugDescription: "stored OAuth credential is invalid"
      )
    }
    self.issuer = issuer
    self.clientID = clientID
    self.session = session
    self.refreshToken = refreshToken
    self.schemaVersion = schemaVersion
  }
}

protocol OAuthCredentialStoring: Sendable {
  func credentials() async throws -> [StoredOAuthCredential]
  func activeAccountUID() async throws -> String?
  func save(_ credential: StoredOAuthCredential) async throws
  func remove(accountUID: String) async throws
  func setActiveAccountUID(_ accountUID: String?) async throws
}

actor KeychainOAuthCredentialStore: OAuthCredentialStoring {
  private let configuration: StellarOAuthConfiguration
  private let accessibility: OAuthTokenAccessibility
  private let credentialService = "cn.2dland.stellar-user-media-sdk.oauth.v1"
  private let activeService = "cn.2dland.stellar-user-media-sdk.oauth.active.v1"

  init(
    configuration: StellarOAuthConfiguration,
    accessibility: OAuthTokenAccessibility
  ) {
    self.configuration = configuration
    self.accessibility = accessibility
  }

  func credentials() async throws -> [StoredOAuthCredential] {
    #if canImport(Security) && canImport(LocalAuthentication)
      var query = baseQuery(service: credentialService)
      query[kSecMatchLimit as String] = kSecMatchLimitAll
      query[kSecReturnData as String] = true
      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      if status == errSecItemNotFound { return [] }
      guard status == errSecSuccess else { throw storageError(status) }
      let values: [Data]
      if let rows = result as? [[String: Any]] {
        values = rows.compactMap { $0[kSecValueData as String] as? Data }
        guard values.count == rows.count else { throw storageError(errSecDecode) }
      } else if let row = result as? [String: Any],
        let data = row[kSecValueData as String] as? Data
      {
        values = [data]
      } else {
        throw storageError(errSecDecode)
      }
      let decoder = JSONDecoder()
      let decoded = try values.map { data in
        do {
          return try decoder.decode(StoredOAuthCredential.self, from: data)
        } catch {
          throw storageError(errSecDecode)
        }
      }
      return decoded.filter {
        $0.issuer == configuration.issuer.absoluteString
          && $0.clientID == configuration.clientID && $0.schemaVersion == 1
      }.sorted { $0.session.accountUID < $1.session.accountUID }
    #else
      throw unsupportedStorageError()
    #endif
  }

  func activeAccountUID() async throws -> String? {
    #if canImport(Security) && canImport(LocalAuthentication)
      var query = baseQuery(service: activeService)
      query[kSecAttrAccount as String] = activeAccountKey
      query[kSecMatchLimit as String] = kSecMatchLimitOne
      query[kSecReturnData as String] = true
      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      if status == errSecItemNotFound { return nil }
      guard status == errSecSuccess, let data = result as? Data else {
        throw storageError(status == errSecSuccess ? errSecDecode : status)
      }
      guard let accountUID = String(data: data, encoding: .utf8),
        UUID(uuidString: accountUID) != nil
      else {
        throw storageError(errSecDecode)
      }
      return accountUID.lowercased()
    #else
      throw unsupportedStorageError()
    #endif
  }

  func save(_ credential: StoredOAuthCredential) async throws {
    #if canImport(Security) && canImport(LocalAuthentication)
      guard credential.issuer == configuration.issuer.absoluteString,
        credential.clientID == configuration.clientID,
        credential.schemaVersion == 1
      else { throw storageError(errSecParam) }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data: Data
      do {
        data = try encoder.encode(credential)
      } catch {
        throw storageError(errSecParam)
      }
      try upsert(
        service: credentialService,
        account: credentialAccountKey(credential.session.accountUID),
        data: data
      )
    #else
      throw unsupportedStorageError()
    #endif
  }

  func remove(accountUID: String) async throws {
    #if canImport(Security) && canImport(LocalAuthentication)
      var query = baseQuery(service: credentialService)
      query[kSecAttrAccount as String] = credentialAccountKey(accountUID)
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw storageError(status)
      }
      if try await activeAccountUID() == accountUID.lowercased() {
        try await setActiveAccountUID(nil)
      }
    #else
      throw unsupportedStorageError()
    #endif
  }

  func setActiveAccountUID(_ accountUID: String?) async throws {
    #if canImport(Security) && canImport(LocalAuthentication)
      guard accountUID.map({ UUID(uuidString: $0) != nil }) ?? true else {
        throw storageError(errSecParam)
      }
      if let accountUID {
        try upsert(
          service: activeService,
          account: activeAccountKey,
          data: Data(accountUID.lowercased().utf8)
        )
      } else {
        var query = baseQuery(service: activeService)
        query[kSecAttrAccount as String] = activeAccountKey
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
          throw storageError(status)
        }
      }
    #else
      throw unsupportedStorageError()
    #endif
  }

  private var activeAccountKey: String {
    "\(configuration.issuer.absoluteString)|\(configuration.clientID)"
  }

  private func credentialAccountKey(_ accountUID: String) -> String {
    "\(activeAccountKey)|\(accountUID.lowercased())"
  }

  #if canImport(Security) && canImport(LocalAuthentication)
    private func baseQuery(service: String) -> [String: Any] {
      let context = LAContext()
      context.interactionNotAllowed = true
      return [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrSynchronizable as String: false,
        kSecUseDataProtectionKeychain as String: true,
        kSecUseAuthenticationContext as String: context,
      ]
    }

    private func upsert(service: String, account: String, data: Data) throws {
      var attributes = baseQuery(service: service)
      attributes[kSecAttrAccount as String] = account
      attributes[kSecAttrAccessible as String] = keychainAccessibility
      attributes[kSecValueData as String] = data
      var status = SecItemAdd(attributes as CFDictionary, nil)
      if status == errSecDuplicateItem {
        var query = baseQuery(service: service)
        query[kSecAttrAccount as String] = account
        status = SecItemUpdate(
          query as CFDictionary,
          [
            kSecValueData as String: data,
            kSecAttrAccessible as String: keychainAccessibility,
          ] as CFDictionary
        )
      }
      guard status == errSecSuccess else { throw storageError(status) }
    }

    private var keychainAccessibility: CFString {
      switch accessibility {
      case .whenUnlockedThisDeviceOnly:
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      case .afterFirstUnlockThisDeviceOnly:
        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      }
    }

    private func storageError(_ status: OSStatus) -> SDKError {
      SDKError(
        code: .storageFailure,
        message: status == errSecInteractionNotAllowed
          ? "OAuth credential requires disallowed Keychain interaction"
          : "OAuth credential storage failed"
      )
    }
  #endif

  private func unsupportedStorageError() -> SDKError {
    SDKError(
      code: .storageFailure,
      message: "OAuth secure credential storage is unavailable on this platform"
    )
  }
}

actor InMemoryOAuthCredentialStore: OAuthCredentialStoring {
  private var values: [String: StoredOAuthCredential] = [:]
  private var activeUID: String?

  func credentials() -> [StoredOAuthCredential] {
    values.values.sorted { $0.session.accountUID < $1.session.accountUID }
  }

  func activeAccountUID() -> String? { activeUID }

  func save(_ credential: StoredOAuthCredential) {
    values[credential.session.accountUID] = credential
  }

  func remove(accountUID: String) {
    values.removeValue(forKey: accountUID.lowercased())
    if activeUID == accountUID.lowercased() { activeUID = nil }
  }

  func setActiveAccountUID(_ accountUID: String?) {
    activeUID = accountUID?.lowercased()
  }
}

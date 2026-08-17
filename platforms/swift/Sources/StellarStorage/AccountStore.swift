import Foundation
import GRDB
import StellarCore
import StellarRemoteMedia

/// Non-secret metadata for one pending account-domain outbox operation.
public struct AccountOutboxRecord: Codable, Equatable, Sendable {
  public let sequence: Int64
  public let operationUID: String
  public let accountUID: String
  public let entityType: String
  public let entityUID: String
  public let baseRevision: Int64
  public let operation: String
  public let retryCount: Int

  private enum CodingKeys: String, CodingKey {
    case sequence
    case operationUID = "operation_uid"
    case accountUID = "account_uid"
    case entityType = "entity_type"
    case entityUID = "entity_uid"
    case baseRevision = "base_revision"
    case operation
    case retryCount = "retry_count"
  }
}

/// Transactional account repository for synchronized credential records and their outbox.
public struct AccountStore: Sendable {
  public let database: StorageDatabase
  package let uuidGenerator: any SDKUUIDGenerating

  public init(
    database: StorageDatabase,
    uuidGenerator: any SDKUUIDGenerating = SystemSDKUUIDGenerator()
  ) throws {
    guard database.kind == .account else {
      throw SDKError(code: .invalidConfiguration, message: "AccountStore requires account.sqlite")
    }
    self.database = database
    self.uuidGenerator = uuidGenerator
  }

  /// Upserts a v1 plaintext credential record and enqueues its sync operation atomically.
  public func saveCredentialRecord(
    _ record: CredentialRecord,
    baseRevision: Int64,
    operationUID suppliedOperationUID: String? = nil
  ) async throws {
    guard baseRevision >= 0 else {
      throw SDKError(code: .invalidConfiguration, message: "base revision must not be negative")
    }
    let operationUID =
      suppliedOperationUID
      ?? uuidGenerator.makeUUID().uuidString.lowercased()
    let kind = Self.credentialKind(record.kind)
    guard !operationUID.isEmpty, !operationUID.contains("\0") else {
      throw SDKError(code: .invalidConfiguration, message: "operation UID is invalid")
    }
    guard record.protectionMode == .plaintext else {
      throw SDKError(
        code: .credentialProtectionUnsupported,
        message: "credential protection mode is not supported by this client"
      )
    }
    guard !record.credentialUID.isEmpty, !record.accountUID.isEmpty,
      !record.sourceUID.isEmpty, !record.credentialUID.contains("\0"),
      !record.accountUID.contains("\0"), !record.sourceUID.contains("\0"),
      !kind.isEmpty, kind.utf8.count <= 64,
      kind.rangeOfCharacter(from: .controlCharacters) == nil,
      record.algorithm == nil, record.keyVersion == nil, record.nonceBase64 == nil,
      record.protectedPayloadBase64 == nil, record.authenticatedDataVersion == nil,
      record.revision >= 0, record.updatedAtMilliseconds >= 0,
      record.deletedAtMilliseconds.map({ $0 >= 0 }) ?? true,
      record.schemaVersion == 1
    else {
      throw SDKError(code: .invalidConfiguration, message: "credential record is invalid")
    }
    let canonicalPayloadJSON: String?
    do {
      canonicalPayloadJSON = try Self.canonicalPlaintextPayload(
        record.payloadJSON,
        kind: record.kind,
        tombstone: record.deletedAtMilliseconds != nil
      )
    } catch {
      throw SDKError(code: .invalidConfiguration, message: "credential record is invalid")
    }
    let normalizedRecord = CredentialRecord(
      credentialUID: record.credentialUID,
      accountUID: record.accountUID,
      sourceUID: record.sourceUID,
      kind: record.kind,
      protectionMode: record.protectionMode,
      payloadJSON: canonicalPayloadJSON,
      algorithm: record.algorithm,
      keyVersion: record.keyVersion,
      nonceBase64: record.nonceBase64,
      protectedPayloadBase64: record.protectedPayloadBase64,
      authenticatedDataVersion: record.authenticatedDataVersion,
      revision: record.revision,
      updatedAtMilliseconds: record.updatedAtMilliseconds,
      deletedAtMilliseconds: record.deletedAtMilliseconds,
      schemaVersion: record.schemaVersion
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let payload: String
    do {
      payload = String(decoding: try encoder.encode(normalizedRecord), as: UTF8.self)
    } catch {
      throw SDKError(code: .parseFailure, message: "credential record encoding failed")
    }
    let operation = record.deletedAtMilliseconds == nil ? "upsert" : "delete"

    do {
      try await database.write { database in
        if let existing = try Row.fetchOne(
          database,
          sql: "SELECT account_uid, source_uid FROM credential_record WHERE credential_uid = ?",
          arguments: [record.credentialUID]
        ) {
          let existingAccountUID: String = existing["account_uid"]
          let existingSourceUID: String = existing["source_uid"]
          guard existingAccountUID == record.accountUID, existingSourceUID == record.sourceUID
          else {
            throw SDKError(
              code: .conflict,
              message: "credential record cannot move between accounts or sources"
            )
          }
        }
        try database.execute(
          sql: """
            INSERT INTO credential_record(
              credential_uid, account_uid, source_uid, kind, protection_mode, payload_json,
              algorithm, key_version, nonce_b64, protected_payload_b64, aad_version,
              revision, base_revision, updated_at_ms, deleted_at_ms, schema_version
            ) VALUES (?, ?, ?, ?, 'plaintext', ?, NULL, NULL, NULL, NULL, NULL, ?, ?, ?, ?, ?)
            ON CONFLICT(credential_uid) DO UPDATE SET
              account_uid = excluded.account_uid,
              source_uid = excluded.source_uid,
              kind = excluded.kind,
              protection_mode = excluded.protection_mode,
              payload_json = excluded.payload_json,
              algorithm = excluded.algorithm,
              key_version = excluded.key_version,
              nonce_b64 = excluded.nonce_b64,
              protected_payload_b64 = excluded.protected_payload_b64,
              aad_version = excluded.aad_version,
              revision = excluded.revision,
              base_revision = excluded.base_revision,
              updated_at_ms = excluded.updated_at_ms,
              deleted_at_ms = excluded.deleted_at_ms,
              schema_version = excluded.schema_version
            """,
          arguments: [
            record.credentialUID, record.accountUID, record.sourceUID, kind, canonicalPayloadJSON,
            record.revision, baseRevision, record.updatedAtMilliseconds,
            record.deletedAtMilliseconds, record.schemaVersion,
          ]
        )
        try database.execute(
          sql: """
            INSERT INTO account_change_log(
              operation_uid, account_uid, entity_type, entity_uid, base_revision,
              operation, payload_json, modified_at_ms
            ) VALUES (?, ?, 'credential_record', ?, ?, ?, ?, ?)
            ON CONFLICT(operation_uid) DO NOTHING
            """,
          arguments: [
            operationUID, record.accountUID, record.credentialUID, baseRevision,
            operation, payload, record.updatedAtMilliseconds,
          ]
        )
        guard
          let storedIdentity = try Row.fetchOne(
            database,
            sql: """
              SELECT account_uid, entity_type, entity_uid, base_revision, operation, payload_json
              FROM account_change_log WHERE operation_uid = ?
              """,
            arguments: [operationUID]
          )
        else {
          throw SDKError(code: .storageFailure, message: "account outbox insert failed")
        }
        let storedAccountUID: String = storedIdentity["account_uid"]
        let storedEntityType: String = storedIdentity["entity_type"]
        let storedEntityUID: String = storedIdentity["entity_uid"]
        let storedBaseRevision: Int64 = storedIdentity["base_revision"]
        let storedOperation: String = storedIdentity["operation"]
        let storedPayload: String? = storedIdentity["payload_json"]
        guard storedAccountUID == record.accountUID,
          storedEntityType == "credential_record",
          storedEntityUID == record.credentialUID,
          storedBaseRevision == baseRevision,
          storedOperation == operation,
          storedPayload == payload
        else {
          throw SDKError(code: .conflict, message: "operation UID was already used")
        }
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "credential record transaction failed")
    }
  }

  /// Lists pending operations without returning credential payloads to diagnostics surfaces.
  public func pendingOutbox(accountUID: String) async throws -> [AccountOutboxRecord] {
    do {
      return try await database.read { database in
        let rows = try Row.fetchAll(
          database,
          sql: """
            SELECT seq, operation_uid, account_uid, entity_type, entity_uid,
                   base_revision, operation, retry_count
            FROM account_change_log
            WHERE account_uid = ? AND uploaded_at_ms IS NULL
            ORDER BY seq
            """,
          arguments: [accountUID]
        )
        return rows.map { row in
          AccountOutboxRecord(
            sequence: row["seq"],
            operationUID: row["operation_uid"],
            accountUID: row["account_uid"],
            entityType: row["entity_type"],
            entityUID: row["entity_uid"],
            baseRevision: row["base_revision"],
            operation: row["operation"],
            retryCount: row["retry_count"]
          )
        }
      }
    } catch {
      throw SDKError(code: .storageFailure, message: "account outbox read failed")
    }
  }

  private static func credentialKind(_ kind: CredentialKind) -> String {
    switch kind {
    case .password: "password"
    case .oauthToken: "oauth_token"
    case .apiToken: "api_token"
    case .cookie: "cookie"
    case .keyPair: "key_pair"
    case .unknown(let value): value
    }
  }

  private static func canonicalPlaintextPayload(
    _ payload: String?,
    kind: CredentialKind,
    tombstone: Bool
  ) throws -> String? {
    if tombstone {
      guard payload == nil else {
        throw SDKError(code: .invalidConfiguration, message: "credential tombstone is invalid")
      }
      return nil
    }
    guard let payload else {
      throw SDKError(code: .invalidConfiguration, message: "credential payload is missing")
    }
    let decoded = try CredentialPayload(jsonString: payload)
    guard decoded.credentialKind == kind else {
      throw SDKError(code: .invalidConfiguration, message: "credential kind does not match payload")
    }
    return try decoded.canonicalJSONString()
  }
}

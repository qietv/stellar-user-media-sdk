import Foundation
import GRDB
import StellarCore
import StellarRemoteMedia

extension AccountStore {
  /// Upserts a source configuration and enqueues its complete sync operation atomically.
  public func saveMediaSourceConfig(
    _ config: MediaSourceConfig,
    baseRevision: Int64,
    operationUID suppliedOperationUID: String? = nil
  ) async throws {
    guard baseRevision >= 0 else {
      throw SDKError(code: .invalidConfiguration, message: "base revision must not be negative")
    }
    let operationUID =
      suppliedOperationUID
      ?? uuidGenerator.makeUUID().uuidString.lowercased()
    guard !operationUID.isEmpty, !operationUID.contains("\0"),
      Self.supported(config.kind),
      Self.supported(config.connectionMode),
      Self.supported(config.credentialMode),
      config.schemaVersion == 1
    else {
      throw SDKError(code: .invalidConfiguration, message: "media source config is unsupported")
    }

    let encoder = Self.canonicalEncoder()
    let payload = try Self.encode(config, using: encoder, label: "media source config")
    let endpoint = try Self.encode(config.endpoint, using: encoder, label: "source endpoint")
    let includedPaths = try Self.encode(
      config.includedPaths,
      using: encoder,
      label: "included paths"
    )
    let excludedPaths = try Self.encode(
      config.excludedPaths,
      using: encoder,
      label: "excluded paths"
    )
    let scanPolicy = try Self.encode(config.scanPolicy, using: encoder, label: "scan policy")
    let metadataPolicy = try Self.encode(
      config.metadataPolicy,
      using: encoder,
      label: "metadata policy"
    )
    let capabilities = try Self.encode(
      config.capabilities,
      using: encoder,
      label: "source capabilities"
    )
    let operation = config.deletedAtMilliseconds == nil ? "upsert" : "delete"

    do {
      try await database.write { database in
        if let existingAccountUID = try String.fetchOne(
          database,
          sql: "SELECT account_uid FROM media_source_config WHERE uid = ?",
          arguments: [config.sourceUID]
        ) {
          guard existingAccountUID == config.accountUID else {
            throw SDKError(
              code: .conflict,
              message: "media source config cannot move between accounts"
            )
          }
        }
        try database.execute(
          sql: """
            INSERT INTO media_source_config(
              uid, account_uid, kind, display_name, endpoint_json, root_path,
              included_paths_json, excluded_paths_json, scan_policy_json,
              metadata_policy_json, connection_mode, credential_mode, credential_uid,
              capabilities_json, revision, base_revision, updated_at_ms, deleted_at_ms,
              schema_version
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(uid) DO UPDATE SET
              account_uid = excluded.account_uid,
              kind = excluded.kind,
              display_name = excluded.display_name,
              endpoint_json = excluded.endpoint_json,
              root_path = excluded.root_path,
              included_paths_json = excluded.included_paths_json,
              excluded_paths_json = excluded.excluded_paths_json,
              scan_policy_json = excluded.scan_policy_json,
              metadata_policy_json = excluded.metadata_policy_json,
              connection_mode = excluded.connection_mode,
              credential_mode = excluded.credential_mode,
              credential_uid = excluded.credential_uid,
              capabilities_json = excluded.capabilities_json,
              revision = excluded.revision,
              base_revision = excluded.base_revision,
              updated_at_ms = excluded.updated_at_ms,
              deleted_at_ms = excluded.deleted_at_ms,
              schema_version = excluded.schema_version
            """,
          arguments: [
            config.sourceUID, config.accountUID, config.kind.wireValue, config.displayName,
            endpoint, config.rootPath, includedPaths, excludedPaths, scanPolicy, metadataPolicy,
            config.connectionMode.wireValue, config.credentialMode.wireValue,
            config.credentialUID, capabilities, config.revision, baseRevision,
            config.updatedAtMilliseconds, config.deletedAtMilliseconds, config.schemaVersion,
          ]
        )
        try database.execute(
          sql: """
            INSERT INTO account_change_log(
              operation_uid, account_uid, entity_type, entity_uid, base_revision,
              operation, payload_json, modified_at_ms
            ) VALUES (?, ?, 'media_source_config', ?, ?, ?, ?, ?)
            ON CONFLICT(operation_uid) DO NOTHING
            """,
          arguments: [
            operationUID, config.accountUID, config.sourceUID, baseRevision,
            operation, payload, config.updatedAtMilliseconds,
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
        guard storedAccountUID == config.accountUID,
          storedEntityType == "media_source_config",
          storedEntityUID == config.sourceUID,
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
      throw SDKError(code: .storageFailure, message: "media source config transaction failed")
    }
  }

  /// Reads one account's configurations in stable source UID order.
  public func mediaSourceConfigs(
    accountUID: String,
    includingDeleted: Bool = false
  ) async throws -> [MediaSourceConfig] {
    guard !accountUID.isEmpty, !accountUID.contains("\0") else {
      throw SDKError(code: .invalidConfiguration, message: "account UID is invalid")
    }
    do {
      return try await database.read { database in
        let rows = try Row.fetchAll(
          database,
          sql: """
            SELECT uid, account_uid, kind, display_name, endpoint_json, root_path,
                   included_paths_json, excluded_paths_json, scan_policy_json,
                   metadata_policy_json, connection_mode, credential_mode, credential_uid,
                   capabilities_json, revision, updated_at_ms, deleted_at_ms, schema_version
            FROM media_source_config
            WHERE account_uid = ? AND (? OR deleted_at_ms IS NULL)
            ORDER BY uid
            """,
          arguments: [accountUID, includingDeleted]
        )
        return try rows.map(Self.decodeConfig)
      }
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "media source config read failed")
    }
  }

  private static func decodeConfig(_ row: Row) throws -> MediaSourceConfig {
    let decoder = JSONDecoder()
    let endpointJSON: String = row["endpoint_json"]
    let includedPathsJSON: String = row["included_paths_json"]
    let excludedPathsJSON: String = row["excluded_paths_json"]
    let scanPolicyJSON: String = row["scan_policy_json"]
    let metadataPolicyJSON: String = row["metadata_policy_json"]
    let capabilitiesJSON: String = row["capabilities_json"]
    do {
      return try MediaSourceConfig(
        sourceUID: row["uid"],
        accountUID: row["account_uid"],
        kind: try Self.decodeEnum(MediaSourceKind.self, value: row["kind"], decoder: decoder),
        displayName: row["display_name"],
        endpoint: try decoder.decode(MediaSourceEndpoint.self, from: Data(endpointJSON.utf8)),
        rootPath: row["root_path"],
        includedPaths: try decoder.decode([String].self, from: Data(includedPathsJSON.utf8)),
        excludedPaths: try decoder.decode([String].self, from: Data(excludedPathsJSON.utf8)),
        scanPolicy: try decoder.decode(
          MediaSourceScanPolicy.self,
          from: Data(scanPolicyJSON.utf8)
        ),
        metadataPolicy: try decoder.decode(
          MediaSourceMetadataPolicy.self,
          from: Data(metadataPolicyJSON.utf8)
        ),
        connectionMode: try Self.decodeEnum(
          MediaSourceConnectionMode.self,
          value: row["connection_mode"],
          decoder: decoder
        ),
        credentialMode: try Self.decodeEnum(
          MediaSourceCredentialMode.self,
          value: row["credential_mode"],
          decoder: decoder
        ),
        credentialUID: row["credential_uid"],
        capabilities: try decoder.decode(
          [MediaSourceCapability].self,
          from: Data(capabilitiesJSON.utf8)
        ),
        revision: row["revision"],
        updatedAtMilliseconds: row["updated_at_ms"],
        deletedAtMilliseconds: row["deleted_at_ms"],
        schemaVersion: row["schema_version"]
      )
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "stored media source config is invalid")
    }
  }

  private static func decodeEnum<Value: Decodable>(
    _: Value.Type,
    value: String,
    decoder: JSONDecoder
  ) throws -> Value {
    let data = try JSONEncoder().encode(value)
    return try decoder.decode(Value.self, from: data)
  }

  private static func encode<Value: Encodable>(
    _ value: Value,
    using encoder: JSONEncoder,
    label: String
  ) throws -> String {
    do {
      return String(decoding: try encoder.encode(value), as: UTF8.self)
    } catch {
      throw SDKError(code: .parseFailure, message: "\(label) encoding failed")
    }
  }

  private static func canonicalEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  private static func supported(_ kind: MediaSourceKind) -> Bool {
    if case .unknown = kind { return false }
    return true
  }

  private static func supported(_ mode: MediaSourceConnectionMode) -> Bool {
    if case .unknown = mode { return false }
    return true
  }

  private static func supported(_ mode: MediaSourceCredentialMode) -> Bool {
    if case .unknown = mode { return false }
    return true
  }
}

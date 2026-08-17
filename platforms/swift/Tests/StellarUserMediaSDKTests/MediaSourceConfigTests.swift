import Foundation
import GRDB
import StellarCore
import StellarRemoteMedia
import StellarStorage
import Testing

@Suite("Synchronized media source configuration")
struct MediaSourceConfigTests {
  @Test("Shared fixture canonicalizes paths and preserves future capabilities")
  func sharedFixture() throws {
    let fixture = try loadFixture()

    #expect(fixture.schemaVersion == 1)
    #expect(fixture.active.includedPaths == fixture.expected.canonicalIncludedPaths)
    #expect(
      fixture.active.capabilities.map(capabilityWireValue)
        == fixture.expected.canonicalCapabilities
    )
    #expect(fixture.active.capabilities.contains(.unknown("future_delta")))

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let encoded = try encoder.encode(fixture.active)
    let roundTrip = try JSONDecoder().decode(MediaSourceConfig.self, from: encoded)
    #expect(roundTrip == fixture.active)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["source_uid"] as? String == "source-1")
    #expect(object["updated_at_ms"] as? Int64 == 1_700_000_000_000)

    #expect(fixture.active.description == "<MediaSourceConfig redacted>")
    #expect(!fixture.active.description.contains("nas.example.test"))
    #expect(!fixture.active.endpoint.description.contains("nas.example.test"))
  }

  @Test("Invalid endpoint and credential combinations fail closed")
  func invalidConfiguration() throws {
    #expect(throws: SDKError.self) {
      try MediaSourceEndpoint(
        scheme: "smb",
        host: "alice@nas.example.test",
        port: 445,
        usesTLS: false
      )
    }
    #expect(throws: SDKError.self) {
      try MediaSourceEndpoint(
        scheme: "smb",
        host: "nas\ninternal.example.test",
        port: 445,
        usesTLS: false
      )
    }
    #expect(throws: SDKError.self) {
      try makeConfig(credentialMode: .synced, credentialUID: nil)
    }
    #expect(throws: SDKError.self) {
      try makeConfig(credentialMode: .none, credentialUID: "credential-1")
    }
    #expect(throws: SDKError.self) {
      try makeConfig(kind: .unknown(""), credentialMode: .none, credentialUID: nil)
    }
  }

  @Test("Config rows and idempotent outbox operations commit atomically")
  func configOutbox() async throws {
    let fixture = try loadFixture()
    let context = try await makeStoreContext(label: "round-trip")
    defer { try? FileManager.default.removeItem(at: context.directory) }

    try await context.store.saveMediaSourceConfig(
      fixture.active,
      baseRevision: 0,
      operationUID: "operation-1"
    )
    try await context.store.saveMediaSourceConfig(
      fixture.active,
      baseRevision: 0,
      operationUID: "operation-1"
    )

    var configs = try await context.store.mediaSourceConfigs(accountUID: "account-1")
    var pending = try await context.store.pendingOutbox(accountUID: "account-1")
    #expect(configs == [fixture.active])
    #expect(pending.count == 1)
    #expect(pending[0].entityType == "media_source_config")
    #expect(pending[0].operation == "upsert")

    try await context.store.saveMediaSourceConfig(
      fixture.tombstone,
      baseRevision: 1,
      operationUID: "operation-2"
    )
    configs = try await context.store.mediaSourceConfigs(accountUID: "account-1")
    pending = try await context.store.pendingOutbox(accountUID: "account-1")
    #expect(configs.isEmpty)
    #expect(
      try await context.store.mediaSourceConfigs(
        accountUID: "account-1",
        includingDeleted: true
      ) == [fixture.tombstone]
    )
    #expect(pending.map(\.operation) == fixture.expected.operations)
    #expect(pending.map(\.baseRevision) == [0, 1])

    let queue = try DatabaseQueue(path: context.databaseURL.path)
    try await queue.write { database in
      try database.execute(sql: "DELETE FROM media_source_config WHERE uid = 'source-1'")
    }
    let outboxCount = try await queue.read { database in
      try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM account_change_log")
    }
    #expect(outboxCount == 2)
  }

  @Test("Operation UID reuse and unsupported source kinds roll back")
  func atomicFailures() async throws {
    let fixture = try loadFixture()
    let context = try await makeStoreContext(label: "conflict")
    defer { try? FileManager.default.removeItem(at: context.directory) }
    try await context.store.saveMediaSourceConfig(
      fixture.active,
      baseRevision: 0,
      operationUID: "operation-1"
    )
    let changed = try makeConfig(displayName: "Changed NAS")

    do {
      try await context.store.saveMediaSourceConfig(
        changed,
        baseRevision: 1,
        operationUID: "operation-1"
      )
      Issue.record("Expected operation UID conflict")
    } catch let error as SDKError {
      #expect(error.code == .conflict)
    }
    #expect(
      try await context.store.mediaSourceConfigs(accountUID: "account-1") == [fixture.active]
    )

    let moved = try makeConfig(accountUID: "account-2")
    do {
      try await context.store.saveMediaSourceConfig(
        moved,
        baseRevision: 1,
        operationUID: "operation-move"
      )
      Issue.record("Expected account boundary conflict")
    } catch let error as SDKError {
      #expect(error.code == .conflict)
    }
    #expect(try await context.store.pendingOutbox(accountUID: "account-2").isEmpty)

    let credential = CredentialRecord(
      credentialUID: "credential-collision",
      accountUID: "account-1",
      sourceUID: "source-1",
      kind: .password,
      payloadJSON:
        #"{"auth_type":"username_password","password":"fixture-password","schema_version":1,"username":"alice"}"#,
      revision: 1,
      updatedAtMilliseconds: 1_700_000_000_000
    )
    do {
      try await context.store.saveCredentialRecord(
        credential,
        baseRevision: 0,
        operationUID: "operation-1"
      )
      Issue.record("Expected cross-entity operation UID conflict")
    } catch let error as SDKError {
      #expect(error.code == .conflict)
    }

    let futureKind = try makeConfig(
      sourceUID: "source-future",
      kind: .unknown("future_source"),
      credentialMode: .none,
      credentialUID: nil
    )
    do {
      try await context.store.saveMediaSourceConfig(futureKind, baseRevision: 0)
      Issue.record("Expected unsupported source kind")
    } catch let error as SDKError {
      #expect(error.code == .invalidConfiguration)
    }
    #expect(try await context.store.pendingOutbox(accountUID: "account-1").count == 1)
    let queue = try DatabaseQueue(path: context.databaseURL.path)
    let credentialCount = try await queue.read { database in
      try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM credential_record")
    }
    #expect(credentialCount == 0)
  }

  private func loadFixture() throws -> SourceConfigFixture {
    let fixtureURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("specs/fixtures/remote-media/source-config-sync-v1.json")
    return try JSONDecoder().decode(
      SourceConfigFixture.self,
      from: Data(contentsOf: fixtureURL)
    )
  }

  private func makeStoreContext(label: String) async throws -> StoreContext {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "stellar-source-config-\(label)-\(UUID().uuidString)",
      isDirectory: true
    )
    let databaseURL = directory.appendingPathComponent("account.sqlite")
    let database = try await StorageDatabase.open(kind: .account, at: databaseURL)
    return StoreContext(
      directory: directory,
      databaseURL: databaseURL,
      store: try AccountStore(database: database)
    )
  }

  private func makeConfig(
    sourceUID: String = "source-1",
    accountUID: String = "account-1",
    kind: MediaSourceKind = .smb,
    displayName: String = "Media NAS",
    credentialMode: MediaSourceCredentialMode = .synced,
    credentialUID: String? = "credential-1"
  ) throws -> MediaSourceConfig {
    try MediaSourceConfig(
      sourceUID: sourceUID,
      accountUID: accountUID,
      kind: kind,
      displayName: displayName,
      endpoint: try MediaSourceEndpoint(
        scheme: "smb",
        host: "nas.example.test",
        port: 445,
        usesTLS: false
      ),
      rootPath: "Media",
      scanPolicy: try MediaSourceScanPolicy(),
      metadataPolicy: try MediaSourceMetadataPolicy(),
      credentialMode: credentialMode,
      credentialUID: credentialUID,
      revision: 1,
      updatedAtMilliseconds: 1_700_000_000_000
    )
  }

  private func capabilityWireValue(_ capability: MediaSourceCapability) -> String {
    switch capability {
    case .list: "list"
    case .read: "read"
    case .rangeRead: "range_read"
    case .changeCursor: "change_cursor"
    case .serverSearch: "server_search"
    case .stableID: "stable_id"
    case .unknown(let value): value
    }
  }
}

private struct SourceConfigFixture: Decodable {
  let schemaVersion: Int
  let active: MediaSourceConfig
  let tombstone: MediaSourceConfig
  let expected: SourceConfigExpected

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case active
    case tombstone
    case expected
  }
}

private struct SourceConfigExpected: Decodable {
  let canonicalCapabilities: [String]
  let canonicalIncludedPaths: [String]
  let operations: [String]

  private enum CodingKeys: String, CodingKey {
    case canonicalCapabilities = "canonical_capabilities"
    case canonicalIncludedPaths = "canonical_included_paths"
    case operations
  }
}

private struct StoreContext {
  let directory: URL
  let databaseURL: URL
  let store: AccountStore
}

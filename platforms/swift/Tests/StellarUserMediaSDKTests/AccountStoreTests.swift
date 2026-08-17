import Foundation
import GRDB
import StellarCore
import StellarRemoteMedia
import StellarStorage
import Testing

@Suite("Account storage and transactional outbox", .serialized)
struct AccountStoreTests {
  @Test("Credential records and idempotent outbox operations commit together")
  func credentialRecordOutbox() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "stellar-account-store-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("account.sqlite")
    let database = try await StorageDatabase.open(kind: .account, at: url)
    let store = try AccountStore(database: database)
    let record = CredentialRecord(
      credentialUID: "credential-1",
      accountUID: "account-1",
      sourceUID: "source-1",
      kind: .password,
      payloadJSON:
        #"{"auth_type":"username_password","password":"secret","schema_version":1,"username":"alice"}"#,
      revision: 1,
      updatedAtMilliseconds: 1_700_000_000_000
    )

    try await store.saveCredentialRecord(
      record,
      baseRevision: 0,
      operationUID: "operation-1"
    )
    try await store.saveCredentialRecord(
      record,
      baseRevision: 0,
      operationUID: "operation-1"
    )
    var pending = try await store.pendingOutbox(accountUID: "account-1")

    #expect(pending.count == 1)
    #expect(pending[0].operationUID == "operation-1")
    #expect(pending[0].entityType == "credential_record")
    #expect(pending[0].operation == "upsert")

    let tombstone = CredentialRecord(
      credentialUID: record.credentialUID,
      accountUID: record.accountUID,
      sourceUID: record.sourceUID,
      kind: record.kind,
      payloadJSON: nil,
      revision: 2,
      updatedAtMilliseconds: 1_700_000_001_000,
      deletedAtMilliseconds: 1_700_000_001_000
    )
    try await store.saveCredentialRecord(
      tombstone,
      baseRevision: 1,
      operationUID: "operation-2"
    )
    pending = try await store.pendingOutbox(accountUID: "account-1")

    #expect(pending.map(\.operation) == ["upsert", "delete"])
    #expect(pending.map(\.baseRevision) == [0, 1])

    let queue = try DatabaseQueue(path: url.path)
    try await queue.write { database in
      try database.execute(
        sql: "DELETE FROM credential_record WHERE credential_uid = 'credential-1'"
      )
    }
    let outboxCount = try await queue.read { database in
      try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM account_change_log")
    }
    #expect(outboxCount == 2)
  }

  @Test("Reusing an operation UID for another credential record rolls back")
  func operationUIDConflict() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "stellar-account-conflict-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await StorageDatabase.open(
      kind: .account,
      at: directory.appendingPathComponent("account.sqlite")
    )
    let store = try AccountStore(database: database)
    let first = makeRecord(credentialUID: "credential-1")
    let second = makeRecord(credentialUID: "credential-2")

    try await store.saveCredentialRecord(first, baseRevision: 0, operationUID: "operation-1")
    await #expect(throws: SDKError.self) {
      try await store.saveCredentialRecord(
        second,
        baseRevision: 0,
        operationUID: "operation-1"
      )
    }

    let pending = try await store.pendingOutbox(accountUID: "account-1")
    #expect(pending.count == 1)
    #expect(pending[0].entityUID == "credential-1")
  }

  @Test("Unsupported future protection modes fail closed without an outbox write")
  func unsupportedProtectionMode() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "stellar-account-protection-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await StorageDatabase.open(
      kind: .account,
      at: directory.appendingPathComponent("account.sqlite")
    )
    let store = try AccountStore(database: database)
    let record = CredentialRecord(
      credentialUID: "credential-1",
      accountUID: "account-1",
      sourceUID: "source-1",
      kind: .password,
      protectionMode: .serverEncrypted,
      payloadJSON: nil,
      algorithm: "future_algorithm",
      keyVersion: 1,
      nonceBase64: "bm9uY2U=",
      protectedPayloadBase64: "cHJvdGVjdGVk",
      authenticatedDataVersion: 1,
      revision: 1,
      updatedAtMilliseconds: 1_700_000_000_000
    )

    do {
      try await store.saveCredentialRecord(record, baseRevision: 0)
      Issue.record("Expected an unsupported protection error")
    } catch let error as SDKError {
      #expect(error.code == .credentialProtectionUnsupported)
    }

    #expect(try await store.pendingOutbox(accountUID: "account-1").isEmpty)
  }

  private func makeRecord(credentialUID: String) -> CredentialRecord {
    CredentialRecord(
      credentialUID: credentialUID,
      accountUID: "account-1",
      sourceUID: "source-1",
      kind: .password,
      payloadJSON:
        #"{"auth_type":"username_password","password":"secret","schema_version":1,"username":"alice"}"#,
      revision: 1,
      updatedAtMilliseconds: 1_700_000_000_000
    )
  }
}

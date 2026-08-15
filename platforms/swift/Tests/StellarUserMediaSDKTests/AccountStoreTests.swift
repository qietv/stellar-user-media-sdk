import Foundation
import GRDB
import StellarCore
import StellarRemoteMedia
import StellarStorage
import Testing

@Suite("Account storage and transactional outbox", .serialized)
struct AccountStoreTests {
  @Test("Credential envelopes and idempotent outbox operations commit together")
  func credentialEnvelopeOutbox() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "stellar-account-store-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("account.sqlite")
    let database = try await StorageDatabase.open(kind: .account, at: url)
    let store = try AccountStore(database: database)
    let envelope = EncryptedCredentialEnvelope(
      credentialUID: "credential-1",
      accountUID: "account-1",
      sourceUID: "source-1",
      kind: .unknown("future_credential"),
      keyVersion: 1,
      nonceBase64: "bm9uY2UtMTIzNA==",
      ciphertextBase64: "Y2lwaGVydGV4dC1vbmx5",
      revision: 1,
      updatedAtMilliseconds: 1_700_000_000_000
    )

    try await store.saveCredentialEnvelope(
      envelope,
      baseRevision: 0,
      operationUID: "operation-1"
    )
    try await store.saveCredentialEnvelope(
      envelope,
      baseRevision: 0,
      operationUID: "operation-1"
    )
    var pending = try await store.pendingOutbox(accountUID: "account-1")

    #expect(pending.count == 1)
    #expect(pending[0].operationUID == "operation-1")
    #expect(pending[0].entityType == "credential_envelope")
    #expect(pending[0].operation == "upsert")

    let tombstone = EncryptedCredentialEnvelope(
      credentialUID: envelope.credentialUID,
      accountUID: envelope.accountUID,
      sourceUID: envelope.sourceUID,
      kind: envelope.kind,
      keyVersion: envelope.keyVersion,
      nonceBase64: envelope.nonceBase64,
      ciphertextBase64: envelope.ciphertextBase64,
      revision: 2,
      updatedAtMilliseconds: 1_700_000_001_000,
      deletedAtMilliseconds: 1_700_000_001_000
    )
    try await store.saveCredentialEnvelope(
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
        sql: "DELETE FROM credential_envelope WHERE credential_uid = 'credential-1'"
      )
    }
    let outboxCount = try await queue.read { database in
      try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM account_change_log")
    }
    #expect(outboxCount == 2)
  }

  @Test("Reusing an operation UID for another envelope rolls back")
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
    let first = makeEnvelope(credentialUID: "credential-1")
    let second = makeEnvelope(credentialUID: "credential-2")

    try await store.saveCredentialEnvelope(first, baseRevision: 0, operationUID: "operation-1")
    await #expect(throws: SDKError.self) {
      try await store.saveCredentialEnvelope(
        second,
        baseRevision: 0,
        operationUID: "operation-1"
      )
    }

    let pending = try await store.pendingOutbox(accountUID: "account-1")
    #expect(pending.count == 1)
    #expect(pending[0].entityUID == "credential-1")
  }

  private func makeEnvelope(credentialUID: String) -> EncryptedCredentialEnvelope {
    EncryptedCredentialEnvelope(
      credentialUID: credentialUID,
      accountUID: "account-1",
      sourceUID: "source-1",
      kind: .password,
      keyVersion: 1,
      nonceBase64: "bm9uY2UtMTIzNA==",
      ciphertextBase64: "Y2lwaGVydGV4dC1vbmx5",
      revision: 1,
      updatedAtMilliseconds: 1_700_000_000_000
    )
  }
}

import Foundation
import GRDB
import StellarCore
import StellarRemoteMedia
import StellarStorage
import Testing

@Suite("Restricted credential payloads")
struct CredentialPayloadTests {
  @Test("Shared fixture accepts known shapes and emits canonical JSON")
  func validFixture() throws {
    let fixture = try loadFixture()
    #expect(fixture.schemaVersion == 1)

    for vector in fixture.valid {
      let payload = try CredentialPayload(jsonString: vector.payloadJSON)
      #expect(payload.credentialKind == vector.kind)
      #expect(try payload.canonicalJSONString() == vector.canonicalJSON)
      #expect(payload.description == "<CredentialPayload redacted>")
      #expect(!payload.description.contains("fixture"))
      for cookie in payload.cookies ?? [] {
        #expect(cookie.description == "<CredentialCookie redacted>")
        #expect(!cookie.description.contains(cookie.name))
        #expect(!cookie.description.contains(cookie.value))
      }
    }
  }

  @Test("Shared fixture rejects unknown, mixed, duplicate, and malformed payloads")
  func invalidFixture() throws {
    let fixture = try loadFixture()

    for vector in fixture.invalid {
      do {
        _ = try CredentialPayload(jsonString: vector.payloadJSON)
        Issue.record("Expected invalid credential payload: \(vector.name)")
      } catch let error as SDKError {
        #expect(error.code == .invalidConfiguration)
        #expect(!error.message.contains("fixture"))
      }
    }
    #expect(throws: SDKError.self) {
      try CredentialPayload(
        authenticationType: .apiToken,
        token: String(repeating: "x", count: 32_769)
      )
    }
  }

  @Test("Account repository accepts every v1 shape and enforces record kind")
  func accountRepositoryValidation() async throws {
    let fixture = try loadFixture()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "stellar-credential-payload-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("account.sqlite")
    let database = try await StorageDatabase.open(kind: .account, at: databaseURL)
    let store = try AccountStore(database: database)

    for (index, vector) in fixture.valid.enumerated() {
      let record = CredentialRecord(
        credentialUID: "credential-\(index)",
        accountUID: "account-1",
        sourceUID: "source-\(index)",
        kind: vector.kind,
        payloadJSON: vector.payloadJSON,
        revision: 1,
        updatedAtMilliseconds: 1_700_000_000_000
      )
      try await store.saveCredentialRecord(
        record,
        baseRevision: 0,
        operationUID: "operation-\(index)"
      )
    }
    #expect(try await store.pendingOutbox(accountUID: "account-1").count == fixture.valid.count)
    let queue = try DatabaseQueue(path: databaseURL.path)
    let storedPayloads = try await queue.read { database in
      try String.fetchAll(
        database,
        sql: "SELECT payload_json FROM credential_record ORDER BY credential_uid"
      )
    }
    #expect(storedPayloads == fixture.valid.map(\.canonicalJSON))

    let oauthVector = try #require(fixture.valid.first(where: { $0.kind == .oauthToken }))
    let mismatched = CredentialRecord(
      credentialUID: "credential-mismatch",
      accountUID: "account-1",
      sourceUID: "source-mismatch",
      kind: .password,
      payloadJSON: oauthVector.payloadJSON,
      revision: 1,
      updatedAtMilliseconds: 1_700_000_000_000
    )
    do {
      try await store.saveCredentialRecord(mismatched, baseRevision: 0)
      Issue.record("Expected credential kind mismatch")
    } catch let error as SDKError {
      #expect(error.code == .invalidConfiguration)
    }
    #expect(try await store.pendingOutbox(accountUID: "account-1").count == fixture.valid.count)

    let moved = CredentialRecord(
      credentialUID: "credential-0",
      accountUID: "account-2",
      sourceUID: "source-0",
      kind: fixture.valid[0].kind,
      payloadJSON: fixture.valid[0].payloadJSON,
      revision: 2,
      updatedAtMilliseconds: 1_700_000_001_000
    )
    do {
      try await store.saveCredentialRecord(
        moved,
        baseRevision: 1,
        operationUID: "operation-move"
      )
      Issue.record("Expected credential account boundary conflict")
    } catch let error as SDKError {
      #expect(error.code == .conflict)
    }
    #expect(try await store.pendingOutbox(accountUID: "account-2").isEmpty)
  }

  private func loadFixture() throws -> CredentialPayloadFixture {
    let fixtureURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("specs/fixtures/security/credential-payload-v1.json")
    return try JSONDecoder().decode(
      CredentialPayloadFixture.self,
      from: Data(contentsOf: fixtureURL)
    )
  }
}

private struct CredentialPayloadFixture: Decodable {
  let schemaVersion: Int
  let valid: [ValidCredentialPayloadVector]
  let invalid: [InvalidCredentialPayloadVector]

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case valid
    case invalid
  }
}

private struct ValidCredentialPayloadVector: Decodable {
  let kind: CredentialKind
  let payloadJSON: String
  let canonicalJSON: String

  private enum CodingKeys: String, CodingKey {
    case kind
    case payloadJSON = "payload_json"
    case canonicalJSON = "canonical_json"
  }
}

private struct InvalidCredentialPayloadVector: Decodable {
  let name: String
  let payloadJSON: String

  private enum CodingKeys: String, CodingKey {
    case name
    case payloadJSON = "payload_json"
  }
}

import Foundation
import StellarCore
import StellarMediaLibrary
import StellarRemoteMedia
import Testing

@Suite("Shared contract models")
struct ContractModelTests {
  @Test("SDK errors use snake_case wire keys")
  func errorWireFormat() throws {
    let error = SDKError(
      code: .rateLimited,
      message: "try later",
      retryAfterMilliseconds: 1_000,
      traceID: "trace-1"
    )

    let object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(error)) as? [String: Any]
    )
    #expect(object["code"] as? String == "rate_limited")
    #expect(object["retry_after_ms"] as? Int == 1_000)
    #expect(object["trace_id"] as? String == "trace-1")
  }

  @Test("Credential records encode plaintext explicitly and redact descriptions")
  func credentialRecordWireFormat() throws {
    let record = CredentialRecord(
      credentialUID: "credential-1",
      accountUID: "account-1",
      sourceUID: "source-1",
      kind: .password,
      payloadJSON:
        #"{"auth_type":"username_password","password":"secret","schema_version":1,"username":"alice"}"#,
      revision: 3,
      updatedAtMilliseconds: 1_700_000_000_000
    )

    let object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]
    )
    #expect(object["credential_uid"] as? String == "credential-1")
    #expect(object["protection_mode"] as? String == "plaintext")
    #expect((object["payload_json"] as? String)?.contains("secret") == true)
    #expect(record.description.contains("secret") == false)
    #expect(record.description.contains("<redacted>"))
  }

  @Test("Unknown credential kinds survive a round trip")
  func unknownCredentialKind() throws {
    let encoded = Data(#""future_credential""#.utf8)
    let decoded = try JSONDecoder().decode(CredentialKind.self, from: encoded)
    #expect(decoded == .unknown("future_credential"))
    #expect(try JSONEncoder().encode(decoded) == encoded)
  }

  @Test("Unknown public enum values degrade safely")
  func unknownPublicEnums() throws {
    let unknownError = try JSONDecoder().decode(
      SDKErrorCode.self, from: Data(#""future_error""#.utf8))
    let unknownMedia = try JSONDecoder().decode(
      ParsedMediaKind.self, from: Data(#""future_media""#.utf8))

    #expect(unknownError == .unknown)
    #expect(unknownMedia == .unknown)
  }
}

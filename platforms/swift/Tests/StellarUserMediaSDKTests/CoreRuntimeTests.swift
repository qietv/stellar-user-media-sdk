import Foundation
import StellarCore
import Testing

@Suite("Core runtime dependencies")
struct CoreRuntimeTests {
  @Test("Runtime dependencies accept deterministic clocks and UUID generators")
  func injectableRuntimeDependencies() {
    let expectedUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
    let dependencies = SDKRuntimeDependencies(
      clock: FixedClock(now: 1_700_000_000_123),
      uuidGenerator: FixedUUIDGenerator(value: expectedUUID),
      logger: NoopSDKLogger(),
      cancellationChecker: NeverCancelledChecker()
    )

    #expect(dependencies.clock.nowMilliseconds() == 1_700_000_000_123)
    #expect(dependencies.uuidGenerator.makeUUID() == expectedUUID)
    #expect(dependencies.cancellationChecker.isCancelled == false)
  }

  @Test("Redaction covers URLs, headers, paths, usernames, passwords, and tokens")
  func structuredRedaction() {
    let redactor = SensitiveDataRedactor()
    let url = redactor.redact(
      url: "https://alice:hunter2@example.com/private/movies?token=abc123&mode=read#secret")
    let headers = redactor.redact(headers: [
      "Authorization": "Bearer token-value",
      "X-API-Key": "api-key-value",
      "Accept": "application/json",
    ])

    #expect(url.contains("example.com"))
    #expect(url.contains("REDACTED_PATH"))
    #expect(url.contains("mode=read"))
    #expect(url.contains("alice") == false)
    #expect(url.contains("hunter2") == false)
    #expect(url.contains("abc123") == false)
    #expect(url.contains("private") == false)
    #expect(headers["Authorization"] == SensitiveDataRedactor.placeholder)
    #expect(headers["X-API-Key"] == SensitiveDataRedactor.placeholder)
    #expect(headers["Accept"] == "application/json")
    #expect(redactor.redact(path: "/Users/alice/Movies/private.mkv") == "<redacted-path>")
    #expect(redactor.redact("alice", as: .username) == "<redacted>")
    #expect(redactor.redact("hunter2", as: .password) == "<redacted>")
    #expect(redactor.redact("token-value", as: .token) == "<redacted>")
  }

  @Test("Unstructured redaction protects diagnostics and command arguments")
  func unstructuredRedaction() {
    let redactor = SensitiveDataRedactor()
    let message = redactor.redact(
      message:
        "Authorization: Bearer abc\nusername=alice password hunter2 refresh_token='token-value'"
    )

    #expect(message.contains("abc") == false)
    #expect(message.contains("alice") == false)
    #expect(message.contains("hunter2") == false)
    #expect(message.contains("token-value") == false)
    #expect(redactor.redact(commandLineArgument: "/private/media/movie.mkv") == "<redacted-path>")
    #expect(
      redactor.redact(commandLineArgument: "--password=hunter2").contains("hunter2") == false)
  }

  @Test("Logger emits only redacted records")
  func redactingLogger() throws {
    let records = LockedBox<[SDKLogRecord]>([])
    let logger = RedactingSDKLogger(clock: FixedClock(now: 42)) { record in
      records.withValue { $0.append(record) }
    }

    logger.log(
      SDKLogEvent(
        level: .warning,
        category: "connector",
        message: "password=hunter2",
        metadata: [
          "url": SDKLogMetadataValue(
            "smb://alice:hunter2@nas.local/private/movie.mkv", privacy: .url),
          "path": SDKLogMetadataValue("/private/movie.mkv", privacy: .path),
          "user": SDKLogMetadataValue("alice", privacy: .username),
          "token": SDKLogMetadataValue("token-value", privacy: .token),
        ]
      ))

    let record = try #require(records.value.first)
    let encoded = try String(decoding: JSONEncoder().encode(record), as: UTF8.self)
    #expect(record.timestampMilliseconds == 42)
    #expect(record.message == "password=<redacted>")
    #expect(record.metadata["path"] == "<redacted-path>")
    #expect(record.metadata["user"] == "<redacted>")
    #expect(record.metadata["token"] == "<redacted>")
    #expect(encoded.contains("hunter2") == false)
    #expect(encoded.contains("alice") == false)
    #expect(encoded.contains("token-value") == false)
    #expect(encoded.contains("private") == false)
  }

  @Test("Retry executor uses injected backoff and stops after success")
  func retryBackoff() async throws {
    let sleeps = LockedBox<[Int64]>([])
    let attempts = LockedBox<[Int]>([])
    let policy = try RetryPolicy(
      maxAttempts: 4,
      initialDelayMilliseconds: 10,
      multiplier: 2,
      maximumDelayMilliseconds: 25
    )
    let executor = RetryExecutor(
      clock: RecordingClock(now: 0, sleeps: sleeps),
      cancellationChecker: NeverCancelledChecker()
    )

    let value: String = try await executor.run(policy: policy) { attempt in
      attempts.withValue { $0.append(attempt) }
      if attempt < 3 {
        throw SDKError(code: .networkUnavailable, message: "offline")
      }
      return "connected"
    }

    #expect(value == "connected")
    #expect(attempts.value == [1, 2, 3])
    #expect(sleeps.value == [10, 20])
    #expect(policy.delayMilliseconds(afterAttempt: 3) == 25)
  }

  @Test("Cancellation prevents operation and retry execution")
  func retryCancellation() async {
    let attempts = LockedBox(0)
    let executor = RetryExecutor(
      clock: FixedClock(now: 0),
      cancellationChecker: FixedCancellationChecker(isCancelled: true)
    )

    await #expect(throws: SDKError.self) {
      let _: String = try await executor.run { _ in
        attempts.withValue { $0 += 1 }
        return "unexpected"
      }
    }
    #expect(attempts.value == 0)
  }

  @Test("Structured-concurrency cancellation maps to the SDK error contract")
  func structuredCancellationMapping() async {
    let executor = RetryExecutor(cancellationChecker: NeverCancelledChecker())

    await #expect(throws: SDKError.self) {
      let _: String = try await executor.run { _ in
        throw CancellationError()
      }
    }
  }

  @Test("Invalid retry policies fail without trapping")
  func invalidRetryPolicy() {
    #expect(throws: SDKError.self) {
      _ = try RetryPolicy(maxAttempts: 0, initialDelayMilliseconds: 10)
    }
    #expect(throws: SDKError.self) {
      _ = try RetryPolicy(maxAttempts: 2, initialDelayMilliseconds: -1)
    }
  }
}

private struct FixedClock: SDKClock {
  let now: Int64

  func nowMilliseconds() -> Int64 { now }

  func sleep(forMilliseconds _: Int64) async throws {}
}

private struct RecordingClock: SDKClock {
  let now: Int64
  let sleeps: LockedBox<[Int64]>

  func nowMilliseconds() -> Int64 { now }

  func sleep(forMilliseconds milliseconds: Int64) async throws {
    sleeps.withValue { $0.append(milliseconds) }
  }
}

private struct FixedUUIDGenerator: SDKUUIDGenerating {
  let value: UUID

  func makeUUID() -> UUID { value }
}

private struct FixedCancellationChecker: SDKCancellationChecking {
  let isCancelled: Bool
}

private final class LockedBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Value

  init(_ value: Value) {
    storage = value
  }

  var value: Value {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
    lock.lock()
    defer { lock.unlock() }
    return try body(&storage)
  }
}

import Foundation

/// Deterministic exponential-backoff policy. `maxAttempts` includes the first invocation.
public struct RetryPolicy: Equatable, Sendable {
  public let maxAttempts: Int
  public let initialDelayMilliseconds: Int64
  public let multiplier: Double
  public let maximumDelayMilliseconds: Int64

  public init(
    maxAttempts: Int,
    initialDelayMilliseconds: Int64,
    multiplier: Double = 2,
    maximumDelayMilliseconds: Int64 = 30_000
  ) throws {
    guard maxAttempts >= 1 else {
      throw SDKError(code: .invalidConfiguration, message: "maxAttempts must be at least one")
    }
    guard initialDelayMilliseconds >= 0, maximumDelayMilliseconds >= 0 else {
      throw SDKError(code: .invalidConfiguration, message: "retry delays must not be negative")
    }
    guard multiplier >= 1, multiplier.isFinite else {
      throw SDKError(
        code: .invalidConfiguration, message: "retry multiplier must be finite and at least one")
    }
    self.maxAttempts = maxAttempts
    self.initialDelayMilliseconds = initialDelayMilliseconds
    self.multiplier = multiplier
    self.maximumDelayMilliseconds = maximumDelayMilliseconds
  }

  /// The default for transient SDK transport failures: three total attempts, starting at 250 ms.
  public static let transient = RetryPolicy(
    uncheckedMaxAttempts: 3,
    initialDelayMilliseconds: 250,
    multiplier: 2,
    maximumDelayMilliseconds: 30_000
  )

  public func delayMilliseconds(afterAttempt attempt: Int) -> Int64 {
    guard attempt >= 1, initialDelayMilliseconds > 0, maximumDelayMilliseconds > 0 else { return 0 }
    let candidate = Double(initialDelayMilliseconds) * pow(multiplier, Double(attempt - 1))
    guard candidate.isFinite else { return maximumDelayMilliseconds }
    guard candidate < Double(maximumDelayMilliseconds) else { return maximumDelayMilliseconds }
    return min(maximumDelayMilliseconds, Int64(candidate.rounded(.down)))
  }

  private init(
    uncheckedMaxAttempts maxAttempts: Int,
    initialDelayMilliseconds: Int64,
    multiplier: Double,
    maximumDelayMilliseconds: Int64
  ) {
    self.maxAttempts = maxAttempts
    self.initialDelayMilliseconds = initialDelayMilliseconds
    self.multiplier = multiplier
    self.maximumDelayMilliseconds = maximumDelayMilliseconds
  }
}

/// Executes retryable work without hiding attempts, delays, or cancellation from tests.
public struct RetryExecutor: Sendable {
  private let clock: any SDKClock
  private let cancellationChecker: any SDKCancellationChecking

  public init(
    clock: any SDKClock = SystemSDKClock(),
    cancellationChecker: any SDKCancellationChecking = TaskCancellationChecker()
  ) {
    self.clock = clock
    self.cancellationChecker = cancellationChecker
  }

  public func run<Value: Sendable>(
    policy: RetryPolicy = .transient,
    shouldRetry: @escaping @Sendable (Error) -> Bool = RetryExecutor.isTransientSDKError,
    operation: @escaping @Sendable (_ attempt: Int) async throws -> Value
  ) async throws -> Value {
    var attempt = 1
    while true {
      try cancellationChecker.checkCancellation()
      do {
        return try await operation(attempt)
      } catch {
        try cancellationChecker.checkCancellation()
        if Self.isCancellation(error) {
          throw Self.sdkCancellationError(from: error)
        }
        guard attempt < policy.maxAttempts, shouldRetry(error) else {
          throw error
        }
        do {
          try await clock.sleep(forMilliseconds: policy.delayMilliseconds(afterAttempt: attempt))
        } catch {
          guard Self.isCancellation(error) else { throw error }
          throw Self.sdkCancellationError(from: error)
        }
        attempt += 1
      }
    }
  }

  public static func isTransientSDKError(_ error: Error) -> Bool {
    guard let error = error as? SDKError else { return false }
    return error.code == .networkUnavailable || error.code == .rateLimited
      || error.code == .remoteUnavailable
  }

  private static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    return (error as? SDKError)?.code == .cancelled
  }

  private static func sdkCancellationError(from error: Error) -> SDKError {
    if let error = error as? SDKError, error.code == .cancelled { return error }
    return SDKError(code: .cancelled, message: "operation cancelled")
  }
}

import Foundation

/// Supplies wall-clock epoch milliseconds and cancellation-aware delays.
public protocol SDKClock: Sendable {
  func nowMilliseconds() -> Int64
  func sleep(forMilliseconds milliseconds: Int64) async throws
}

/// The production clock used by SDK clients unless a deterministic clock is injected.
public struct SystemSDKClock: SDKClock {
  public init() {}

  public func nowMilliseconds() -> Int64 {
    Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
  }

  public func sleep(forMilliseconds milliseconds: Int64) async throws {
    guard milliseconds >= 0 else {
      throw SDKError(
        code: .invalidConfiguration,
        message: "sleep duration must not be negative"
      )
    }
    guard milliseconds > 0 else {
      await Task.yield()
      return
    }
    try await Task<Never, Never>.sleep(for: .milliseconds(milliseconds))
  }
}

/// Creates identifiers without coupling deterministic tests to Foundation's global UUID source.
public protocol SDKUUIDGenerating: Sendable {
  func makeUUID() -> UUID
}

/// The production UUID generator.
public struct SystemSDKUUIDGenerator: SDKUUIDGenerating {
  public init() {}

  public func makeUUID() -> UUID { UUID() }
}

/// Injectable runtime services shared by SDK coordinators.
public struct SDKRuntimeDependencies: Sendable {
  public let clock: any SDKClock
  public let uuidGenerator: any SDKUUIDGenerating
  public let logger: any SDKLogging
  public let cancellationChecker: any SDKCancellationChecking

  public init(
    clock: any SDKClock,
    uuidGenerator: any SDKUUIDGenerating,
    logger: any SDKLogging,
    cancellationChecker: any SDKCancellationChecking
  ) {
    self.clock = clock
    self.uuidGenerator = uuidGenerator
    self.logger = logger
    self.cancellationChecker = cancellationChecker
  }

  /// Runtime services suitable for production use. Logging is disabled until a sink is supplied.
  public static var live: SDKRuntimeDependencies {
    SDKRuntimeDependencies(
      clock: SystemSDKClock(),
      uuidGenerator: SystemSDKUUIDGenerator(),
      logger: NoopSDKLogger(),
      cancellationChecker: TaskCancellationChecker()
    )
  }
}

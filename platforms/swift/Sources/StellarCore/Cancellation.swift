/// A replaceable cancellation source used by retry, scanning, and transport coordinators.
public protocol SDKCancellationChecking: Sendable {
  var isCancelled: Bool { get }
  func checkCancellation() throws
}

extension SDKCancellationChecking {
  public func checkCancellation() throws {
    guard !isCancelled else {
      throw SDKError(code: .cancelled, message: "operation cancelled")
    }
  }
}

/// Bridges Swift structured-concurrency cancellation into the stable SDK error model.
public struct TaskCancellationChecker: SDKCancellationChecking {
  public init() {}

  public var isCancelled: Bool { Task.isCancelled }
}

/// A cancellation source for work that has no external cancellation owner.
public struct NeverCancelledChecker: SDKCancellationChecking {
  public init() {}

  public var isCancelled: Bool { false }
}

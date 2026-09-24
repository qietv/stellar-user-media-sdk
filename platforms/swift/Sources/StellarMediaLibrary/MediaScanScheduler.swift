import Foundation
import StellarCore
import StellarRemoteMedia

/// The source of a request submitted to `MediaScanScheduler`.
public enum MediaScanTriggerOrigin: String, Codable, Hashable, Sendable {
  case manual
  case watcher
  case scheduled
}

/// One source-independent request to schedule discovery or repair work.
public struct MediaScanTrigger: Equatable, Sendable {
  public let sourceUID: String
  public let mode: MediaScanMode
  public let roots: [RemoteLocator]
  public let origin: MediaScanTriggerOrigin
  public let submittedAtMilliseconds: Int64

  public init(
    sourceUID: String,
    mode: MediaScanMode,
    roots: [RemoteLocator],
    origin: MediaScanTriggerOrigin,
    submittedAtMilliseconds: Int64
  ) throws {
    guard !sourceUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !sourceUID.contains("\0"), submittedAtMilliseconds >= 0,
      roots.allSatisfy({ $0.sourceUID == sourceUID })
    else {
      throw SDKError(code: .invalidConfiguration, message: "media scan trigger is invalid")
    }
    switch mode {
    case .full:
      guard roots.count == 1, roots[0].path.isRoot else {
        throw SDKError(
          code: .invalidConfiguration,
          message: "full scan trigger must cover the source root"
        )
      }
    case .incremental:
      guard !roots.isEmpty else {
        throw SDKError(
          code: .invalidConfiguration,
          message: "incremental scan trigger requires a scope"
        )
      }
    case .repair:
      guard roots.isEmpty else {
        throw SDKError(
          code: .invalidConfiguration,
          message: "repair trigger must not enumerate source roots"
        )
      }
    }
    self.sourceUID = sourceUID
    self.mode = mode
    self.roots = roots
    self.origin = origin
    self.submittedAtMilliseconds = submittedAtMilliseconds
  }
}

/// Coalescing delays for watcher hints. Manual and periodic triggers are immediately eligible.
public struct MediaScanSchedulerConfiguration: Equatable, Sendable {
  public let watcherDebounceMilliseconds: Int64
  public let watcherMaximumWaitMilliseconds: Int64

  public init() {
    watcherDebounceMilliseconds = 2_000
    watcherMaximumWaitMilliseconds = 10_000
  }

  public init(
    watcherDebounceMilliseconds: Int64,
    watcherMaximumWaitMilliseconds: Int64
  ) throws {
    guard watcherDebounceMilliseconds >= 0,
      watcherMaximumWaitMilliseconds >= watcherDebounceMilliseconds
    else {
      throw SDKError(code: .invalidConfiguration, message: "scan scheduler timing is invalid")
    }
    self.watcherDebounceMilliseconds = watcherDebounceMilliseconds
    self.watcherMaximumWaitMilliseconds = watcherMaximumWaitMilliseconds
  }
}

/// A coalesced unit of work claimed from `MediaScanScheduler`.
public struct ScheduledMediaScan: Equatable, Sendable {
  public let request: MediaScanRequest
  public let origins: Set<MediaScanTriggerOrigin>
  public let firstSubmittedAtMilliseconds: Int64

  fileprivate init(
    request: MediaScanRequest,
    origins: Set<MediaScanTriggerOrigin>,
    firstSubmittedAtMilliseconds: Int64
  ) {
    self.request = request
    self.origins = origins
    self.firstSubmittedAtMilliseconds = firstSubmittedAtMilliseconds
  }
}

/// Merges scan triggers and enforces one claimed run per source.
///
/// Full discovery subsumes pending incremental scopes. Incremental scopes are compacted with the
/// source's path semantics. Repair remains a separate unit of work because metadata repair must
/// not accidentally discard a pending authoritative discovery run.
public actor MediaScanScheduler {
  private enum WorkKind: Hashable, Sendable {
    case discovery
    case repair
  }

  private struct Pending: Sendable {
    let sourceUID: String
    var mode: MediaScanMode
    var roots: [RemoteLocator]
    let semantics: RemotePathSemantics
    var origins: Set<MediaScanTriggerOrigin>
    let firstSubmittedAtMilliseconds: Int64
    var readyAtMilliseconds: Int64
    var priority: Int
    let sequence: UInt64
  }

  public let configuration: MediaScanSchedulerConfiguration

  private var pending: [String: [WorkKind: Pending]] = [:]
  private var activeRunBySource: [String: String] = [:]
  private var sequence: UInt64 = 0

  public init(
    configuration: MediaScanSchedulerConfiguration = MediaScanSchedulerConfiguration()
  ) {
    self.configuration = configuration
  }

  /// Adds or merges a trigger without starting work.
  public func submit(
    _ trigger: MediaScanTrigger,
    pathSemantics: RemotePathSemantics
  ) throws {
    let kind: WorkKind = trigger.mode == .repair ? .repair : .discovery
    var sourcePending = pending[trigger.sourceUID, default: [:]]
    if var existing = sourcePending[kind] {
      guard existing.semantics == pathSemantics else {
        throw SDKError(
          code: .conflict,
          message: "source path semantics changed while scan work was pending"
        )
      }
      merge(trigger, into: &existing)
      sourcePending[kind] = existing
    } else {
      sequence &+= 1
      sourcePending[kind] = Pending(
        sourceUID: trigger.sourceUID,
        mode: trigger.mode,
        roots: Self.compact(trigger.roots, semantics: pathSemantics),
        semantics: pathSemantics,
        origins: [trigger.origin],
        firstSubmittedAtMilliseconds: trigger.submittedAtMilliseconds,
        readyAtMilliseconds: readyTime(for: trigger),
        priority: Self.priority(for: trigger),
        sequence: sequence
      )
    }
    pending[trigger.sourceUID] = sourcePending
  }

  /// Claims the highest-priority ready run whose source is currently idle.
  public func nextReady(atMilliseconds now: Int64) throws -> ScheduledMediaScan? {
    guard now >= 0 else {
      throw SDKError(code: .invalidConfiguration, message: "scheduler time is invalid")
    }
    var selected: (sourceUID: String, kind: WorkKind, pending: Pending)?
    for (sourceUID, jobs) in pending where activeRunBySource[sourceUID] == nil {
      for (kind, candidate) in jobs where candidate.readyAtMilliseconds <= now {
        guard let current = selected else {
          selected = (sourceUID, kind, candidate)
          continue
        }
        if (candidate.priority, UInt64.max - candidate.sequence)
          > (current.pending.priority, UInt64.max - current.pending.sequence)
        {
          selected = (sourceUID, kind, candidate)
        }
      }
    }
    guard let selected else { return nil }

    var sourcePending = pending[selected.sourceUID, default: [:]]
    sourcePending[selected.kind] = nil
    pending[selected.sourceUID] = sourcePending.isEmpty ? nil : sourcePending
    let request = try MediaScanRequest(
      runUID: UUID().uuidString.lowercased(),
      sourceUID: selected.sourceUID,
      mode: selected.pending.mode,
      roots: selected.pending.roots
    )
    activeRunBySource[selected.sourceUID] = request.runUID
    return ScheduledMediaScan(
      request: request,
      origins: selected.pending.origins,
      firstSubmittedAtMilliseconds: selected.pending.firstSubmittedAtMilliseconds
    )
  }

  /// Returns the earliest future time at which pending work can be claimed.
  public func nextReadyAtMilliseconds() -> Int64? {
    pending.compactMap { sourceUID, jobs in
      guard activeRunBySource[sourceUID] == nil else { return nil }
      return jobs.values.map(\.readyAtMilliseconds).min()
    }.min()
  }

  /// Releases a claimed source after success, cancellation, or failure.
  public func finish(runUID: String) throws {
    guard let sourceUID = activeRunBySource.first(where: { $0.value == runUID })?.key else {
      throw SDKError(code: .conflict, message: "scheduled scan run is not active")
    }
    activeRunBySource[sourceUID] = nil
  }

  /// Number of coalesced units waiting behind active work.
  public func pendingRunCount() -> Int {
    pending.values.reduce(0) { $0 + $1.count }
  }

  private func merge(_ trigger: MediaScanTrigger, into existing: inout Pending) {
    existing.origins.insert(trigger.origin)
    existing.priority = max(existing.priority, Self.priority(for: trigger))
    if trigger.mode == .full {
      existing.mode = .full
      existing.roots = trigger.roots
    } else if existing.mode == .incremental {
      existing.roots = Self.compact(
        existing.roots + trigger.roots,
        semantics: existing.semantics
      )
    }

    if trigger.origin == .watcher, trigger.mode == .incremental,
      existing.origins == [.watcher]
    {
      existing.readyAtMilliseconds = min(
        Self.clampedAdd(
          existing.firstSubmittedAtMilliseconds,
          configuration.watcherMaximumWaitMilliseconds
        ),
        Self.clampedAdd(
          trigger.submittedAtMilliseconds,
          configuration.watcherDebounceMilliseconds
        )
      )
    } else {
      existing.readyAtMilliseconds = min(
        existing.readyAtMilliseconds,
        trigger.submittedAtMilliseconds
      )
    }
  }

  private func readyTime(for trigger: MediaScanTrigger) -> Int64 {
    guard trigger.origin == .watcher, trigger.mode == .incremental else {
      return trigger.submittedAtMilliseconds
    }
    return Self.clampedAdd(
      trigger.submittedAtMilliseconds,
      configuration.watcherDebounceMilliseconds
    )
  }

  private static func priority(for trigger: MediaScanTrigger) -> Int {
    if trigger.origin == .manual {
      return trigger.mode == .repair ? 500 : 400
    }
    switch trigger.mode {
    case .full: return 300
    case .incremental: return 200
    case .repair: return 100
    }
  }

  private static func compact(
    _ locators: [RemoteLocator],
    semantics: RemotePathSemantics
  ) -> [RemoteLocator] {
    let sorted = locators.sorted {
      let left = $0.pathComparisonKey(using: semantics)
      let right = $1.pathComparisonKey(using: semantics)
      return (left.utf8.count, left) < (right.utf8.count, right)
    }
    var accepted: [(locator: RemoteLocator, key: String)] = []
    accepted.reserveCapacity(sorted.count)
    for locator in sorted {
      let key = locator.pathComparisonKey(using: semantics)
      guard !accepted.contains(where: { Self.isEqualOrDescendant(key, of: $0.key) }) else {
        continue
      }
      accepted.append((locator, key))
    }
    return accepted.map(\.locator)
  }

  private static func isEqualOrDescendant(_ candidate: String, of root: String) -> Bool {
    root.isEmpty || candidate == root || candidate.hasPrefix("\(root)/")
  }

  private static func clampedAdd(_ value: Int64, _ increment: Int64) -> Int64 {
    value > Int64.max - increment ? Int64.max : value + increment
  }
}

import Foundation
import StellarCore
import StellarRemoteMedia

/// The source work performed by a media scan run.
public enum MediaScanMode: String, Codable, Sendable {
  /// Recursively enumerates the configured source root.
  case full
  /// Recursively enumerates one or more explicit directory scopes.
  case incremental
  /// Reprocesses already indexed facts without enumerating the source.
  case repair
}

/// Durable phases in the source-independent scanner state machine.
public enum MediaScanPhase: String, Codable, Sendable {
  case queued
  case enumerating
  case finalizing
  case completed
  case failed
  case cancelled
}

/// A stable request for one resumable media scan run.
public struct MediaScanRequest: Codable, Equatable, Sendable {
  public let runUID: String
  public let sourceUID: String
  public let mode: MediaScanMode
  public let roots: [RemoteLocator]

  public init(
    runUID: String,
    sourceUID: String,
    mode: MediaScanMode,
    roots: [RemoteLocator]
  ) throws {
    guard !runUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !runUID.contains("\0"),
      !sourceUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !sourceUID.contains("\0"),
      roots.allSatisfy({ $0.sourceUID == sourceUID })
    else {
      throw SDKError(code: .invalidConfiguration, message: "media scan request is invalid")
    }

    switch mode {
    case .full:
      guard roots.count == 1, roots[0].path.isRoot else {
        throw SDKError(
          code: .invalidConfiguration,
          message: "full scan must cover exactly the source root"
        )
      }
    case .incremental:
      guard !roots.isEmpty else {
        throw SDKError(
          code: .invalidConfiguration,
          message: "incremental scan requires an explicit scope"
        )
      }
    case .repair:
      break
    }

    self.runUID = runUID
    self.sourceUID = sourceUID
    self.mode = mode
    self.roots = roots
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        runUID: container.decode(String.self, forKey: .runUID),
        sourceUID: container.decode(String.self, forKey: .sourceUID),
        mode: container.decode(MediaScanMode.self, forKey: .mode),
        roots: container.decode([RemoteLocator].self, forKey: .roots)
      )
    } catch let error as SDKError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message)
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case runUID = "run_uid"
    case sourceUID = "source_uid"
    case mode
    case roots
  }
}

/// One resumable cursor position in the bounded directory work queue.
public struct MediaScanPageCursor: Codable, Equatable, Hashable, Sendable {
  public let directory: RemoteLocator
  public let cursor: String?

  public init(directory: RemoteLocator, cursor: String? = nil) throws {
    guard cursor?.isEmpty != true else {
      throw SDKError(code: .invalidConfiguration, message: "scan page cursor must not be empty")
    }
    self.directory = directory
    self.cursor = cursor
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        directory: container.decode(RemoteLocator.self, forKey: .directory),
        cursor: container.decodeIfPresent(String.self, forKey: .cursor)
      )
    } catch let error as SDKError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message)
      )
    }
  }
}

/// The preflight identity of one covered directory root.
public struct MediaScanRootIdentity: Codable, Equatable, Sendable {
  public let locator: RemoteLocator
  public let stableID: String?

  public init(entry: RemoteEntry) throws {
    guard entry.kind == .directory else {
      throw SDKError(code: .invalidConfiguration, message: "scan root must be a directory")
    }
    locator = entry.locator
    stableID = entry.stableID
  }

  private enum CodingKeys: String, CodingKey {
    case locator
    case stableID = "stable_id"
  }
}

/// A durable checkpoint committed after every successfully validated directory page.
public struct MediaScanCheckpoint: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let request: MediaScanRequest
  public let phase: MediaScanPhase
  public let capabilities: MediaSourceCapabilities?
  public let rootIdentities: [MediaScanRootIdentity]
  /// Legacy embedded frontier. Version 2 checkpoints keep this empty and use the scan sink.
  public let pendingPages: [MediaScanPageCursor]
  /// Legacy embedded completion set. Version 2 checkpoints keep this empty.
  public let completedPages: [MediaScanPageCursor]
  /// Legacy embedded identity set. Version 2 checkpoints keep this empty.
  public let seenEntryIdentityKeys: [String]
  /// Legacy embedded directory set. Version 2 checkpoints keep this empty.
  public let seenDirectoryIdentityKeys: [String]
  /// Number of pending pages in the durable frontier. The pages themselves live in the sink.
  public let pendingPageCount: Int
  public let discoveredEntryCount: Int64
  public let processedPageCount: Int64
  public let lastErrorCode: SDKErrorCode?

  /// Creates the initial queued checkpoint for a scan request.
  public init(request: MediaScanRequest) throws {
    self.init(
      schemaVersion: 2,
      request: request,
      phase: .queued,
      capabilities: nil,
      rootIdentities: [],
      pendingPageCount: request.mode == .repair ? 0 : request.roots.count,
      discoveredEntryCount: 0,
      processedPageCount: 0,
      lastErrorCode: nil
    )
  }

  private init(
    schemaVersion: Int = 2,
    request: MediaScanRequest,
    phase: MediaScanPhase,
    capabilities: MediaSourceCapabilities?,
    rootIdentities: [MediaScanRootIdentity],
    pendingPageCount: Int,
    discoveredEntryCount: Int64,
    processedPageCount: Int64,
    lastErrorCode: SDKErrorCode?
  ) {
    self.schemaVersion = schemaVersion
    self.request = request
    self.phase = phase
    self.capabilities = capabilities
    self.rootIdentities = rootIdentities
    pendingPages = []
    completedPages = []
    seenEntryIdentityKeys = []
    seenDirectoryIdentityKeys = []
    self.pendingPageCount = pendingPageCount
    self.discoveredEntryCount = discoveredEntryCount
    self.processedPageCount = processedPageCount
    self.lastErrorCode = lastErrorCode
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    let request = try container.decode(MediaScanRequest.self, forKey: .request)
    let phase = try container.decode(MediaScanPhase.self, forKey: .phase)
    let capabilities = try container.decodeIfPresent(
      MediaSourceCapabilities.self,
      forKey: .capabilities
    )
    let rootIdentities = try container.decode(
      [MediaScanRootIdentity].self,
      forKey: .rootIdentities
    )
    let pendingPageCount = try container.decode(Int.self, forKey: .pendingPageCount)
    let discoveredEntryCount = try container.decode(Int64.self, forKey: .discoveredEntryCount)
    let processedPageCount = try container.decode(Int64.self, forKey: .processedPageCount)
    let lastErrorCode = try container.decodeIfPresent(
      SDKErrorCode.self,
      forKey: .lastErrorCode
    )

    guard schemaVersion == 2,
      pendingPageCount >= 0,
      discoveredEntryCount >= 0,
      processedPageCount >= 0,
      rootIdentities.allSatisfy({ $0.locator.sourceUID == request.sourceUID }),
      rootIdentities.isEmpty || rootIdentities.map(\.locator) == request.roots,
      ![MediaScanPhase.finalizing, .completed].contains(phase) || pendingPageCount == 0,
      ![MediaScanPhase.failed, .cancelled].contains(phase) || lastErrorCode != nil,
      ![MediaScanPhase.finalizing, .completed].contains(phase) || lastErrorCode == nil,
      request.mode != .repair || (pendingPageCount == 0 && discoveredEntryCount == 0),
      request.mode == .repair || ![MediaScanPhase.finalizing, .completed].contains(phase)
        || rootIdentities.count == request.roots.count
    else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: decoder.codingPath,
          debugDescription: "media scan checkpoint is invalid"
        )
      )
    }

    self.init(
      schemaVersion: schemaVersion,
      request: request,
      phase: phase,
      capabilities: capabilities,
      rootIdentities: rootIdentities,
      pendingPageCount: pendingPageCount,
      discoveredEntryCount: discoveredEntryCount,
      processedPageCount: processedPageCount,
      lastErrorCode: lastErrorCode
    )
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case request
    case phase
    case capabilities
    case rootIdentities = "root_identities"
    case pendingPageCount = "pending_page_count"
    case discoveredEntryCount = "discovered_entry_count"
    case processedPageCount = "processed_page_count"
    case lastErrorCode = "last_error_code"
  }

  fileprivate func updating(
    phase: MediaScanPhase? = nil,
    capabilities: MediaSourceCapabilities?? = nil,
    rootIdentities: [MediaScanRootIdentity]? = nil,
    pendingPageCount: Int? = nil,
    discoveredEntryCount: Int64? = nil,
    processedPageCount: Int64? = nil,
    lastErrorCode: SDKErrorCode?? = nil
  ) -> MediaScanCheckpoint {
    MediaScanCheckpoint(
      schemaVersion: 2,
      request: request,
      phase: phase ?? self.phase,
      capabilities: capabilities ?? self.capabilities,
      rootIdentities: rootIdentities ?? self.rootIdentities,
      pendingPageCount: pendingPageCount ?? self.pendingPageCount,
      discoveredEntryCount: discoveredEntryCount ?? self.discoveredEntryCount,
      processedPageCount: processedPageCount ?? self.processedPageCount,
      lastErrorCode: lastErrorCode ?? self.lastErrorCode
    )
  }
}

/// Durable enumeration state held outside the compact scanner checkpoint.
public struct MediaScanEnumerationState: Equatable, Sendable {
  public let pendingPages: [MediaScanPageCursor]
  public let completedPages: [MediaScanPageCursor]
  public let seenEntryIdentityKeys: [String]
  public let seenDirectoryIdentityKeys: [String]

  public init(
    pendingPages: [MediaScanPageCursor],
    completedPages: [MediaScanPageCursor],
    seenEntryIdentityKeys: [String],
    seenDirectoryIdentityKeys: [String]
  ) throws {
    guard Set(pendingPages).count == pendingPages.count,
      Set(completedPages).count == completedPages.count,
      Set(pendingPages).isDisjoint(with: completedPages),
      Set(seenEntryIdentityKeys).count == seenEntryIdentityKeys.count,
      Set(seenDirectoryIdentityKeys).count == seenDirectoryIdentityKeys.count,
      Set(seenDirectoryIdentityKeys).isSubset(of: seenEntryIdentityKeys)
    else {
      throw SDKError(code: .invalidConfiguration, message: "scan enumeration state is invalid")
    }
    self.pendingPages = pendingPages
    self.completedPages = completedPages
    self.seenEntryIdentityKeys = seenEntryIdentityKeys
    self.seenDirectoryIdentityKeys = seenDirectoryIdentityKeys
  }
}

/// The incremental frontier and identity changes acknowledged with one directory page.
public struct MediaScanPageTransition: Equatable, Sendable {
  public let completedPage: MediaScanPageCursor
  public let enqueuedPages: [MediaScanPageCursor]
  public let seenEntryIdentityKeys: [String]
  public let seenDirectoryIdentityKeys: [String]

  public init(
    completedPage: MediaScanPageCursor,
    enqueuedPages: [MediaScanPageCursor],
    seenEntryIdentityKeys: [String],
    seenDirectoryIdentityKeys: [String]
  ) {
    self.completedPage = completedPage
    self.enqueuedPages = enqueuedPages
    self.seenEntryIdentityKeys = seenEntryIdentityKeys
    self.seenDirectoryIdentityKeys = seenDirectoryIdentityKeys
  }
}

/// The authoritative boundary exposed only when a scan is safely finalized.
public struct MediaScanCompletion: Codable, Equatable, Sendable {
  public let runUID: String
  public let sourceUID: String
  public let mode: MediaScanMode
  public let coveredRoots: [RemoteLocator]
  public let reconcileMissingEligible: Bool
  public let discoveredEntryCount: Int64
  public let processedPageCount: Int64

  fileprivate init(checkpoint: MediaScanCheckpoint) {
    runUID = checkpoint.request.runUID
    sourceUID = checkpoint.request.sourceUID
    mode = checkpoint.request.mode
    coveredRoots = checkpoint.request.roots
    reconcileMissingEligible = checkpoint.request.mode != .repair
    discoveredEntryCount = checkpoint.discoveredEntryCount
    processedPageCount = checkpoint.processedPageCount
  }

  private enum CodingKeys: String, CodingKey {
    case runUID = "run_uid"
    case sourceUID = "source_uid"
    case mode
    case coveredRoots = "covered_roots"
    case reconcileMissingEligible = "reconcile_missing_eligible"
    case discoveredEntryCount = "discovered_entry_count"
    case processedPageCount = "processed_page_count"
  }
}

/// One atomic scanner write: entries and the checkpoint that acknowledges their page.
public struct MediaScanBatch: Sendable {
  public let entries: [RemoteEntry]
  public let checkpoint: MediaScanCheckpoint
  public let completion: MediaScanCompletion?
  public let enumerationState: MediaScanEnumerationState?

  /// Ordered frontier transitions acknowledged atomically by this batch.
  public let pageTransitions: [MediaScanPageTransition]

  /// The transition for a legacy single-page batch, or `nil` for a coalesced batch.
  public let pageTransition: MediaScanPageTransition?

  public init(
    entries: [RemoteEntry],
    checkpoint: MediaScanCheckpoint,
    completion: MediaScanCompletion? = nil
  ) {
    self.init(
      entries: entries,
      checkpoint: checkpoint,
      completion: completion,
      enumerationState: nil,
      pageTransitions: []
    )
  }

  public init(
    entries: [RemoteEntry],
    checkpoint: MediaScanCheckpoint,
    completion: MediaScanCompletion? = nil,
    enumerationState: MediaScanEnumerationState?,
    pageTransition: MediaScanPageTransition?
  ) {
    self.init(
      entries: entries,
      checkpoint: checkpoint,
      completion: completion,
      enumerationState: enumerationState,
      pageTransitions: pageTransition.map { [$0] } ?? []
    )
  }

  public init(
    entries: [RemoteEntry],
    checkpoint: MediaScanCheckpoint,
    completion: MediaScanCompletion? = nil,
    enumerationState: MediaScanEnumerationState?,
    pageTransitions: [MediaScanPageTransition]
  ) {
    self.entries = entries
    self.checkpoint = checkpoint
    self.completion = completion
    self.enumerationState = enumerationState
    self.pageTransitions = pageTransitions
    pageTransition = pageTransitions.count == 1 ? pageTransitions[0] : nil
  }
}

/// Atomic persistence seam implemented by S4 storage and by fixture-backed tests.
public protocol MediaScanSink: Sendable {
  /// Preferred number of small directory pages to persist in one atomic commit.
  ///
  /// The default of one preserves per-page durability for general-purpose sinks. Durable
  /// database sinks may opt into a larger bounded batch to amortize transaction overhead.
  var preferredPageCommitBatchSize: Int { get }

  func commit(_ batch: MediaScanBatch) async throws
  func loadEnumerationState(runUID: String) async throws -> MediaScanEnumerationState?
}

extension MediaScanSink {
  public var preferredPageCommitBatchSize: Int { 1 }

  public func loadEnumerationState(runUID _: String) async throws -> MediaScanEnumerationState? {
    nil
  }
}

/// Scanner event categories that never expose source paths or stable identifiers.
public enum MediaScanEventKind: String, Codable, Sendable {
  case started
  case progress
  case checkpointed
  case completed
  case failed
  case cancelled
}

/// A path-free progress event safe for application status surfaces.
public struct MediaScanEvent: Codable, Equatable, Sendable {
  public let kind: MediaScanEventKind
  public let runUID: String
  public let phase: MediaScanPhase
  public let discoveredEntryCount: Int64
  public let processedPageCount: Int64
  public let pendingPageCount: Int
  public let errorCode: SDKErrorCode?

  fileprivate init(
    kind: MediaScanEventKind,
    checkpoint: MediaScanCheckpoint,
    errorCode: SDKErrorCode? = nil
  ) {
    self.kind = kind
    runUID = checkpoint.request.runUID
    phase = checkpoint.phase
    discoveredEntryCount = checkpoint.discoveredEntryCount
    processedPageCount = checkpoint.processedPageCount
    pendingPageCount = checkpoint.pendingPageCount
    self.errorCode = errorCode
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case runUID = "run_uid"
    case phase
    case discoveredEntryCount = "discovered_entry_count"
    case processedPageCount = "processed_page_count"
    case pendingPageCount = "pending_page_count"
    case errorCode = "error_code"
  }
}

/// Injectable event consumer used by apps, CLI, and tests.
public protocol MediaScanObserver: Sendable {
  func emit(_ event: MediaScanEvent) async
}

/// An observer for callers that do not need progress events.
public struct NoopMediaScanObserver: MediaScanObserver {
  public init() {}

  public func emit(_: MediaScanEvent) async {}
}

/// Bounded enumeration and pagination limits for one scanner instance.
public struct MediaScannerConfiguration: Equatable, Sendable {
  public let pageSize: Int
  public let maxConcurrentDirectoryRequests: Int

  public init() {
    pageSize = 2_000
    maxConcurrentDirectoryRequests = 4
  }

  public init(pageSize: Int, maxConcurrentDirectoryRequests: Int) throws {
    guard (1...10_000).contains(pageSize),
      (1...32).contains(maxConcurrentDirectoryRequests)
    else {
      throw SDKError(code: .invalidConfiguration, message: "scanner configuration is invalid")
    }
    self.pageSize = pageSize
    self.maxConcurrentDirectoryRequests = maxConcurrentDirectoryRequests
  }
}

/// A completed scanner result. Failed and cancelled runs throw and never return this value.
public struct MediaScanResult: Equatable, Sendable {
  public let checkpoint: MediaScanCheckpoint
  public let completion: MediaScanCompletion

  fileprivate init(checkpoint: MediaScanCheckpoint, completion: MediaScanCompletion) {
    self.checkpoint = checkpoint
    self.completion = completion
  }
}

/// Source-independent, resumable, bounded-concurrency directory scanner.
public struct MediaScanner: Sendable {
  public let configuration: MediaScannerConfiguration

  public init(configuration: MediaScannerConfiguration = MediaScannerConfiguration()) {
    self.configuration = configuration
  }

  public func scan(
    _ request: MediaScanRequest,
    using connector: any MediaSourceConnector,
    sink: any MediaScanSink,
    resumeFrom suppliedCheckpoint: MediaScanCheckpoint? = nil,
    observer: any MediaScanObserver = NoopMediaScanObserver()
  ) async throws -> MediaScanResult {
    var checkpoint: MediaScanCheckpoint
    var enumerationState: MediaScanEnumerationState?
    if let suppliedCheckpoint {
      guard suppliedCheckpoint.request == request else {
        throw SDKError(
          code: .invalidConfiguration,
          message: "scan checkpoint does not match request"
        )
      }
      checkpoint = suppliedCheckpoint
    } else {
      checkpoint = try MediaScanCheckpoint(request: request)
      enumerationState = try initialEnumerationState(for: request)
      try await sink.commit(
        MediaScanBatch(
          entries: [],
          checkpoint: checkpoint,
          enumerationState: enumerationState,
          pageTransition: nil
        )
      )
    }

    if checkpoint.phase == .completed {
      let completion = MediaScanCompletion(checkpoint: checkpoint)
      return MediaScanResult(checkpoint: checkpoint, completion: completion)
    }

    if enumerationState == nil, request.mode != .repair, checkpoint.phase != .finalizing {
      guard let restored = try await sink.loadEnumerationState(runUID: request.runUID) else {
        throw SDKError(
          code: .storageFailure,
          message: "durable scan frontier is missing"
        )
      }
      try validate(restored, for: checkpoint)
      enumerationState = restored
    }

    await observer.emit(MediaScanEvent(kind: .started, checkpoint: checkpoint))

    if checkpoint.phase == .finalizing || request.mode == .repair {
      do {
        return try await finalize(checkpoint: checkpoint, sink: sink, observer: observer)
      } catch {
        let failure = normalized(error)
        try? await recordFailure(
          failure,
          checkpoint: &checkpoint,
          sink: sink,
          observer: observer
        )
        throw failure
      }
    }

    let session: any MediaSourceSession
    do {
      try Task.checkCancellation()
      session = try await connector.connect()
    } catch {
      let failure = normalized(error)
      try? await recordFailure(failure, checkpoint: &checkpoint, sink: sink, observer: observer)
      throw failure
    }

    do {
      guard session.sourceUID == request.sourceUID else {
        throw SDKError(
          code: .invalidConfiguration,
          message: "connector source does not match scan request"
        )
      }
      let capabilities = await session.capabilities
      if let savedCapabilities = checkpoint.capabilities,
        !savedCapabilities.isEnumerationResumeCompatible(with: capabilities)
      {
        throw SDKError(
          code: .invalidConfiguration,
          message: "connector capabilities changed during resumed scan"
        )
      }
      try validateCoverage(request.roots, mode: request.mode, capabilities: capabilities)
      let rootIdentities = try await preflightRoots(
        request.roots,
        session: session,
        capabilities: capabilities,
        saved: checkpoint.rootIdentities
      )

      checkpoint = checkpoint.updating(
        phase: .enumerating,
        capabilities: .some(capabilities),
        rootIdentities: rootIdentities,
        lastErrorCode: .some(nil)
      )
      try await sink.commit(MediaScanBatch(entries: [], checkpoint: checkpoint))
      await observer.emit(MediaScanEvent(kind: .checkpointed, checkpoint: checkpoint))

      do {
        checkpoint = try await enumerate(
          session: session,
          checkpoint: checkpoint,
          state: try requireEnumerationState(enumerationState),
          sink: sink,
          observer: observer
        )
      } catch let interruption as EnumerationInterruption {
        checkpoint = interruption.checkpoint
        throw interruption.underlying
      }
      await session.disconnect()
      return try await finalize(checkpoint: checkpoint, sink: sink, observer: observer)
    } catch {
      await session.disconnect()
      let failure = normalized(error)
      try? await recordFailure(failure, checkpoint: &checkpoint, sink: sink, observer: observer)
      throw failure
    }
  }

  private func enumerate(
    session: any MediaSourceSession,
    checkpoint initialCheckpoint: MediaScanCheckpoint,
    state initialState: MediaScanEnumerationState,
    sink: any MediaScanSink,
    observer: any MediaScanObserver
  ) async throws -> MediaScanCheckpoint {
    var checkpoint = initialCheckpoint
    guard let capabilities = checkpoint.capabilities else {
      throw SDKError(code: .invalidConfiguration, message: "scan capabilities are missing")
    }
    let directoryRequestLimit = min(
      configuration.maxConcurrentDirectoryRequests,
      capabilities.preferredDirectoryRequestConcurrency
    )
    var workingState = EnumerationWorkingState(state: initialState)
    let pageCommitBatchSize = max(1, min(sink.preferredPageCommitBatchSize, 64))
    var durableCheckpoint = checkpoint

    do {
      return try await withThrowingTaskGroup(of: PageResponse.self) { group in
        var active = Set<MediaScanPageCursor>()
        var bufferedEntries: [RemoteEntry] = []
        var bufferedTransitions: [MediaScanPageTransition] = []

        while workingState.pendingPageCount > 0 {
          try Task.checkCancellation()

          for pageCursor in workingState.schedulingCandidates(
            excluding: active,
            limit: directoryRequestLimit - active.count
          ) {
            active.insert(pageCursor)
            let pageSize = configuration.pageSize
            group.addTask {
              try Task.checkCancellation()
              let request = try RemoteDirectoryPageRequest(
                directory: pageCursor.directory,
                cursor: pageCursor.cursor,
                limit: pageSize
              )
              let page = try await session.listDirectory(request)
              try Task.checkCancellation()
              return PageResponse(cursor: pageCursor, page: page)
            }
          }

          guard let response = try await group.next() else {
            throw SDKError(code: .unknown, message: "scanner work queue ended unexpectedly")
          }
          active.remove(response.cursor)

          // Keep entry memory bounded to approximately one configured source page. This still
          // coalesces the common many-small-directories case without retaining several large
          // directory pages at once.
          if !bufferedTransitions.isEmpty,
            bufferedEntries.count + response.page.items.count > configuration.pageSize
          {
            try await sink.commit(
              MediaScanBatch(
                entries: bufferedEntries,
                checkpoint: checkpoint,
                enumerationState: nil,
                pageTransitions: bufferedTransitions
              )
            )
            durableCheckpoint = checkpoint
            bufferedEntries.removeAll(keepingCapacity: true)
            bufferedTransitions.removeAll(keepingCapacity: true)
            await observer.emit(MediaScanEvent(kind: .checkpointed, checkpoint: checkpoint))
          }

          let processed = try process(
            response,
            checkpoint: checkpoint,
            capabilities: capabilities,
            workingState: &workingState
          )
          checkpoint = processed.checkpoint
          bufferedEntries.append(contentsOf: response.page.items)
          bufferedTransitions.append(processed.transition)
          await observer.emit(MediaScanEvent(kind: .progress, checkpoint: checkpoint))

          if bufferedTransitions.count >= pageCommitBatchSize
            || bufferedEntries.count >= configuration.pageSize
            || workingState.pendingPageCount == 0
          {
            try await sink.commit(
              MediaScanBatch(
                entries: bufferedEntries,
                checkpoint: checkpoint,
                enumerationState: nil,
                pageTransitions: bufferedTransitions
              )
            )
            durableCheckpoint = checkpoint
            bufferedEntries.removeAll(keepingCapacity: true)
            bufferedTransitions.removeAll(keepingCapacity: true)
            await observer.emit(MediaScanEvent(kind: .checkpointed, checkpoint: checkpoint))
          }
        }

        checkpoint = checkpoint.updating(
          phase: .finalizing,
          pendingPageCount: 0,
          lastErrorCode: .some(nil)
        )
        try await sink.commit(MediaScanBatch(entries: [], checkpoint: checkpoint))
        await observer.emit(MediaScanEvent(kind: .checkpointed, checkpoint: checkpoint))
        return checkpoint
      }
    } catch {
      throw EnumerationInterruption(checkpoint: durableCheckpoint, underlying: error)
    }
  }

  private func process(
    _ response: PageResponse,
    checkpoint: MediaScanCheckpoint,
    capabilities: MediaSourceCapabilities,
    workingState: inout EnumerationWorkingState
  ) throws -> ProcessedPage {
    guard workingState.containsPending(response.cursor) else {
      throw SDKError(code: .conflict, message: "scanner received an untracked page")
    }

    let semantics = capabilities.pathSemantics
    let parentPath = response.cursor.directory.path
    for entry in response.page.items {
      guard entry.locator.sourceUID == checkpoint.request.sourceUID,
        Self.hasDirectParent(entry.locator.path, parent: parentPath, semantics: semantics)
      else {
        throw SDKError(
          code: .parseFailure,
          message: "connector returned an entry outside the requested directory"
        )
      }
    }

    workingState.complete(response.cursor)
    workingState.completedPageCursors.insert(response.cursor)
    var enqueuedPages: [MediaScanPageCursor] = []

    if let nextCursor = response.page.nextCursor {
      let next = try MediaScanPageCursor(
        directory: response.cursor.directory,
        cursor: nextCursor
      )
      guard !workingState.completedPageCursors.contains(next),
        !workingState.containsPending(next)
      else {
        throw SDKError(code: .parseFailure, message: "connector repeated a page cursor")
      }
      workingState.enqueue(next)
      enqueuedPages.append(next)
    }

    var discoveredCount = checkpoint.discoveredEntryCount
    var newlySeenEntryKeys: [String] = []
    var newlySeenDirectoryKeys: [String] = []

    for entry in response.page.items {
      let identityKey = identityKey(for: entry, capabilities: capabilities)
      if workingState.seenEntryKeys.insert(identityKey).inserted {
        newlySeenEntryKeys.append(identityKey)
        discoveredCount += 1
      }
      guard entry.kind == .directory else { continue }
      if workingState.seenDirectoryKeys.insert(identityKey).inserted {
        newlySeenDirectoryKeys.append(identityKey)
        let child = try MediaScanPageCursor(directory: entry.locator)
        guard !workingState.completedPageCursors.contains(child),
          !workingState.containsPending(child)
        else {
          continue
        }
        workingState.enqueue(child)
        enqueuedPages.append(child)
      }
    }

    return ProcessedPage(
      checkpoint: checkpoint.updating(
        pendingPageCount: workingState.pendingPageCount,
        discoveredEntryCount: discoveredCount,
        processedPageCount: checkpoint.processedPageCount + 1
      ),
      transition: MediaScanPageTransition(
        completedPage: response.cursor,
        enqueuedPages: enqueuedPages,
        seenEntryIdentityKeys: newlySeenEntryKeys,
        seenDirectoryIdentityKeys: newlySeenDirectoryKeys
      )
    )
  }

  private func finalize(
    checkpoint: MediaScanCheckpoint,
    sink: any MediaScanSink,
    observer: any MediaScanObserver
  ) async throws -> MediaScanResult {
    let finalizingCheckpoint = checkpoint.updating(
      phase: .finalizing,
      pendingPageCount: 0,
      lastErrorCode: .some(nil)
    )
    if checkpoint.phase != .finalizing {
      try await sink.commit(MediaScanBatch(entries: [], checkpoint: finalizingCheckpoint))
    }
    let completedCheckpoint = finalizingCheckpoint.updating(phase: .completed)
    let completion = MediaScanCompletion(checkpoint: completedCheckpoint)
    try await sink.commit(
      MediaScanBatch(
        entries: [],
        checkpoint: completedCheckpoint,
        completion: completion
      )
    )
    await observer.emit(MediaScanEvent(kind: .completed, checkpoint: completedCheckpoint))
    return MediaScanResult(checkpoint: completedCheckpoint, completion: completion)
  }

  private func recordFailure(
    _ failure: SDKError,
    checkpoint: inout MediaScanCheckpoint,
    sink: any MediaScanSink,
    observer: any MediaScanObserver
  ) async throws {
    let isCancelled = failure.code == .cancelled
    checkpoint = checkpoint.updating(
      phase: isCancelled ? .cancelled : .failed,
      lastErrorCode: .some(failure.code)
    )
    let failureBatch = MediaScanBatch(entries: [], checkpoint: checkpoint)
    if isCancelled {
      try await Task.detached {
        try await sink.commit(failureBatch)
      }.value
    } else {
      try await sink.commit(failureBatch)
    }
    await observer.emit(
      MediaScanEvent(
        kind: isCancelled ? .cancelled : .failed,
        checkpoint: checkpoint,
        errorCode: failure.code
      )
    )
  }

  private func identityKey(
    for entry: RemoteEntry,
    capabilities: MediaSourceCapabilities
  ) -> String {
    if capabilities.stableIDScope == .persistent || capabilities.stableIDScope == .scan,
      let stableID = entry.stableID
    {
      return "stable:\(stableID)"
    }
    return "path:\(entry.locator.pathComparisonKey(using: capabilities.pathSemantics))"
  }

  private static func hasDirectParent(
    _ entry: RemotePath,
    parent: RemotePath,
    semantics: RemotePathSemantics
  ) -> Bool {
    let entryPath = entry.relativePath
    let parentPath = parent.relativePath
    if let separator = entryPath.utf8.lastIndex(of: 47) {
      if entryPath[..<separator] == parentPath {
        return true
      }
    } else if parentPath.isEmpty {
      return true
    }
    return entry.parent?.comparisonKey(using: semantics)
      == parent.comparisonKey(using: semantics)
  }

  private func initialEnumerationState(
    for request: MediaScanRequest
  ) throws -> MediaScanEnumerationState {
    try MediaScanEnumerationState(
      pendingPages: request.mode == .repair
        ? [] : request.roots.map { try MediaScanPageCursor(directory: $0) },
      completedPages: [],
      seenEntryIdentityKeys: [],
      seenDirectoryIdentityKeys: []
    )
  }

  private func requireEnumerationState(
    _ state: MediaScanEnumerationState?
  ) throws -> MediaScanEnumerationState {
    guard let state else {
      throw SDKError(code: .storageFailure, message: "durable scan frontier is missing")
    }
    return state
  }

  private func validate(
    _ state: MediaScanEnumerationState,
    for checkpoint: MediaScanCheckpoint
  ) throws {
    guard state.pendingPages.count == checkpoint.pendingPageCount,
      state.completedPages.count == checkpoint.processedPageCount,
      state.seenEntryIdentityKeys.count == checkpoint.discoveredEntryCount,
      (state.pendingPages + state.completedPages).allSatisfy({
        $0.directory.sourceUID == checkpoint.request.sourceUID
      })
    else {
      throw SDKError(code: .storageFailure, message: "durable scan frontier is inconsistent")
    }
  }

  private func validateCoverage(
    _ roots: [RemoteLocator],
    mode: MediaScanMode,
    capabilities: MediaSourceCapabilities
  ) throws {
    guard mode == .incremental else { return }
    let semantics = capabilities.pathSemantics
    for (index, root) in roots.enumerated() {
      for other in roots.dropFirst(index + 1) {
        let rootKey = root.pathComparisonKey(using: semantics)
        let otherKey = other.pathComparisonKey(using: semantics)
        guard rootKey != otherKey,
          !root.path.isDescendant(of: other.path, using: semantics),
          !other.path.isDescendant(of: root.path, using: semantics)
        else {
          throw SDKError(
            code: .invalidConfiguration,
            message: "incremental scan scopes must not overlap"
          )
        }
      }
    }
  }

  private func preflightRoots(
    _ roots: [RemoteLocator],
    session: any MediaSourceSession,
    capabilities: MediaSourceCapabilities,
    saved: [MediaScanRootIdentity]
  ) async throws -> [MediaScanRootIdentity] {
    var identities: [MediaScanRootIdentity] = []
    for root in roots {
      try Task.checkCancellation()
      let entry = try await session.stat(root)
      guard entry.locator == root else {
        throw SDKError(
          code: .invalidConfiguration,
          message: "connector returned the wrong scan root"
        )
      }
      identities.append(try MediaScanRootIdentity(entry: entry))
    }

    guard !saved.isEmpty else { return identities }
    guard saved.map(\.locator) == identities.map(\.locator) else {
      throw SDKError(code: .conflict, message: "scan root changed during resumed scan")
    }
    if capabilities.stableIDScope == .persistent {
      for (previous, current) in zip(saved, identities) {
        guard previous.stableID == current.stableID else {
          throw SDKError(code: .conflict, message: "scan root identity changed")
        }
      }
    }
    return identities
  }

  private func normalized(_ error: any Error) -> SDKError {
    if error is CancellationError {
      return SDKError(code: .cancelled, message: "media scan cancelled")
    }
    if let error = error as? SDKError {
      return error
    }
    return SDKError(code: .unknown, message: "media scan failed")
  }

  private struct PageResponse: Sendable {
    let cursor: MediaScanPageCursor
    let page: CursorPage<RemoteEntry>
  }

  private struct EnumerationWorkingState {
    private var pendingPageQueue: [MediaScanPageCursor]
    private var pendingPageQueueHead: Int
    private var pendingPageCursors: Set<MediaScanPageCursor>
    var completedPageCursors: Set<MediaScanPageCursor>
    var seenEntryKeys: Set<String>
    var seenDirectoryKeys: Set<String>

    init(state: MediaScanEnumerationState) {
      pendingPageQueue = state.pendingPages.sorted(by: Self.cursorPrecedes)
      pendingPageQueueHead = 0
      pendingPageCursors = Set(state.pendingPages)
      completedPageCursors = Set(state.completedPages)
      seenEntryKeys = Set(state.seenEntryIdentityKeys)
      seenDirectoryKeys = Set(state.seenDirectoryIdentityKeys)
    }

    var pendingPageCount: Int { pendingPageCursors.count }

    func containsPending(_ cursor: MediaScanPageCursor) -> Bool {
      pendingPageCursors.contains(cursor)
    }

    func schedulingCandidates(
      excluding active: Set<MediaScanPageCursor>,
      limit: Int
    ) -> [MediaScanPageCursor] {
      guard limit > 0 else { return [] }
      return Array(
        pendingPageQueue[pendingPageQueueHead...].lazy.filter {
          pendingPageCursors.contains($0) && !active.contains($0)
        }.prefix(limit)
      )
    }

    mutating func complete(_ cursor: MediaScanPageCursor) {
      pendingPageCursors.remove(cursor)
      while pendingPageQueueHead < pendingPageQueue.count,
        !pendingPageCursors.contains(pendingPageQueue[pendingPageQueueHead])
      {
        pendingPageQueueHead += 1
      }
    }

    mutating func enqueue(_ cursor: MediaScanPageCursor) {
      if pendingPageCursors.insert(cursor).inserted {
        pendingPageQueue.append(cursor)
      }
    }

    private static func cursorPrecedes(
      _ left: MediaScanPageCursor,
      _ right: MediaScanPageCursor
    ) -> Bool {
      let leftKey = "\(left.directory.path.relativePath)\u{0}\(left.cursor ?? "")"
      let rightKey = "\(right.directory.path.relativePath)\u{0}\(right.cursor ?? "")"
      return leftKey < rightKey
    }
  }

  private struct ProcessedPage {
    let checkpoint: MediaScanCheckpoint
    let transition: MediaScanPageTransition
  }

  private struct EnumerationInterruption: Error {
    let checkpoint: MediaScanCheckpoint
    let underlying: any Error
  }
}

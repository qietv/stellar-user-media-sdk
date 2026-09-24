import Foundation
import StellarCore
import StellarMediaLibrary
import StellarRemoteMedia
import StellarStorage

/// The exact published file revision and candidate descriptors consumed by a deep disc probe.
public struct DiscMediaProbeTarget: Equatable, Sendable {
  public let locator: RemoteLocator
  public let sizeBytes: Int64?
  public let modifiedAtMilliseconds: Int64?
  public let entityTag: String?
  public let inputRevision: Int64
  public let candidates: [CompositeMediaDescriptor]

  init(input: LibraryCompositeMediaProbeInput) throws {
    let candidates = try JSONDecoder().decode(
      [CompositeMediaDescriptor].self,
      from: Data(input.descriptorsJSON.utf8)
    )
    let locator = try RemoteLocator(
      sourceUID: input.file.sourceUID,
      path: RemotePath(input.file.relativePath)
    )
    guard !candidates.isEmpty,
      candidates.allSatisfy({ $0.locator == locator && $0.confidence == .candidate })
    else {
      throw SDKError(code: .parseFailure, message: "disc candidate cache input is invalid")
    }
    self.locator = locator
    sizeBytes = input.file.sizeBytes
    modifiedAtMilliseconds = input.file.modifiedAtMilliseconds
    entityTag = input.file.entityTag
    inputRevision = input.inputRevision
    self.candidates = candidates
  }
}

/// A current cached deep-probe state returned to library and playback UI.
public enum DiscMediaProbeCacheEntry: Equatable, Sendable {
  case confirmed(DiscMediaProbeResult)
  case failed(DiscMediaProbeFailure)
}

/// Result of processing one revision-safe optical-disc queue lease.
public enum DiscMediaProbeProcessingResult: Equatable, Sendable {
  case notCompositeMedia
  case cacheHit(DiscMediaProbeResult)
  case probed(DiscMediaProbeResult)
  case failed(DiscMediaProbeFailure)
}

/// High-level, source-independent optical-disc probe and SQLite cache coordinator.
public struct DiscMediaLibrary: Sendable {
  public let store: LibraryStore

  public init(store: LibraryStore) {
    self.store = store
  }

  /// Enqueues only composite files whose exact material revision lacks a durable result.
  @discardableResult
  public func enqueueMissingProbeWork(
    sourceUID: String,
    priority: Int = -150,
    limit: Int = 200,
    retryTerminalFailures: Bool = false
  ) async throws -> Int {
    try await store.enqueueMissingCompositeMediaProbeWork(
      sourceUID: sourceUID,
      selectionRuleVersion: DiscPlaylistSelectionRule.currentVersion,
      priority: priority,
      limit: limit,
      retryTerminalFailures: retryTerminalFailures
    )
  }

  /// Returns a typed target for a current `.probe` lease, or nil for an ordinary media file.
  public func target(for lease: LibraryScanWorkLease) async throws -> DiscMediaProbeTarget? {
    try await store.compositeMediaProbeInput(for: lease).map(DiscMediaProbeTarget.init)
  }

  /// Reads a cache entry only when source identity, size, mtime, etag, material revision, and
  /// playlist-selection rule still match the published file.
  public func cachedState(
    sourceUID: String,
    relativePath: String
  ) async throws -> DiscMediaProbeCacheEntry? {
    guard
      let record = try await store.cachedCompositeMediaProbe(
        sourceUID: sourceUID,
        relativePath: relativePath,
        selectionRuleVersion: DiscPlaylistSelectionRule.currentVersion
      )
    else { return nil }
    if record.status == .confirmed {
      guard let json = record.resultJSON else {
        throw SDKError(code: .storageFailure, message: "disc probe cache is incomplete")
      }
      return .confirmed(
        try JSONDecoder().decode(DiscMediaProbeResult.self, from: Data(json.utf8))
      )
    }
    guard let failure = Self.failure(from: record.status) else {
      throw SDKError(code: .storageFailure, message: "disc probe cache status is invalid")
    }
    return .failed(failure)
  }

  /// Probes and persists one optical disc. Routine format/source failures are returned as data;
  /// storage, lease, and validation failures still throw.
  public func process(
    _ lease: LibraryScanWorkLease,
    using session: any MediaSourceSession,
    readTimeoutMilliseconds: Int = 30_000,
    useSuccessfulCache: Bool = true
  ) async throws -> DiscMediaProbeProcessingResult {
    guard let target = try await target(for: lease) else { return .notCompositeMedia }
    if useSuccessfulCache,
      case .confirmed(let cached)? = try await cachedState(
        sourceUID: target.locator.sourceUID,
        relativePath: target.locator.path.relativePath
      )
    {
      try await store.completeScanWork(lease)
      return .cacheHit(cached)
    }

    do {
      let result = try await probe(
        target,
        using: session,
        readTimeoutMilliseconds: readTimeoutMilliseconds
      )
      try await persist(result, completing: lease)
      return .probed(result)
    } catch let error as SDKError where error.code == .conflict || error.code == .storageFailure {
      throw error
    } catch {
      let failure = Self.classify(error)
      try await persist(failure, completing: lease)
      return .failed(failure)
    }
  }

  /// Performs an uncached deep probe while preserving ambiguous structural candidates.
  public func probe(
    _ target: DiscMediaProbeTarget,
    using session: any MediaSourceSession,
    readTimeoutMilliseconds: Int = 30_000
  ) async throws -> DiscMediaProbeResult {
    var lastError: (any Error)?
    for candidate in target.candidates {
      do {
        switch candidate.container {
        case .diskImage:
          let entry = try await session.stat(candidate.locator)
          return try await BDMVIOContextRemoteImageProbe().probe(
            entry: entry,
            candidate: candidate,
            using: session,
            readTimeoutMilliseconds: readTimeoutMilliseconds
          )
        case .directory:
          return try await BDMVIOContextRemoteDirectoryProbe().probe(
            candidate: candidate,
            using: session,
            readTimeoutMilliseconds: readTimeoutMilliseconds
          )
        }
      } catch {
        lastError = error
        let failure = Self.classify(error)
        if failure == .remoteUnavailable || failure == .cancelled || failure == .unsupported {
          break
        }
      }
    }
    throw lastError
      ?? SDKError(code: .parseFailure, message: "disc contains no supported playlist")
  }

  private func persist(
    _ result: DiscMediaProbeResult,
    completing lease: LibraryScanWorkLease
  ) async throws {
    guard result.selectionRuleVersion == DiscPlaylistSelectionRule.currentVersion,
      result.descriptor.locator.sourceUID == lease.file.sourceUID,
      result.descriptor.locator.path.relativePath == lease.file.relativePath
    else {
      throw SDKError(code: .conflict, message: "disc probe result does not match its lease")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let json = String(decoding: try encoder.encode(result), as: UTF8.self)
    let record = try LibraryCompositeMediaProbeRecord(
      inputRevision: lease.inputRevision,
      inputSizeBytes: lease.file.sizeBytes,
      inputModifiedAtMilliseconds: lease.file.modifiedAtMilliseconds,
      inputEntityTag: lease.file.entityTag,
      selectionRuleVersion: result.selectionRuleVersion,
      status: .confirmed,
      resultJSON: json
    )
    try await store.persistCompositeMediaProbe(
      record,
      technicalProbe: try Self.technicalProbe(from: result),
      completing: lease,
      disposition: .complete
    )
  }

  private func persist(
    _ failure: DiscMediaProbeFailure,
    completing lease: LibraryScanWorkLease
  ) async throws {
    let record = try LibraryCompositeMediaProbeRecord(
      inputRevision: lease.inputRevision,
      inputSizeBytes: lease.file.sizeBytes,
      inputModifiedAtMilliseconds: lease.file.modifiedAtMilliseconds,
      inputEntityTag: lease.file.entityTag,
      selectionRuleVersion: DiscPlaylistSelectionRule.currentVersion,
      status: Self.storageStatus(from: failure),
      resultJSON: nil
    )
    let disposition: LibraryCompositeMediaProbeDisposition
    switch failure {
    case .unsupported, .corruptStructure, .encrypted:
      disposition = .fail(errorCode: Self.sdkErrorCode(from: failure))
    case .cancelled:
      disposition = .retry(errorCode: .cancelled, afterMilliseconds: 0)
    case .remoteUnavailable:
      let delay = min(300_000, 5_000 * Int64(1 << min(lease.attempts, 5)))
      disposition = .retry(errorCode: .remoteUnavailable, afterMilliseconds: delay)
    case .dependencyFailure:
      if lease.attempts + 1 >= 3 {
        disposition = .fail(errorCode: .unknown)
      } else {
        let delay = min(300_000, 5_000 * Int64(1 << min(lease.attempts, 5)))
        disposition = .retry(errorCode: .unknown, afterMilliseconds: delay)
      }
    }
    try await store.persistCompositeMediaProbe(
      record,
      technicalProbe: nil,
      completing: lease,
      disposition: disposition
    )
  }

  private static func technicalProbe(
    from result: DiscMediaProbeResult
  ) throws -> LibraryTechnicalProbeRecord {
    let selected = result.playlists.first(where: \.isSelected)
    let summary = LibraryTechnicalSummaryRecord(
      container: result.descriptor.kind.rawValue,
      durationMilliseconds: selected?.durationMilliseconds
    )
    var streams: [LibraryTechnicalStreamRecord] = []
    streams.reserveCapacity(result.audioLanguages.count + result.subtitleLanguages.count)
    for language in result.audioLanguages {
      streams.append(
        try LibraryTechnicalStreamRecord(
          streamIndex: streams.count,
          kind: "audio",
          language: language.languageCode,
          title: "PID \(language.packetIdentifier)"
        )
      )
    }
    for language in result.subtitleLanguages {
      streams.append(
        try LibraryTechnicalStreamRecord(
          streamIndex: streams.count,
          kind: "subtitle",
          language: language.languageCode,
          title: "PID \(language.packetIdentifier)"
        )
      )
    }
    return try LibraryTechnicalProbeRecord(
      summary: summary,
      streams: streams,
      probeProvider: "bdmviocontext",
      probeVersion: result.selectionRuleVersion
    )
  }

  package static func classify(_ error: any Error) -> DiscMediaProbeFailure {
    if error is CancellationError { return .cancelled }
    guard let sdkError = error as? SDKError else {
      let description = String(describing: error).lowercased()
      if description.contains("encrypt") || description.contains("aacs")
        || description.contains("css")
      {
        return .encrypted
      }
      return .dependencyFailure
    }
    let message = sdkError.message.lowercased()
    if message.contains("encrypt") || message.contains("aacs") || message.contains("css") {
      return .encrypted
    }
    if message.contains("does not support") || message.contains("unsupported") {
      return .unsupported
    }
    switch sdkError.code {
    case .cancelled: return .cancelled
    case .networkUnavailable, .remoteUnavailable, .rateLimited: return .remoteUnavailable
    case .parseFailure, .metadataNotFound: return .corruptStructure
    case .invalidConfiguration: return .unsupported
    default: return .dependencyFailure
    }
  }

  private static func storageStatus(
    from failure: DiscMediaProbeFailure
  ) -> LibraryCompositeMediaProbeStatus {
    switch failure {
    case .unsupported: .unsupported
    case .corruptStructure: .corruptStructure
    case .encrypted: .encrypted
    case .cancelled: .cancelled
    case .remoteUnavailable: .remoteUnavailable
    case .dependencyFailure: .dependencyFailure
    }
  }

  private static func failure(
    from status: LibraryCompositeMediaProbeStatus
  ) -> DiscMediaProbeFailure? {
    switch status {
    case .confirmed: nil
    case .unsupported: .unsupported
    case .corruptStructure: .corruptStructure
    case .encrypted: .encrypted
    case .cancelled: .cancelled
    case .remoteUnavailable: .remoteUnavailable
    case .dependencyFailure: .dependencyFailure
    }
  }

  private static func sdkErrorCode(from failure: DiscMediaProbeFailure) -> SDKErrorCode {
    switch failure {
    case .unsupported: .invalidConfiguration
    case .corruptStructure, .encrypted: .parseFailure
    case .cancelled: .cancelled
    case .remoteUnavailable: .remoteUnavailable
    case .dependencyFailure: .unknown
    }
  }
}

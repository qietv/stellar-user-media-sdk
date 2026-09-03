import Foundation
import StellarCore
import StellarRemoteMedia
import StellarStorage

/// A `MediaScanSink` that commits scanner state and file facts to `library.sqlite`.
public struct SQLiteMediaScanSink: MediaScanSink, Sendable {
  public let store: LibraryStore

  /// Small directory pages share a transaction; entry buffering remains capped by the scanner's
  /// configured page size.
  public var preferredPageCommitBatchSize: Int { 32 }

  public init(store: LibraryStore) {
    self.store = store
  }

  public func commit(_ batch: MediaScanBatch) async throws {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let checkpointJSON = String(
        decoding: try encoder.encode(batch.checkpoint),
        as: UTF8.self
      )
      let coverageJSON = String(
        decoding: try encoder.encode(ScanCoverage(roots: batch.checkpoint.request.roots)),
        as: UTF8.self
      )
      let persistenceBatch = try LibraryScanPersistenceBatch(
        runUID: batch.checkpoint.request.runUID,
        sourceUID: batch.checkpoint.request.sourceUID,
        mode: batch.checkpoint.request.mode.rawValue,
        state: batch.checkpoint.phase.rawValue,
        checkpointJSON: checkpointJSON,
        coverageJSON: coverageJSON,
        entries: batch.entries,
        compositeMedia: try Self.persistenceCompositeMedia(
          batch.compositeMedia,
          encoder: encoder
        ),
        capabilities: batch.checkpoint.capabilities,
        coveredRoots: batch.completion?.coveredRoots ?? [],
        reconcileMissingEligible: batch.completion?.reconcileMissingEligible ?? false,
        discoveredEntryCount: batch.checkpoint.discoveredEntryCount,
        pendingPageCount: batch.checkpoint.pendingPageCount,
        processedPageCount: batch.checkpoint.processedPageCount,
        errorCode: batch.checkpoint.lastErrorCode?.rawValue,
        enumerationState: try batch.enumerationState.map(Self.persistenceState),
        pageTransitions: try batch.pageTransitions.map(Self.persistenceTransition)
      )
      try await store.commit(persistenceBatch)
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "scanner checkpoint encoding failed")
    }
  }

  private static func persistenceCompositeMedia(
    _ detections: [CompositeMediaDetection],
    encoder: JSONEncoder
  ) throws -> [LibraryScanCompositeMedia] {
    let grouped = Dictionary(grouping: detections, by: { $0.descriptor.locator })
    return try grouped.keys.sorted(by: {
      $0.path.relativePath < $1.path.relativePath
    }).map { locator in
      let descriptors = grouped[locator, default: []].map(\.descriptor).sorted {
        Self.descriptorSortKey($0) < Self.descriptorSortKey($1)
      }
      return try LibraryScanCompositeMedia(
        locator: locator,
        descriptorsJSON: String(decoding: try encoder.encode(descriptors), as: UTF8.self)
      )
    }
  }

  private static func descriptorSortKey(_ descriptor: CompositeMediaDescriptor) -> String {
    [
      descriptor.kind.rawValue,
      descriptor.container.rawValue,
      descriptor.confidence.rawValue,
      descriptor.logicalRoot.path.relativePath,
      descriptor.entryPoint?.path.relativePath ?? "",
    ].joined(separator: "\0")
  }

  /// Loads a previously committed scanner checkpoint for resumable enumeration.
  public func loadCheckpoint(runUID: String) async throws -> MediaScanCheckpoint? {
    guard let json = try await store.checkpointJSON(runUID: runUID) else {
      return nil
    }
    return try Self.decodeCheckpoint(json)
  }

  /// Loads the newest resumable checkpoint for a source after an app or worker restart.
  ///
  /// A completed newer run suppresses older failed or cancelled runs, so callers cannot
  /// accidentally publish stale discovery state by reviving superseded work.
  public func loadLatestRecoverableCheckpoint(
    sourceUID: String
  ) async throws -> MediaScanCheckpoint? {
    guard let json = try await store.latestRecoverableCheckpointJSON(sourceUID: sourceUID) else {
      return nil
    }
    let checkpoint = try Self.decodeCheckpoint(json)
    guard checkpoint.request.sourceUID == sourceUID, checkpoint.phase != .completed else {
      throw SDKError(code: .storageFailure, message: "stored scan recovery checkpoint is invalid")
    }
    return checkpoint
  }

  private static func decodeCheckpoint(_ json: String) throws -> MediaScanCheckpoint {
    do {
      return try JSONDecoder().decode(MediaScanCheckpoint.self, from: Data(json.utf8))
    } catch {
      if let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
        object["schema_version"] as? Int == 1
      {
        throw SDKError(
          code: .conflict,
          message: "legacy scanner checkpoint requires a new scan run"
        )
      }
      throw SDKError(code: .storageFailure, message: "stored scanner checkpoint is invalid")
    }
  }

  public func loadEnumerationState(runUID: String) async throws -> MediaScanEnumerationState? {
    guard let state = try await store.scanEnumerationState(runUID: runUID) else { return nil }
    return try MediaScanEnumerationState(
      pendingPages: state.pendingPages.map(Self.scannerPage),
      completedPages: state.completedPages.map(Self.scannerPage),
      seenEntryIdentityKeys: state.seenEntryIdentityKeys,
      seenDirectoryIdentityKeys: state.seenDirectoryIdentityKeys
    )
  }

  private static func persistenceState(
    _ state: MediaScanEnumerationState
  ) throws -> LibraryScanEnumerationState {
    try LibraryScanEnumerationState(
      pendingPages: state.pendingPages.map(persistencePage),
      completedPages: state.completedPages.map(persistencePage),
      seenEntryIdentityKeys: state.seenEntryIdentityKeys,
      seenDirectoryIdentityKeys: state.seenDirectoryIdentityKeys
    )
  }

  private static func persistenceTransition(
    _ transition: MediaScanPageTransition
  ) throws -> LibraryScanPageTransition {
    LibraryScanPageTransition(
      completedPage: try persistencePage(transition.completedPage),
      enqueuedPages: try transition.enqueuedPages.map(persistencePage),
      seenEntryIdentityKeys: transition.seenEntryIdentityKeys,
      seenDirectoryIdentityKeys: transition.seenDirectoryIdentityKeys
    )
  }

  private static func persistencePage(
    _ page: MediaScanPageCursor
  ) throws -> LibraryScanFrontierPage {
    try LibraryScanFrontierPage(directory: page.directory, cursor: page.cursor)
  }

  private static func scannerPage(
    _ page: LibraryScanFrontierPage
  ) throws -> MediaScanPageCursor {
    try MediaScanPageCursor(directory: page.directory, cursor: page.cursor)
  }
}

private struct ScanCoverage: Encodable {
  let schemaVersion = 1
  let roots: [RemoteLocator]

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case roots
  }
}

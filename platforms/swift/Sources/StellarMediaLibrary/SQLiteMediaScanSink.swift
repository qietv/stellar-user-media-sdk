import Foundation
import StellarCore
import StellarRemoteMedia
import StellarStorage

/// A `MediaScanSink` that commits scanner state and file facts to `library.sqlite`.
public struct SQLiteMediaScanSink: MediaScanSink, Sendable {
  public let store: LibraryStore

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
        capabilities: batch.checkpoint.capabilities,
        coveredRoots: batch.completion?.coveredRoots ?? [],
        reconcileMissingEligible: batch.completion?.reconcileMissingEligible ?? false,
        discoveredEntryCount: batch.checkpoint.discoveredEntryCount,
        errorCode: batch.checkpoint.lastErrorCode?.rawValue
      )
      try await store.commit(persistenceBatch)
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "scanner checkpoint encoding failed")
    }
  }

  /// Loads a previously committed scanner checkpoint for resumable enumeration.
  public func loadCheckpoint(runUID: String) async throws -> MediaScanCheckpoint? {
    guard let json = try await store.checkpointJSON(runUID: runUID) else {
      return nil
    }
    do {
      return try JSONDecoder().decode(MediaScanCheckpoint.self, from: Data(json.utf8))
    } catch {
      throw SDKError(code: .storageFailure, message: "stored scanner checkpoint is invalid")
    }
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

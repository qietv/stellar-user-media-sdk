import Foundation
import StellarUserMediaSDK

enum ManifestCLICommand {
  static func run(arguments: [String]) async -> Int32 {
    guard arguments.count == 2, arguments[0] == "replay" else {
      writeError("manifest expects replay <fixture-path>")
      return 2
    }

    do {
      let fixture = try JSONDecoder().decode(
        ScannerManifestFixture.self,
        from: Data(contentsOf: URL(fileURLWithPath: arguments[1]))
      )
      guard fixture.schemaVersion == 1 else {
        throw SDKError(code: .invalidConfiguration, message: "unsupported manifest schema")
      }

      var snapshots: [ManifestReplaySnapshot] = []
      for scenario in fixture.scenarios {
        let sink = ManifestScanSink()
        let connector = ManifestConnector(
          sourceUID: fixture.sourceUID,
          capabilities: fixture.capabilities,
          pages: scenario.pages,
          failureRequest: scenario.failureRequest
        )
        let pageSize = scenario.pages.first?.request.limit ?? 500
        let scanner = MediaScanner(
          configuration: try MediaScannerConfiguration(
            pageSize: pageSize,
            maxConcurrentDirectoryRequests: 1
          )
        )
        do {
          _ = try await scanner.scan(scenario.request, using: connector, sink: sink)
        } catch {
          guard scenario.expected.phase == .failed || scenario.expected.phase == .cancelled else {
            throw error
          }
        }
        let checkpoint = try await sink.requiredCheckpoint()
        let snapshot = await sink.snapshot(name: scenario.name, checkpoint: checkpoint)
        guard snapshot.matches(scenario.expected) else {
          throw SDKError(code: .conflict, message: "scan manifest snapshot mismatch")
        }
        snapshots.append(snapshot)
      }

      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let data = try encoder.encode(
        ManifestReplayOutput(schema: "stellar.scan-manifest-replay.v1", snapshots: snapshots)
      )
      guard let output = String(data: data, encoding: .utf8) else {
        throw SDKError(code: .parseFailure, message: "manifest output is not UTF-8")
      }
      print(output)
      return 0
    } catch let error as SDKError {
      writeError(error.message)
      return 1
    } catch {
      writeError("failed to replay scan manifest")
      return 1
    }
  }

  private static func writeError(_ message: String) {
    let safeMessage = SensitiveDataRedactor().redact(message: message)
    FileHandle.standardError.write(Data("error: \(safeMessage)\n".utf8))
  }
}

private struct ScannerManifestFixture: Decodable, Sendable {
  let schemaVersion: Int
  let sourceUID: String
  let capabilities: MediaSourceCapabilities
  let scenarios: [ManifestScenario]

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case sourceUID = "source_uid"
    case capabilities
    case scenarios
  }
}

private struct ManifestScenario: Decodable, Sendable {
  let name: String
  let request: MediaScanRequest
  let pages: [ManifestPage]
  let failureRequest: RemoteDirectoryPageRequest?
  let expected: ManifestExpected

  private enum CodingKeys: String, CodingKey {
    case name
    case request
    case pages
    case failureRequest = "failure_request"
    case expected
  }
}

private struct ManifestPage: Decodable, Sendable {
  let request: RemoteDirectoryPageRequest
  let response: CursorPage<RemoteEntry>
}

private struct ManifestExpected: Decodable, Sendable {
  let phase: MediaScanPhase
  let reconcileMissingEligible: Bool
  let discoveredEntryCount: Int64
  let processedPageCount: Int64
  let entryIdentityKeys: [String]

  private enum CodingKeys: String, CodingKey {
    case phase
    case reconcileMissingEligible = "reconcile_missing_eligible"
    case discoveredEntryCount = "discovered_entry_count"
    case processedPageCount = "processed_page_count"
    case entryIdentityKeys = "entry_identity_keys"
  }
}

private struct ManifestReplayOutput: Encodable {
  let schema: String
  let snapshots: [ManifestReplaySnapshot]
}

private struct ManifestReplaySnapshot: Encodable {
  let name: String
  let phase: MediaScanPhase
  let reconcileMissingEligible: Bool
  let discoveredEntryCount: Int64
  let processedPageCount: Int64
  let entryIdentityKeys: [String]

  func matches(_ expected: ManifestExpected) -> Bool {
    phase == expected.phase
      && reconcileMissingEligible == expected.reconcileMissingEligible
      && discoveredEntryCount == expected.discoveredEntryCount
      && processedPageCount == expected.processedPageCount
      && entryIdentityKeys == expected.entryIdentityKeys
  }

  private enum CodingKeys: String, CodingKey {
    case name
    case phase
    case reconcileMissingEligible = "reconcile_missing_eligible"
    case discoveredEntryCount = "discovered_entry_count"
    case processedPageCount = "processed_page_count"
    case entryIdentityKeys = "entry_identity_keys"
  }
}

private actor ManifestScanSink: MediaScanSink {
  private var checkpoint: MediaScanCheckpoint?
  private var completion: MediaScanCompletion?
  private var entries: [String: RemoteEntry] = [:]

  func commit(_ batch: MediaScanBatch) async throws {
    for entry in batch.entries {
      let identity =
        entry.stableID.map { "stable:\($0)" }
        ?? "path:\(entry.locator.path.relativePath)"
      entries[identity] = entry
    }
    checkpoint = batch.checkpoint
    if let completion = batch.completion {
      self.completion = completion
    }
  }

  func requiredCheckpoint() throws -> MediaScanCheckpoint {
    guard let checkpoint else {
      throw SDKError(code: .storageFailure, message: "manifest checkpoint is missing")
    }
    return checkpoint
  }

  func snapshot(name: String, checkpoint: MediaScanCheckpoint) -> ManifestReplaySnapshot {
    ManifestReplaySnapshot(
      name: name,
      phase: checkpoint.phase,
      reconcileMissingEligible: completion?.reconcileMissingEligible ?? false,
      discoveredEntryCount: checkpoint.discoveredEntryCount,
      processedPageCount: checkpoint.processedPageCount,
      entryIdentityKeys: entries.keys.sorted()
    )
  }
}

private actor ManifestConnector: MediaSourceConnector {
  private let session: ManifestSession

  init(
    sourceUID: String,
    capabilities: MediaSourceCapabilities,
    pages: [ManifestPage],
    failureRequest: RemoteDirectoryPageRequest?
  ) {
    session = ManifestSession(
      sourceUID: sourceUID,
      capabilities: capabilities,
      pages: pages,
      failureRequest: failureRequest
    )
  }

  func connect() async throws -> any MediaSourceSession { session }
}

private actor ManifestSession: MediaSourceSession {
  nonisolated let sourceUID: String
  nonisolated let capabilities: MediaSourceCapabilities
  private let pages: [RemoteDirectoryPageRequest: CursorPage<RemoteEntry>]
  private let failureRequest: RemoteDirectoryPageRequest?
  private var hasFailed = false

  init(
    sourceUID: String,
    capabilities: MediaSourceCapabilities,
    pages: [ManifestPage],
    failureRequest: RemoteDirectoryPageRequest?
  ) {
    self.sourceUID = sourceUID
    self.capabilities = capabilities
    self.pages = Dictionary(uniqueKeysWithValues: pages.map { ($0.request, $0.response) })
    self.failureRequest = failureRequest
  }

  func listDirectory(_ request: RemoteDirectoryPageRequest) async throws
    -> CursorPage<RemoteEntry>
  {
    if request == failureRequest, !hasFailed {
      hasFailed = true
      throw SDKError(code: .remoteUnavailable, message: "manifest page interruption")
    }
    guard let page = pages[request] else {
      throw SDKError(code: .metadataNotFound, message: "manifest page was not found")
    }
    return page
  }

  func stat(_ locator: RemoteLocator) async throws -> RemoteEntry {
    guard locator.sourceUID == sourceUID else {
      throw SDKError(code: .metadataNotFound, message: "manifest root was not found")
    }
    return try RemoteEntry(
      locator: locator,
      kind: .directory,
      stableID: locator.path.isRoot ? "manifest-root" : "manifest-scope"
    )
  }

  func read(at _: RemoteLocator, range _: RemoteByteRange) async throws -> Data {
    throw SDKError(code: .metadataNotFound, message: "manifest read is unsupported")
  }

  func disconnect() async {}
}

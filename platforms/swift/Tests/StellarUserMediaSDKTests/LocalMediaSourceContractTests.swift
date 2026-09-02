import Foundation
import StellarCore
import StellarLocalMedia
import StellarMediaLibrary
import StellarRemoteMedia
import Testing

@Suite("Local media source contracts", .serialized)
struct LocalMediaSourceContractTests {
  @Test("Local connector paginates, stats, range-reads, and confines symlinks")
  func connectorOperations() async throws {
    let fixture = try LocalDirectoryFixture()
    defer { fixture.remove() }
    let configuration = try LocalMediaSourceConfiguration(
      sourceUID: "local-fixture-1",
      rootURL: fixture.rootURL,
      pathSemantics: RemotePathSemantics(
        caseSensitivity: .sensitive,
        unicodeNormalization: .preserve
      )
    )
    let connector = LocalMediaSourceConnector(configuration: configuration)
    let session = try await connector.connect()
    let root = try RemoteLocator(sourceUID: configuration.sourceUID, path: RemotePath())
    let rootEntry = try await session.stat(root)
    let capabilities = await session.capabilities

    #expect(configuration.description.contains(fixture.rootURL.path) == false)
    #expect(rootEntry.kind == .directory)
    #expect(rootEntry.stableID != nil)
    #expect(capabilities.stableIDScope == .scan)
    #expect(capabilities.supportsRangeReads)

    var entries: [RemoteEntry] = []
    var cursor: String?
    repeat {
      let page = try await session.listDirectory(
        RemoteDirectoryPageRequest(directory: root, cursor: cursor, limit: 2)
      )
      entries.append(contentsOf: page.items)
      cursor = page.nextCursor
    } while cursor != nil

    #expect(
      entries.map(\.locator.path.relativePath).sorted() == [
        ".hidden",
        "Arrival.mkv",
        "Escape",
        "Series",
        "三体.mkv",
      ])
    #expect(entries.first(where: { $0.locator.path.name == "Escape" })?.kind == .symbolicLink)

    let arrival = try #require(
      entries.first(where: { $0.locator.path.name == "Arrival.mkv" })
    )
    let stat = try await session.stat(arrival.locator)
    let data = try await session.read(
      at: arrival.locator,
      range: RemoteByteRange(offset: 1, length: 3)
    )
    #expect(stat.stableID == arrival.stableID)
    #expect(stat.size == 7)
    #expect(String(decoding: data, as: UTF8.self) == "rri")

    let escape = try #require(entries.first(where: { $0.locator.path.name == "Escape" }))
    await #expect(throws: SDKError.self) {
      _ = try await session.stat(escape.locator)
    }

    await session.disconnect()
    await #expect(throws: SDKError.self) {
      _ = try await session.listDirectory(
        RemoteDirectoryPageRequest(directory: root, limit: 2)
      )
    }
  }

  @Test("Local pagination keeps a stable snapshot and validates resumed cursors")
  func paginationMutation() async throws {
    let fixture = try LocalDirectoryFixture()
    defer { fixture.remove() }
    let connector = LocalMediaSourceConnector(
      configuration: try LocalMediaSourceConfiguration(
        sourceUID: "local-fixture-mutation",
        rootURL: fixture.rootURL
      )
    )
    let session = try await connector.connect()
    let root = try RemoteLocator(sourceUID: "local-fixture-mutation", path: RemotePath())
    let firstPage = try await session.listDirectory(
      RemoteDirectoryPageRequest(directory: root, limit: 2)
    )
    let cursor = try #require(firstPage.nextCursor)
    try Data("new".utf8).write(to: fixture.rootURL.appendingPathComponent("New.mkv"))

    let remainingPage = try await session.listDirectory(
      RemoteDirectoryPageRequest(directory: root, cursor: cursor, limit: 100)
    )
    #expect(remainingPage.nextCursor == nil)
    #expect(remainingPage.items.contains(where: { $0.locator.path.name == "New.mkv" }) == false)
    await session.disconnect()

    let resumedSession = try await connector.connect()
    await #expect(throws: SDKError.self) {
      _ = try await resumedSession.listDirectory(
        RemoteDirectoryPageRequest(directory: root, cursor: cursor, limit: 2)
      )
    }
    await resumedSession.disconnect()
  }

  @Test("The shared scanner completes a recursive local directory scan")
  func scannerIntegration() async throws {
    let fixture = try LocalDirectoryFixture()
    defer { fixture.remove() }
    let sourceUID = "local-scanner-fixture"
    let connector = LocalMediaSourceConnector(
      configuration: try LocalMediaSourceConfiguration(
        sourceUID: sourceUID,
        rootURL: fixture.rootURL,
        pathSemantics: RemotePathSemantics(
          caseSensitivity: .sensitive,
          unicodeNormalization: .preserve
        )
      )
    )
    let root = try RemoteLocator(sourceUID: sourceUID, path: RemotePath())
    let request = try MediaScanRequest(
      runUID: "local-full-scan",
      sourceUID: sourceUID,
      mode: .full,
      roots: [root]
    )
    let sink = LocalRecordingScanSink()
    let scanner = MediaScanner(
      configuration: try MediaScannerConfiguration(
        pageSize: 2,
        maxConcurrentDirectoryRequests: 2
      )
    )

    let result = try await scanner.scan(request, using: connector, sink: sink)

    #expect(result.checkpoint.phase == .completed)
    #expect(result.completion.reconcileMissingEligible)
    #expect(result.checkpoint.processedPageCount == 4)
    #expect(
      await sink.paths == [
        ".hidden",
        "Arrival.mkv",
        "Escape",
        "Series",
        "Series/Foundation.S01E01.mkv",
        "三体.mkv",
      ])
    #expect(await sink.completion == result.completion)
  }
}

private final class LocalDirectoryFixture: @unchecked Sendable {
  let baseURL: URL
  let rootURL: URL

  init() throws {
    baseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("stellar-local-fixture-\(UUID().uuidString)", isDirectory: true)
    rootURL = baseURL.appendingPathComponent("Media", isDirectory: true)
    let seriesURL = rootURL.appendingPathComponent("Series", isDirectory: true)
    try FileManager.default.createDirectory(
      at: seriesURL,
      withIntermediateDirectories: true
    )
    try Data("Arrival".utf8).write(to: rootURL.appendingPathComponent("Arrival.mkv"))
    try Data("hidden".utf8).write(to: rootURL.appendingPathComponent(".hidden"))
    try Data("three-body".utf8).write(to: rootURL.appendingPathComponent("三体.mkv"))
    try Data("Foundation".utf8).write(
      to: seriesURL.appendingPathComponent("Foundation.S01E01.mkv")
    )
    let outsideURL = baseURL.appendingPathComponent("Outside.mkv")
    try Data("outside".utf8).write(to: outsideURL)
    try FileManager.default.createSymbolicLink(
      at: rootURL.appendingPathComponent("Escape"),
      withDestinationURL: outsideURL
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: baseURL)
  }
}

private actor LocalRecordingScanSink: MediaScanSink {
  private var entries: [String: RemoteEntry] = [:]
  private(set) var completion: MediaScanCompletion?

  var paths: [String] {
    entries.values.map(\.locator.path.relativePath).sorted()
  }

  func commit(_ batch: MediaScanBatch) async throws {
    for entry in batch.entries {
      let key = entry.stableID ?? "path:\(entry.locator.path.relativePath)"
      entries[key] = entry
    }
    if let completion = batch.completion {
      self.completion = completion
    }
  }
}

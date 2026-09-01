import Foundation
import StellarCore
import StellarRemoteMedia
import Testing

@Suite("Remote enumeration contracts")
struct RemoteEnumerationContractTests {
  @Test("Shared enumeration fixture preserves paths, capabilities, and pages")
  func sharedEnumerationFixture() throws {
    let fixture = try loadFixture()

    #expect(fixture.schemaVersion == 1)
    #expect(fixture.sourceUID == "source-fixture-1")
    #expect(fixture.capabilities.stableIDScope == .persistent)
    #expect(fixture.capabilities.pathSemantics.caseSensitivity == .insensitive)
    #expect(fixture.capabilities.pathSemantics.unicodeNormalization == .nfc)
    #expect(fixture.capabilities.preferredDirectoryRequestConcurrency == 4)
    #expect(fixture.pages.count == 3)

    for pathCase in fixture.pathCases {
      let path = try RemotePath(pathCase.input)
      #expect(path.relativePath == pathCase.normalized)
      #expect(
        path.comparisonKey(using: fixture.capabilities.pathSemantics) == pathCase.compareKey
      )
    }

    #expect(fixture.pages[0].response.nextCursor == "root-page-2")
    #expect(fixture.pages[1].response.nextCursor == nil)
    #expect(fixture.pages[0].response.items[1].stableID == "directory-movies")
    #expect(fixture.pages[2].response.items[0].locator.path.name == "Café.mkv")
  }

  @Test("Paths reject traversal and compare scope by components")
  func remotePathSafety() throws {
    #expect(throws: SDKError.self) { _ = try RemotePath("/Movies") }
    #expect(throws: SDKError.self) { _ = try RemotePath("Movies/../Secrets") }
    #expect(throws: SDKError.self) { _ = try RemotePath("Movies/Bad\0Name") }
    #expect(throws: SDKError.self) { _ = try RemotePath().appending(component: "A/B") }

    let semantics = RemotePathSemantics(
      caseSensitivity: .insensitive,
      unicodeNormalization: .nfc
    )
    let movies = try RemotePath("Movies")
    let child = try RemotePath("movies/A")
    let siblingPrefix = try RemotePath("MoviesArchive/A")
    let composed = try RemotePath("Movies/Café.mkv")
    let decomposed = try RemotePath("movies/Café.mkv")

    #expect(child.isDescendant(of: movies, using: semantics))
    #expect(siblingPrefix.isDescendant(of: movies, using: semantics) == false)
    #expect(composed.comparisonKey(using: semantics) == decomposed.comparisonKey(using: semantics))
  }

  @Test("Unknown connector enums degrade safely")
  func unknownEnums() throws {
    let decoder = JSONDecoder()
    #expect(
      try decoder.decode(
        RemotePathCaseSensitivity.self,
        from: Data(#""provider_default""#.utf8)
      ) == .unknown
    )
    #expect(
      try decoder.decode(RemoteStableIDScope.self, from: Data(#""volume""#.utf8)) == .unknown
    )
    #expect(
      try decoder.decode(RemoteEntryKind.self, from: Data(#""socket""#.utf8)) == .unknown
    )
  }

  @Test("Capability and page request invariants reject unsafe input")
  func validation() throws {
    let root = try RemoteLocator(sourceUID: "source-1", path: RemotePath())
    let baseline = try MediaSourceCapabilities(
      stableIDScope: .persistent,
      pathSemantics: RemotePathSemantics(
        caseSensitivity: .sensitive,
        unicodeNormalization: .preserve
      ),
      supportsRangeReads: true,
      supportsChangeCursor: false,
      deltaDeletionsComplete: false,
      preferredDirectoryRequestConcurrency: 4
    )
    let differentPerformanceHints = try MediaSourceCapabilities(
      stableIDScope: .persistent,
      pathSemantics: baseline.pathSemantics,
      supportsRangeReads: false,
      supportsChangeCursor: false,
      deltaDeletionsComplete: false,
      preferredDirectoryRequestConcurrency: 1
    )
    #expect(baseline != differentPerformanceHints)
    #expect(baseline.isEnumerationResumeCompatible(with: differentPerformanceHints))
    #expect(throws: SDKError.self) {
      _ = try MediaSourceCapabilities(
        stableIDScope: .persistent,
        pathSemantics: RemotePathSemantics(
          caseSensitivity: .sensitive,
          unicodeNormalization: .preserve
        ),
        supportsRangeReads: true,
        supportsChangeCursor: false,
        deltaDeletionsComplete: true
      )
    }
    #expect(throws: SDKError.self) {
      _ = try MediaSourceCapabilities(
        stableIDScope: .none,
        pathSemantics: RemotePathSemantics(
          caseSensitivity: .sensitive,
          unicodeNormalization: .preserve
        ),
        supportsRangeReads: false,
        supportsChangeCursor: false,
        deltaDeletionsComplete: false,
        preferredDirectoryRequestConcurrency: 0
      )
    }
    #expect(throws: SDKError.self) {
      _ = try RemoteDirectoryPageRequest(directory: root, cursor: "")
    }
    #expect(throws: SDKError.self) {
      _ = try RemoteByteRange(offset: -1, length: 1)
    }
  }

  @Test("Fake connector replays pagination and exposes read-only operations")
  func fakeConnector() async throws {
    let fixture = try loadFixture()
    let session = FakeMediaSourceSession(fixture: fixture)
    let connector = FakeMediaSourceConnector(session: session)

    let connected = try await connector.connect()
    let capabilities = await connected.capabilities
    let firstPage = try await connected.listDirectory(fixture.pages[0].request)
    let secondPage = try await connected.listDirectory(fixture.pages[1].request)
    let moviePage = try await connected.listDirectory(fixture.pages[2].request)
    let arrival = try #require(moviePage.items.last)
    let stat = try await connected.stat(arrival.locator)
    let bytes = try await connected.read(
      at: arrival.locator,
      range: RemoteByteRange(offset: 1, length: 3)
    )
    await connected.disconnect()

    #expect(capabilities == fixture.capabilities)
    #expect(firstPage.items.map(\.stableID) == ["directory-series", "directory-movies"])
    #expect(secondPage.items.first?.stableID == "directory-movies")
    #expect(stat == arrival)
    #expect(String(decoding: bytes, as: UTF8.self) == "rri")
    #expect(await connector.connectionCount == 1)
    #expect(await session.isDisconnected)

    await session.failNextPage()
    await #expect(throws: SDKError.self) {
      _ = try await connected.listDirectory(fixture.pages[0].request)
    }
  }

  private func loadFixture() throws -> RemoteEnumerationFixture {
    try JSONDecoder().decode(
      RemoteEnumerationFixture.self,
      from: Data(contentsOf: sharedFixtureURL)
    )
  }

  private var sharedFixtureURL: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("specs/fixtures/media-library/remote-enumeration-v1.json")
  }
}

private struct RemoteEnumerationFixture: Decodable, Sendable {
  let schemaVersion: Int
  let sourceUID: String
  let capabilities: MediaSourceCapabilities
  let pathCases: [RemotePathCaseFixture]
  let pages: [RemotePageFixture]

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case sourceUID = "source_uid"
    case capabilities
    case pathCases = "path_cases"
    case pages
  }
}

private struct RemotePathCaseFixture: Decodable, Sendable {
  let input: String
  let normalized: String
  let compareKey: String

  private enum CodingKeys: String, CodingKey {
    case input
    case normalized
    case compareKey = "compare_key"
  }
}

private struct RemotePageFixture: Decodable, Sendable {
  let request: RemoteDirectoryPageRequest
  let response: CursorPage<RemoteEntry>
}

private struct FakeMediaSourceConnector: MediaSourceConnector {
  let session: FakeMediaSourceSession
  private let state = FakeConnectorState()

  var connectionCount: Int {
    get async { await state.connectionCount }
  }

  func connect() async throws -> any MediaSourceSession {
    await state.recordConnection()
    return session
  }
}

private actor FakeConnectorState {
  private(set) var connectionCount = 0

  func recordConnection() {
    connectionCount += 1
  }
}

private actor FakeMediaSourceSession: MediaSourceSession {
  nonisolated let sourceUID: String
  nonisolated let capabilities: MediaSourceCapabilities
  private let pages: [RemoteDirectoryPageRequest: CursorPage<RemoteEntry>]
  private let entries: [RemoteLocator: RemoteEntry]
  private var shouldFailNextPage = false
  private(set) var isDisconnected = false

  init(fixture: RemoteEnumerationFixture) {
    sourceUID = fixture.sourceUID
    capabilities = fixture.capabilities
    pages = Dictionary(uniqueKeysWithValues: fixture.pages.map { ($0.request, $0.response) })
    entries = Dictionary(
      fixture.pages
        .flatMap(\.response.items)
        .map { ($0.locator, $0) },
      uniquingKeysWith: { _, latest in latest }
    )
  }

  func listDirectory(_ request: RemoteDirectoryPageRequest) async throws
    -> CursorPage<RemoteEntry>
  {
    if shouldFailNextPage {
      shouldFailNextPage = false
      throw SDKError(code: .remoteUnavailable, message: "injected page failure")
    }
    guard request.directory.sourceUID == sourceUID, let page = pages[request] else {
      throw SDKError(code: .metadataNotFound, message: "fixture page not found")
    }
    return page
  }

  func stat(_ locator: RemoteLocator) async throws -> RemoteEntry {
    guard locator.sourceUID == sourceUID, let entry = entries[locator] else {
      throw SDKError(code: .metadataNotFound, message: "fixture entry not found")
    }
    return entry
  }

  func read(at locator: RemoteLocator, range: RemoteByteRange) async throws -> Data {
    _ = try await stat(locator)
    let data = Data("Arrival".utf8)
    let lowerBound = Int(range.offset)
    let upperBound = min(data.count, lowerBound + range.length)
    guard lowerBound < upperBound else {
      return Data()
    }
    return data.subdata(in: lowerBound..<upperBound)
  }

  func disconnect() async {
    isDisconnected = true
  }

  func failNextPage() {
    shouldFailNextPage = true
  }
}

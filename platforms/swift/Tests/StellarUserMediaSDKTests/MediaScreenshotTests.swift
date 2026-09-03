import Foundation
import StellarCore
import StellarMediaImaging
import StellarMediaLibrary
import StellarRemoteMedia
import Testing

@Suite("Media screenshots", .serialized)
struct MediaScreenshotTests {
  @Test("FFmpegKit captures a PNG from a local media file")
  func localCapture() async throws {
    let inputURL = temporaryURL(extension: "ppm")
    defer { try? FileManager.default.removeItem(at: inputURL) }
    try ppmFixture.write(to: inputURL)

    let result = try await FFmpegMediaScreenshotGenerator().capture(
      fileAt: inputURL,
      request: MediaScreenshotRequest(timestampMilliseconds: 0, format: .png)
    )

    #expect(result.format == .png)
    #expect(result.mimeType == "image/png")
    #expect(result.width == 4)
    #expect(result.height == 2)
    #expect(result.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
  }

  @Test("Remote media is read through the MediaSourceSession seam before capture")
  func remoteCapture() async throws {
    let locator = try RemoteLocator(
      sourceUID: "screenshot-fixture",
      path: RemotePath("fixture.ppm")
    )
    let session = try ScreenshotFixtureSession(locator: locator, data: ppmFixture)

    let result = try await FFmpegMediaScreenshotGenerator().capture(
      locator,
      using: session,
      request: MediaScreenshotRequest(timestampMilliseconds: 0, format: .jpeg)
    )

    #expect(result.format == .jpeg)
    #expect(result.width == 4)
    #expect(result.height == 2)
    #expect(result.data.starts(with: [0xFF, 0xD8]))
    #expect(await session.bytesRead == ppmFixture.count)
  }

  @Test("Maximum pixel dimension preserves the frame aspect ratio")
  func maximumPixelDimension() async throws {
    let inputURL = temporaryURL(extension: "ppm")
    defer { try? FileManager.default.removeItem(at: inputURL) }
    var fixture = Data("P6\n32 16\n255\n".utf8)
    fixture.append(contentsOf: repeatElement(UInt8(0x7F), count: 32 * 16 * 3))
    try fixture.write(to: inputURL)

    let result = try await FFmpegMediaScreenshotGenerator().capture(
      fileAt: inputURL,
      request: MediaScreenshotRequest(
        timestampMilliseconds: 0,
        format: .png,
        maximumPixelDimension: 16
      )
    )

    #expect(result.width == 16)
    #expect(result.height == 8)
  }

  @Test("FFmpeg technical probing uses the same seekable remote range seam")
  func remoteTechnicalProbe() async throws {
    let locator = try RemoteLocator(
      sourceUID: "probe-fixture",
      path: RemotePath("fixture.ppm")
    )
    let session = try ScreenshotFixtureSession(locator: locator, data: ppmFixture)
    let result = try await FFmpegMediaTechnicalProbe().probe(
      MediaTechnicalProbeRequest(locator: locator, sizeBytes: Int64(ppmFixture.count)),
      using: session
    )

    #expect(result.probeProvider == FFmpegMediaTechnicalProbe.provider)
    #expect(result.probeVersion == FFmpegMediaTechnicalProbe.version)
    #expect(result.streams.contains { $0.kind == .video && $0.width == 4 && $0.height == 2 })
    #expect(await session.bytesRead > 0)
  }

  @Test("Remote screenshots do not materialize an entire large source")
  func remoteCaptureDoesNotStageWholeFile() async throws {
    let reportedSize = 4 * 1_024 * 1_024
    let locator = try RemoteLocator(
      sourceUID: "large-screenshot-fixture",
      path: RemotePath("fixture.ppm")
    )
    let session = try ScreenshotFixtureSession(
      locator: locator,
      data: ppmFixture,
      reportedSize: reportedSize
    )

    _ = try await FFmpegMediaScreenshotGenerator().capture(
      locator,
      using: session,
      request: MediaScreenshotRequest(timestampMilliseconds: 0, format: .jpeg)
    )

    #expect(await session.bytesRead < reportedSize)
  }

  @Test("Playlist thumbnails compose ordered remote frames through bounded range reads")
  func remotePlaylistThumbnail() async throws {
    let locators = try (1...3).map { index in
      try RemoteLocator(
        sourceUID: "playlist-fixture",
        path: RemotePath("fixture-\(index).ppm")
      )
    }
    let reportedSize = 4 * 1_024 * 1_024
    let session = try ScreenshotFixtureSession(
      entries: Dictionary(uniqueKeysWithValues: locators.map { ($0, ppmFixture) }),
      reportedSize: reportedSize
    )
    let request = try MediaPlaylistThumbnailRequest(
      width: 96,
      height: 64,
      format: .png,
      maximumItems: 3,
      maximumConcurrentCaptures: 2
    )
    let items = try locators.map { try MediaPlaylistThumbnailItem(locator: $0) }

    let result = try await FFmpegMediaPlaylistThumbnailGenerator().capture(
      items,
      using: [session.sourceUID: session],
      request: request
    )

    #expect(result.width == 96)
    #expect(result.height == 64)
    #expect(result.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    #expect(await session.bytesRead < reportedSize * locators.count)
    #expect(await session.maximumRequestedLength <= 256 * 1_024)
  }

  @Test("Screenshot request validation rejects invalid values")
  func requestValidation() {
    #expect(throws: SDKError.self) {
      _ = try MediaScreenshotRequest(timestampMilliseconds: -1)
    }
    #expect(throws: SDKError.self) {
      _ = try MediaScreenshotRequest(timestampMilliseconds: 0, maximumPixelDimension: 8)
    }
  }

  private var ppmFixture: Data {
    var data = Data("P6\n4 2\n255\n".utf8)
    data.append(
      contentsOf: [
        0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF,
        0x00, 0x00, 0x00, 0x80, 0x80, 0x80, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF,
      ]
    )
    return data
  }

  private func temporaryURL(extension pathExtension: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("stellar-screenshot-test-\(UUID().uuidString)")
      .appendingPathExtension(pathExtension)
  }
}

private actor ScreenshotFixtureSession: MediaSourceSession {
  nonisolated let sourceUID: String
  nonisolated let capabilities: MediaSourceCapabilities
  private let entries: [RemoteLocator: Data]
  private let reportedSize: Int
  private(set) var bytesRead = 0
  private(set) var maximumRequestedLength = 0

  init(locator: RemoteLocator, data: Data, reportedSize: Int? = nil) throws {
    sourceUID = locator.sourceUID
    capabilities = try MediaSourceCapabilities(
      stableIDScope: .none,
      pathSemantics: RemotePathSemantics(
        caseSensitivity: .insensitive,
        unicodeNormalization: .preserve
      ),
      supportsRangeReads: true,
      supportsChangeCursor: false,
      deltaDeletionsComplete: false,
      preferredDirectoryRequestConcurrency: 1
    )
    entries = [locator: data]
    self.reportedSize = reportedSize ?? data.count
  }

  init(entries: [RemoteLocator: Data], reportedSize: Int) throws {
    guard let sourceUID = entries.keys.first?.sourceUID, !entries.isEmpty,
      entries.keys.allSatisfy({ $0.sourceUID == sourceUID }), reportedSize > 0
    else {
      throw SDKError(code: .invalidConfiguration, message: "fixture entries are invalid")
    }
    self.sourceUID = sourceUID
    capabilities = try MediaSourceCapabilities(
      stableIDScope: .none,
      pathSemantics: RemotePathSemantics(
        caseSensitivity: .insensitive,
        unicodeNormalization: .preserve
      ),
      supportsRangeReads: true,
      supportsChangeCursor: false,
      deltaDeletionsComplete: false,
      preferredDirectoryRequestConcurrency: 1
    )
    self.entries = entries
    self.reportedSize = reportedSize
  }

  func listDirectory(_: RemoteDirectoryPageRequest) async throws -> CursorPage<RemoteEntry> {
    throw SDKError(code: .invalidConfiguration, message: "fixture does not contain a directory")
  }

  func stat(_ locator: RemoteLocator) async throws -> RemoteEntry {
    guard entries[locator] != nil else {
      throw SDKError(code: .metadataNotFound, message: "fixture media was not found")
    }
    return try RemoteEntry(locator: locator, kind: .file, size: Int64(reportedSize))
  }

  func read(at locator: RemoteLocator, range: RemoteByteRange) async throws -> Data {
    guard let data = entries[locator] else {
      throw SDKError(code: .metadataNotFound, message: "fixture media was not found")
    }
    let lowerBound = min(Int(range.offset), data.count)
    let upperBound = min(lowerBound + range.length, data.count)
    let result = data.subdata(in: lowerBound..<upperBound)
    bytesRead += result.count
    maximumRequestedLength = max(maximumRequestedLength, range.length)
    return result
  }

  func disconnect() async {}
}

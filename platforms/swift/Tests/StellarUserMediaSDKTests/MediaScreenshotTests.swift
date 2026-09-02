import Foundation
import StellarCore
import StellarMediaImaging
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
  private let locator: RemoteLocator
  private let data: Data
  private(set) var bytesRead = 0

  init(locator: RemoteLocator, data: Data) throws {
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
    self.locator = locator
    self.data = data
  }

  func listDirectory(_: RemoteDirectoryPageRequest) async throws -> CursorPage<RemoteEntry> {
    throw SDKError(code: .invalidConfiguration, message: "fixture does not contain a directory")
  }

  func stat(_ locator: RemoteLocator) async throws -> RemoteEntry {
    guard locator == self.locator else {
      throw SDKError(code: .metadataNotFound, message: "fixture media was not found")
    }
    return try RemoteEntry(locator: locator, kind: .file, size: Int64(data.count))
  }

  func read(at locator: RemoteLocator, range: RemoteByteRange) async throws -> Data {
    guard locator == self.locator else {
      throw SDKError(code: .metadataNotFound, message: "fixture media was not found")
    }
    let lowerBound = min(Int(range.offset), data.count)
    let upperBound = min(lowerBound + range.length, data.count)
    let result = data.subdata(in: lowerBound..<upperBound)
    bytesRead += result.count
    return result
  }

  func disconnect() async {}
}

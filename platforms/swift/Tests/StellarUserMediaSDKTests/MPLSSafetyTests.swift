import Foundation
import KSPlayer
import Testing

@testable import BDMVIOContext

@Suite("MPLS input safety")
struct MPLSSafetyTests {
  @Test("Text bytes cannot become an unchecked playlist offset")
  func rejectsTextAndInvalidOffsets() throws {
    #expect(throws: MPLSParseError.self) {
      _ = try MPLS.parse(
        bytes: Array(repeating: Array("123456789".utf8), count: 1_892).flatMap { $0 },
        name: "1234567912.txt", fileMap: [:]
      )
    }
    for offset in [8, 12, 16] {
      var bytes = fixture()
      bytes.replaceSubrange(offset..<(offset + 4), with: [0x31, 0x32, 0x33, 0x34])
      #expect(throws: MPLSParseError.self) {
        _ = try MPLS.parse(bytes: bytes, name: "00000.mpls", fileMap: [:])
      }
    }
  }

  @Test("Every truncated prefix and nested length is checked before reading")
  func rejectsTruncatedAndMalformedSections() throws {
    let valid = fixture()
    for length in 0..<90 {
      #expect(throws: MPLSParseError.self) {
        _ = try MPLS.parse(bytes: Array(valid.prefix(length)), name: "00000.mpls", fileMap: [:])
      }
    }
    for (offset, replacement) in [
      (20, [UInt8](repeating: 255, count: 4)),  // Playlist section length.
      (26, [255, 255]),  // Play-item count.
      (30, [0, 1]),  // Play-item section too small.
      (30, [255, 255]),  // Play-item section too large.
      (42, [0x11]),  // Multi-angle count/entries.
      (44, [255, 255, 255, 255]),  // In time greater than out time.
      (64, [0, 1]), (64, [255, 255]),  // STN bounds.
      (69, [255]),  // Audio entries beyond STN.
      (70, [255]), (74, [255]),  // PG + PIP count cannot overflow UInt8.
      (88, [255, 255]),  // Truncated marks.
    ] {
      var bytes = valid
      bytes.replaceSubrange(offset..<(offset + replacement.count), with: replacement)
      #expect(throws: MPLSParseError.self) {
        _ = try MPLS.parse(bytes: bytes, name: "00000.mpls", fileMap: [:])
      }
    }
  }

  @Test("STN stream entry and attribute bounds preserve valid audio languages")
  func streamBounds() throws {
    var bytes = fixture()
    // Grow the item and STN by ten bytes for one audio stream, moving the mark section.
    bytes.insert(contentsOf: [3, 1, 0x11, 0, 5, 0x81, 0x31, 0x65, 0x6e, 0x67], at: 80)
    bytes[15] = 94
    bytes[23] = 66
    bytes[31] = 58
    bytes[65] = 24
    bytes[69] = 1
    let parsed = try MPLS.parse(bytes: bytes, name: "00000.mpls", fileMap: [:])
    #expect(parsed.playItems.first?.stn.audio.first?.lang == "eng")
    #expect(parsed.playItems.first?.stn.audio.first?.pid == 0x1100)
    for offset in [80, 84] {
      for length: UInt8 in [0, 1, 255] {
        var invalid = bytes
        invalid[offset] = length
        #expect(throws: MPLSParseError.self) {
          _ = try MPLS.parse(bytes: invalid, name: "00000.mpls", fileMap: [:])
        }
      }
    }
  }

  @Test("Short reads fill completely and EOF, read failure and allocation limits throw")
  func readCompletion() throws {
    let good = PlaylistDownload(bytes: fixture(), chunkSize: 3)
    let parsed = try good.parseMPLSFile(fileMap: [:])
    #expect(parsed.playItems.count == 1)
    #expect(good.readCount == 32)
    #expect(good.closeCount == 1)
    for download in [
      PlaylistDownload(bytes: Array(fixture().prefix(40)), reportedSize: 96),
      PlaylistDownload(bytes: fixture(), chunkSize: -1),
      PlaylistDownload(bytes: [], reportedSize: -1),
      PlaylistDownload(bytes: [], reportedSize: Int64.max),
    ] {
      #expect(throws: MPLSParseError.self) { _ = try download.parseMPLSFile(fileMap: [:]) }
      #expect(download.closeCount == 1)
    }
  }

  @Test("PLAYLIST ignores sidecars while valid uppercase MPLS files remain playable")
  func filtersSidecars() async throws {
    let text = PlaylistDownload(
      bytes: Array("123456789123456789123456789".utf8), name: "1234567912.txt")
    let hidden = PlaylistDownload(bytes: [1, 2, 3], name: "._00000.mpls")
    let playlist = PlaylistDownload(bytes: fixture(), name: "00000.MPLS")
    let manager = PlaylistFilesManager(playlists: [text, hidden, playlist])
    let context = try await BDMVIOContext(filesManager: manager)
    #expect(context.playlists.map(\.name) == ["00000.MPLS"])
    #expect(context.fileSize() == 2_048)
    #expect(text.readCount == 0)
    #expect(hidden.readCount == 0)
    context.close()
    context.close()
    #expect(manager.closeCount == 1)
  }

  @Test("An invalid MPLS fails initialization and closes the manager")
  func invalidPlaylistFailsSafely() async throws {
    let manager = PlaylistFilesManager(playlists: [
      PlaylistDownload(bytes: Array("123456789123456789123456789".utf8))
    ])
    await #expect(throws: MPLSParseError.self) {
      _ = try await BDMVIOContext(filesManager: manager)
    }
    #expect(manager.closeCount == 1)
  }

  @Test("Deterministic mutations of a valid playlist never escape bounded parsing")
  func mutatedInputs() {
    var seed: UInt64 = 0x3132_3334
    for _ in 0..<2_000 {
      var bytes = fixture()
      for _ in 0..<4 {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        let offset = Int(seed >> 32) % bytes.count
        bytes[offset] = UInt8(truncatingIfNeeded: seed)
      }
      _ = try? MPLS.parse(bytes: bytes, name: "00000.mpls", fileMap: [:])
    }
  }

  private func fixture() -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 96)
    bytes.replaceSubrange(0..<8, with: Array("MPLS0100".utf8))
    bytes[11] = 20
    bytes[15] = 84
    bytes[23] = 56
    bytes[27] = 1
    bytes[31] = 48
    bytes.replaceSubrange(32..<41, with: Array("00001M2TS".utf8))
    bytes[42] = 1
    bytes.replaceSubrange(48..<52, with: [0, 6, 0xdd, 0xd0])  // 10 seconds at 45 kHz.
    bytes[65] = 14
    bytes[87] = 2
    return bytes
  }
}

private final class PlaylistDownload: DownloadProtocol, CustomStringConvertible {
  let bufferSize: Int32 = 512
  let description: String
  let bytes: [UInt8]
  let reportedSize: Int64
  let chunkSize: Int
  var offset = 0
  var readCount = 0
  var closeCount = 0

  init(bytes: [UInt8], name: String = "00000.mpls", reportedSize: Int64? = nil, chunkSize: Int = 96)
  {
    self.bytes = bytes
    description = name
    self.reportedSize = reportedSize ?? Int64(bytes.count)
    self.chunkSize = chunkSize
  }

  func fileSize() -> Int64 { reportedSize }
  func close() { closeCount += 1 }
  func seek(offset: Int64, whence: Int32) -> Int64 {
    guard whence == SEEK_SET, offset >= 0, offset <= bytes.count else { return -1 }
    self.offset = Int(offset)
    return offset
  }
  func read(buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
    readCount += 1
    guard chunkSize >= 0, let buffer else { return -1 }
    let count = min(Int(size), chunkSize, bytes.count - offset)
    for index in 0..<count { buffer[index] = bytes[offset + index] }
    offset += count
    return Int32(count)
  }
}

private final class PlaylistFilesManager: FilesManager, @unchecked Sendable {
  let playlists: [PlaylistDownload]
  var closeCount = 0
  init(playlists: [PlaylistDownload]) { self.playlists = playlists }
  func close() { closeCount += 1 }
  func contentsOfDirectory(atPath path: String) async throws -> [FileObject] {
    ["PLAYLIST", "STREAM"].map { name in
      FileObject(
        url: URL(fileURLWithPath: "/BDMV/\(name)"),
        allValues: [
          .nameKey: name, .pathKey: "/BDMV/\(name)",
          .fileResourceTypeKey: URLFileResourceType.directory,
        ]
      )
    }
  }
  func downloads(atPath path: String) async throws -> [DownloadProtocol & CustomStringConvertible] {
    if path == "/BDMV/PLAYLIST" { return playlists }
    return [PlaylistDownload(bytes: [UInt8](repeating: 0, count: 2_048), name: "00001.m2ts")]
  }
}

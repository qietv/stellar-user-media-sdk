import Foundation
import StellarCore
import StellarMediaLibrary
import StellarRemoteMedia
import Testing

@testable import StellarDiscMedia

@Suite("Remote BDMV adapters")
struct RemoteDiscAdapterTests {
  @Test("Synchronous disc reads fill short async ranges and preserve seek and EOF")
  func rangeReadAndSeek() async throws {
    let sourceBytes: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
    let entry = try file("Movie.iso", bytes: sourceBytes)
    let session = try DiscAdapterFixtureSession(
      files: [entry.locator: Data(sourceBytes)],
      maximumReadSize: 2
    )
    let download = try RemoteRangeDownload(
      session: session,
      entry: entry,
      timeoutMilliseconds: 1_000
    )

    #expect(download.fileSize() == 10)
    #expect(read(download, count: 5) == [0, 1, 2, 3, 4])
    #expect(download.seek(offset: 7, whence: SEEK_SET) == 7)
    #expect(read(download, count: 8) == [7, 8, 9])
    #expect(read(download, count: 1).isEmpty)
    #expect(download.seek(offset: -2, whence: SEEK_END) == 8)
    #expect(read(download, count: 2) == [8, 9])
    #expect(download.seek(offset: 11, whence: SEEK_SET) == -1)

    download.close()
    var byte: UInt8 = 0
    #expect(download.read(buffer: &byte, size: 1) == -1)
    #expect(await session.readCount >= 4)
  }

  @Test("Remote FilesManager maps virtual BDMV paths and creates range downloads")
  func filesManagerMapping() async throws {
    let root = try directory("Movie")
    let bdmv = try directory("Movie/BDMV")
    let playlist = try directory("Movie/BDMV/PLAYLIST")
    let stream = try directory("Movie/BDMV/STREAM")
    let mpls = try file("Movie/BDMV/PLAYLIST/00001.MPLS", bytes: [1, 2, 3, 4])
    let clip = try file("Movie/BDMV/STREAM/00001.M2TS", bytes: [5, 6, 7])
    let index = try file("Movie/BDMV/index.bdmv", bytes: [8])
    let session = try DiscAdapterFixtureSession(
      directories: [
        bdmv.locator: [playlist, stream, index],
        playlist.locator: [mpls],
        stream.locator: [clip],
      ],
      files: [
        mpls.locator: Data([1, 2, 3, 4]),
        clip.locator: Data([5, 6, 7]),
        index.locator: Data([8]),
      ]
    )
    let candidate = try CompositeMediaDescriptor(
      locator: root.locator,
      logicalRoot: root.locator,
      container: .directory,
      kind: .bluray,
      confidence: .candidate,
      entryPoint: index.locator
    )
    let manager = try RemoteBDMVFilesManager(
      session: session,
      candidate: candidate,
      pageSize: 2,
      readTimeoutMilliseconds: 1_000
    )

    let bdmvContents = try await manager.contentsOfDirectory(atPath: "/BDMV")
    #expect(Set(bdmvContents.map(\.name)) == ["PLAYLIST", "STREAM", "index.bdmv"])
    #expect(
      bdmvContents.first(where: { $0.name == "PLAYLIST" })?.path == "/BDMV/PLAYLIST"
    )
    let playlists = try await manager.downloads(atPath: "/BDMV/PLAYLIST")
    let playlistDownload = try #require(playlists.first as? RemoteRangeDownload)
    #expect(playlistDownload.description == "00001.mpls")
    #expect(read(playlistDownload, count: 8) == [1, 2, 3, 4])
    let streams = try await manager.downloads(atPath: "/BDMV/STREAM")
    #expect(streams.map(\.description) == ["00001.m2ts"])

    manager.close()
    await #expect(throws: SDKError.self) {
      _ = try await manager.contentsOfDirectory(atPath: "/BDMV")
    }
  }

  @Test("Remote FilesManager preserves the observed AVCHD path casing")
  func avchdPathCasing() async throws {
    let root = try directory("Camera")
    let bdmv = try directory("Camera/avchd/bdmv")
    let playlist = try directory("Camera/avchd/bdmv/playlist")
    let stream = try directory("Camera/avchd/bdmv/stream")
    let index = try file("Camera/avchd/bdmv/INDEX.BDMV", bytes: [1])
    let session = try DiscAdapterFixtureSession(
      directories: [
        bdmv.locator: [playlist, stream, index]
      ],
      files: [index.locator: Data([1])]
    )
    let candidate = try CompositeMediaDescriptor(
      locator: root.locator,
      logicalRoot: root.locator,
      container: .directory,
      kind: .avchd,
      confidence: .candidate,
      entryPoint: index.locator
    )
    let manager = try RemoteBDMVFilesManager(
      session: session,
      candidate: candidate,
      readTimeoutMilliseconds: 1_000
    )

    let contents = try await manager.contentsOfDirectory(atPath: "/BDMV")
    #expect(contents.map(\.name) == ["PLAYLIST", "STREAM", "INDEX.BDMV"])
    #expect(contents.prefix(2).map(\.path) == ["/BDMV/PLAYLIST", "/BDMV/STREAM"])
    manager.close()
  }

  @Test("Remote FilesManager exposes VIDEO_TS files to BDMVIOContext's DVD path")
  func dvdPathMapping() async throws {
    let root = try directory("DVD Movie")
    let videoTS = try directory("DVD Movie/video_ts")
    let control = try file("DVD Movie/video_ts/video_ts.ifo", bytes: [1])
    let backup = try file("DVD Movie/video_ts/VIDEO_TS.BUP", bytes: [2])
    let title = try file("DVD Movie/video_ts/VTS_01_1.VOB", bytes: [3, 4])
    let session = try DiscAdapterFixtureSession(
      directories: [videoTS.locator: [control, backup, title]],
      files: [
        control.locator: Data([1]),
        backup.locator: Data([2]),
        title.locator: Data([3, 4]),
      ]
    )
    let candidate = try CompositeMediaDescriptor(
      locator: root.locator,
      logicalRoot: root.locator,
      container: .directory,
      kind: .dvdVideo,
      confidence: .candidate,
      entryPoint: control.locator
    )
    let manager = try RemoteBDMVFilesManager(
      session: session,
      candidate: candidate,
      readTimeoutMilliseconds: 1_000
    )

    #expect(try await manager.contentsOfDirectory(atPath: "/BDMV").isEmpty)
    let files = try await manager.downloads(atPath: "/VIDEO_TS")
    #expect(Set(files.map(\.description)) == ["VIDEO_TS.IFO", "VIDEO_TS.BUP", "VTS_01_1.VOB"])
    manager.close()
  }

  @Test("A stalled asynchronous source is bounded by the synchronous read timeout")
  func rangeReadTimeout() throws {
    let entry = try file("Slow.iso", bytes: [1])
    let session = try DiscAdapterFixtureSession(
      files: [entry.locator: Data([1])],
      readDelayMilliseconds: 1_000
    )
    let download = try RemoteRangeDownload(
      session: session,
      entry: entry,
      timeoutMilliseconds: 100
    )
    var byte: UInt8 = 0

    #expect(download.read(buffer: &byte, size: 1) == -1)
    download.close()
  }

  private func read(_ download: RemoteRangeDownload, count: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    let readCount = bytes.withUnsafeMutableBufferPointer { buffer in
      download.read(buffer: buffer.baseAddress, size: Int32(count))
    }
    guard readCount > 0 else { return [] }
    return Array(bytes.prefix(Int(readCount)))
  }

  private func directory(_ path: String) throws -> RemoteEntry {
    try RemoteEntry(
      locator: RemoteLocator(sourceUID: "disc-adapter", path: RemotePath(path)),
      kind: .directory,
      stableID: "directory:\(path)"
    )
  }

  private func file(_ path: String, bytes: [UInt8]) throws -> RemoteEntry {
    try RemoteEntry(
      locator: RemoteLocator(sourceUID: "disc-adapter", path: RemotePath(path)),
      kind: .file,
      stableID: "file:\(path)",
      size: Int64(bytes.count)
    )
  }
}

private actor DiscAdapterFixtureSession: MediaSourceSession {
  nonisolated let sourceUID = "disc-adapter"
  nonisolated let capabilities: MediaSourceCapabilities

  private let directories: [RemoteLocator: [RemoteEntry]]
  private let files: [RemoteLocator: Data]
  private let maximumReadSize: Int?
  private let readDelayMilliseconds: Int
  private(set) var readCount = 0

  init(
    directories: [RemoteLocator: [RemoteEntry]] = [:],
    files: [RemoteLocator: Data],
    maximumReadSize: Int? = nil,
    readDelayMilliseconds: Int = 0
  ) throws {
    self.directories = directories
    self.files = files
    self.maximumReadSize = maximumReadSize
    self.readDelayMilliseconds = readDelayMilliseconds
    capabilities = try MediaSourceCapabilities(
      stableIDScope: .persistent,
      pathSemantics: RemotePathSemantics(
        caseSensitivity: .sensitive,
        unicodeNormalization: .preserve
      ),
      supportsRangeReads: true,
      supportsChangeCursor: false,
      deltaDeletionsComplete: false,
      preferredDirectoryRequestConcurrency: 1
    )
  }

  func listDirectory(
    _ request: RemoteDirectoryPageRequest
  ) async throws -> CursorPage<RemoteEntry> {
    guard request.cursor == nil, let entries = directories[request.directory] else {
      throw SDKError(code: .remoteUnavailable, message: "unexpected BDMV fixture directory")
    }
    return try CursorPage(items: entries, nextCursor: nil)
  }

  func stat(_ locator: RemoteLocator) async throws -> RemoteEntry {
    if let bytes = files[locator] {
      return try RemoteEntry(locator: locator, kind: .file, size: Int64(bytes.count))
    }
    return try RemoteEntry(locator: locator, kind: .directory)
  }

  func read(at locator: RemoteLocator, range: RemoteByteRange) async throws -> Data {
    readCount += 1
    if readDelayMilliseconds > 0 {
      try await Task.sleep(for: .milliseconds(readDelayMilliseconds))
    }
    guard let data = files[locator], range.offset < Int64(data.count) else { return Data() }
    let start = Int(range.offset)
    let requestedEnd = min(data.count, start + range.length)
    let end = min(requestedEnd, start + (maximumReadSize ?? range.length))
    return data[start..<end]
  }

  func disconnect() async {}
}

import CryptoKit
import Foundation
import StellarCore
import StellarLocalMedia
import StellarMediaLibrary
import StellarRemoteMedia
import StellarSMB2Apple
import StellarSMB2Core
import StellarStorage
import StellarWebDAV
import Testing

@testable import StellarDiscMedia

@Suite("Remote BDMV adapters", .serialized)
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

  @Test("Random seeks and reads crossing a 2 KiB UDF block preserve exact bytes")
  func rangeReadAcrossUDFBlocks() async throws {
    let sourceBytes = (0..<6_144).map { UInt8($0 % 251) }
    let entry = try file("Blocks.iso", bytes: sourceBytes)
    let session = try DiscAdapterFixtureSession(
      files: [entry.locator: Data(sourceBytes)],
      maximumReadSize: 97
    )
    let download = try RemoteRangeDownload(
      session: session,
      entry: entry,
      timeoutMilliseconds: 1_000
    )
    defer { download.close() }

    for (offset, count) in [(2_039, 32), (4_091, 41), (17, 509), (6_100, 44)] {
      #expect(download.seek(offset: Int64(offset), whence: SEEK_SET) == Int64(offset))
      #expect(read(download, count: count) == Array(sourceBytes[offset..<(offset + count)]))
    }
    #expect(download.seek(offset: 6_144, whence: SEEK_SET) == 6_144)
    #expect(read(download, count: 1).isEmpty)
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

  @Test(
    "Disc probe failures keep capability, structure, protection, cancellation, and source states distinct"
  )
  func typedFailureClassification() {
    #expect(
      DiscMediaLibrary.classify(
        SDKError(code: .invalidConfiguration, message: "range reads are unsupported")
      ) == .unsupported)
    #expect(
      DiscMediaLibrary.classify(
        SDKError(code: .parseFailure, message: "playlist is malformed")
      ) == .corruptStructure)
    #expect(
      DiscMediaLibrary.classify(
        SDKError(code: .parseFailure, message: "AACS encrypted disc")
      ) == .encrypted)
    #expect(
      DiscMediaLibrary.classify(
        SDKError(code: .cancelled, message: "cancelled")
      ) == .cancelled)
    #expect(
      DiscMediaLibrary.classify(
        SDKError(code: .remoteUnavailable, message: "source offline")
      ) == .remoteUnavailable)
    #expect(
      DiscMediaLibrary.classify(
        NSError(domain: "fixture", code: 1)
      ) == .dependencyFailure)
  }

  @Test("A remote image read error survives the synchronous udfread bridge")
  func imageReadFailurePropagation() async throws {
    let entry = try file("Unavailable.iso", bytes: [1])
    let candidate = try #require(
      try OpticalDiscCandidateDetector().diskImageCandidate(for: entry)?.descriptor
    )
    let session = try DiscAdapterFixtureSession(
      files: [entry.locator: Data([1])],
      readError: SDKError(code: .remoteUnavailable, message: "fixture source offline")
    )
    do {
      _ = try await BDMVIOContextRemoteImageProbe().probe(
        entry: entry,
        candidate: candidate,
        using: session,
        readTimeoutMilliseconds: 1_000
      )
      Issue.record("expected the remote read failure")
    } catch let error as SDKError {
      #expect(error.code == .remoteUnavailable)
    }
  }

  @Test("A valid BDMV directory projects all unique playlists and chooses the largest title")
  func bdmvIntegrationProjection() async throws {
    let fixture = try bdmvFixture()
    let result = try await BDMVIOContextRemoteDirectoryProbe().probe(
      candidate: fixture.candidate,
      using: fixture.session,
      readTimeoutMilliseconds: 1_000
    )

    #expect(result.descriptor.confidence == .confirmed)
    #expect(result.playlists.map(\.identifier) == ["00000.mpls", "00001.mpls"])
    #expect(result.playlists.first(where: \.isSelected)?.identifier == "00001.mpls")
    #expect(result.playlists.first(where: \.isSelected)?.segments.count == 1)
    #expect(result.metrics.directoryListRequestCount == 3)
    #expect(await fixture.session.listCount == 3)
    #expect(try result.playbackSelection().playlistIdentifier == "00001.mpls")
    #expect(
      try result.playbackSelection(playlistIdentifier: "00000.mpls").playlistIdentifier
        == "00000.mpls"
    )
  }

  @Test("The Local source produces the same BDMV playlist projection")
  func localSourceBDMVProjection() async throws {
    let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "stellar-local-disc-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: fixtureRoot) }
    let playlistURL = fixtureRoot.appendingPathComponent("Movie/BDMV/PLAYLIST", isDirectory: true)
    let streamURL = fixtureRoot.appendingPathComponent("Movie/BDMV/STREAM", isDirectory: true)
    try FileManager.default.createDirectory(at: playlistURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: streamURL, withIntermediateDirectories: true)
    try Data([1]).write(to: fixtureRoot.appendingPathComponent("Movie/BDMV/index.bdmv"))
    try Data(mpls(clipID: "00001")).write(to: playlistURL.appendingPathComponent("00000.mpls"))
    try Data(mpls(clipID: "00002")).write(to: playlistURL.appendingPathComponent("00001.mpls"))
    try Data(mpls(clipID: "00001")).write(to: playlistURL.appendingPathComponent("00002.mpls"))
    try Data(repeating: 1, count: 16).write(to: streamURL.appendingPathComponent("00001.m2ts"))
    try Data(repeating: 2, count: 32).write(to: streamURL.appendingPathComponent("00002.m2ts"))

    let sourceUID = "local-disc-fixture"
    let session = try await LocalMediaSourceConnector(
      configuration: try LocalMediaSourceConfiguration(
        sourceUID: sourceUID,
        rootURL: fixtureRoot
      )
    ).connect()
    let locator = try RemoteLocator(sourceUID: sourceUID, path: RemotePath("Movie"))
    do {
      let page = try await session.listDirectory(
        RemoteDirectoryPageRequest(directory: locator, limit: 500)
      )
      let classification = try await OpticalDiscMediaScanClassifier().classify(
        directory: locator,
        entries: page.items,
        using: session
      )
      let candidate = try #require(classification.compositeMedia.first?.descriptor)
      let result = try await BDMVIOContextRemoteDirectoryProbe().probe(
        candidate: candidate,
        using: session,
        readTimeoutMilliseconds: 1_000
      )
      await session.disconnect()

      #expect(result.playlists.map(\.identifier) == ["00000.mpls", "00001.mpls"])
      #expect(result.playlists.first(where: \.isSelected)?.identifier == "00001.mpls")
      #expect(result.metrics.directoryListRequestCount == 3)
    } catch {
      await session.disconnect()
      throw error
    }
  }

  @Test("The WebDAV source produces the same BDMV playlist projection")
  func webDAVSourceBDMVProjection() async throws {
    let files = [
      "/media/Movie/BDMV/index.bdmv": Data([1]),
      "/media/Movie/BDMV/PLAYLIST/00000.mpls": Data(mpls(clipID: "00001")),
      "/media/Movie/BDMV/PLAYLIST/00001.mpls": Data(mpls(clipID: "00002")),
      "/media/Movie/BDMV/PLAYLIST/00002.mpls": Data(mpls(clipID: "00001")),
      "/media/Movie/BDMV/STREAM/00001.m2ts": Data(repeating: 1, count: 16),
      "/media/Movie/BDMV/STREAM/00002.m2ts": Data(repeating: 2, count: 32),
    ]
    let transport = DiscWebDAVTransport(files: files)
    let sourceUID = "webdav-disc-fixture"
    let session = try await WebDAVMediaSourceConnector(
      configuration: try WebDAVMediaSourceConfiguration(
        sourceUID: sourceUID,
        baseURL: URL(string: "https://disc.example.test/media/")!
      ),
      transport: transport
    ).connect()
    let locator = try RemoteLocator(sourceUID: sourceUID, path: RemotePath("Movie"))
    do {
      let page = try await session.listDirectory(
        RemoteDirectoryPageRequest(directory: locator, limit: 500)
      )
      let classification = try await OpticalDiscMediaScanClassifier().classify(
        directory: locator,
        entries: page.items,
        using: session
      )
      let candidate = try #require(classification.compositeMedia.first?.descriptor)
      let result = try await BDMVIOContextRemoteDirectoryProbe().probe(
        candidate: candidate,
        using: session,
        readTimeoutMilliseconds: 1_000
      )
      await session.disconnect()

      #expect(result.playlists.map(\.identifier) == ["00000.mpls", "00001.mpls"])
      #expect(result.playlists.first(where: \.isSelected)?.identifier == "00001.mpls")
      #expect(result.metrics.directoryListRequestCount == 3)
      let depthOneRequestCount = await transport.depthOneRequestCount
      #expect(depthOneRequestCount == 5)
    } catch {
      await session.disconnect()
      throw error
    }
  }

  @Test("The SMB source produces the same BDMV playlist projection")
  func smbSourceBDMVProjection() async throws {
    let movie = try SMB2Path("Movie")
    let bdmv = try SMB2Path("Movie/BDMV")
    let playlist = try SMB2Path("Movie/BDMV/PLAYLIST")
    let stream = try SMB2Path("Movie/BDMV/STREAM")
    let index = try SMB2Path("Movie/BDMV/index.bdmv")
    let firstMPLS = try SMB2Path("Movie/BDMV/PLAYLIST/00000.mpls")
    let mainMPLS = try SMB2Path("Movie/BDMV/PLAYLIST/00001.mpls")
    let duplicateMPLS = try SMB2Path("Movie/BDMV/PLAYLIST/00002.mpls")
    let firstClip = try SMB2Path("Movie/BDMV/STREAM/00001.m2ts")
    let mainClip = try SMB2Path("Movie/BDMV/STREAM/00002.m2ts")
    let files = [
      index: Data([1]),
      firstMPLS: Data(mpls(clipID: "00001")),
      mainMPLS: Data(mpls(clipID: "00002")),
      duplicateMPLS: Data(mpls(clipID: "00001")),
      firstClip: Data(repeating: 1, count: 16),
      mainClip: Data(repeating: 2, count: 32),
    ]
    func entry(_ path: SMB2Path, kind: SMB2EntryKind) throws -> SMB2Entry {
      try SMB2Entry(
        path: path,
        kind: kind,
        size: files[path].map { Int64($0.count) },
        stableID: "fixture:\(path.relativePath)"
      )
    }
    let movieEntry = try entry(movie, kind: .directory)
    let bdmvEntry = try entry(bdmv, kind: .directory)
    let playlistEntry = try entry(playlist, kind: .directory)
    let streamEntry = try entry(stream, kind: .directory)
    let indexEntry = try entry(index, kind: .file)
    let firstMPLSEntry = try entry(firstMPLS, kind: .file)
    let mainMPLSEntry = try entry(mainMPLS, kind: .file)
    let duplicateMPLSEntry = try entry(duplicateMPLS, kind: .file)
    let firstClipEntry = try entry(firstClip, kind: .file)
    let mainClipEntry = try entry(mainClip, kind: .file)
    let fixtureSession = DiscSMB2Session(
      entriesByDirectory: [
        movie: [bdmvEntry],
        bdmv: [playlistEntry, streamEntry, indexEntry],
        playlist: [firstMPLSEntry, mainMPLSEntry, duplicateMPLSEntry],
        stream: [firstClipEntry, mainClipEntry],
      ],
      entriesByPath: Dictionary(
        uniqueKeysWithValues: [
          movieEntry, bdmvEntry, playlistEntry, streamEntry, indexEntry, firstMPLSEntry,
          mainMPLSEntry, duplicateMPLSEntry, firstClipEntry, mainClipEntry,
        ].map { ($0.path, $0) }
      ),
      files: files
    )
    let sourceUID = "smb-disc-fixture"
    let connector = SMB2MediaSourceConnector(
      transport: DiscSMB2Transport(session: fixtureSession),
      configuration: try SMB2MediaSourceConfiguration(
        sourceUID: sourceUID,
        connectionRequest: SMB2ConnectionRequest(
          endpoint: SMB2Endpoint(server: "fixture.invalid", share: "Media"),
          credential: SMB2Credential(username: "fixture", password: "fixture")
        ),
        stableIDScope: .persistent
      )
    )
    let session = try await connector.connect()
    let locator = try RemoteLocator(sourceUID: sourceUID, path: RemotePath("Movie"))
    do {
      let page = try await session.listDirectory(
        RemoteDirectoryPageRequest(directory: locator, limit: 500)
      )
      let classification = try await OpticalDiscMediaScanClassifier().classify(
        directory: locator,
        entries: page.items,
        using: session
      )
      let candidate = try #require(classification.compositeMedia.first?.descriptor)
      let result = try await BDMVIOContextRemoteDirectoryProbe().probe(
        candidate: candidate,
        using: session,
        readTimeoutMilliseconds: 1_000
      )
      await session.disconnect()

      #expect(result.playlists.map(\.identifier) == ["00000.mpls", "00001.mpls"])
      #expect(result.playlists.first(where: \.isSelected)?.identifier == "00001.mpls")
      #expect(result.metrics.directoryListRequestCount == 3)
      #expect(await fixtureSession.listRequestCount == 5)
    } catch {
      await session.disconnect()
      throw error
    }
  }

  @Test("A self-made UDF image is parsed locally and through bounded remote ranges")
  func udfImageIntegration() async throws {
    let imageURL = try #require(
      Bundle.module.url(forResource: "minimal-bdmv", withExtension: "iso")
    )
    let checksumURL = try #require(
      Bundle.module.url(forResource: "minimal-bdmv.iso", withExtension: "sha256")
    )
    let imageData = try Data(contentsOf: imageURL, options: .mappedIfSafe)
    let digest = SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined()
    let checksum = try String(contentsOf: checksumURL, encoding: .utf8)
    let recordedDigest = try #require(checksum.split(whereSeparator: { $0.isWhitespace }).first)
    #expect(digest == String(recordedDigest))

    let entry = try file("Fixture.iso", bytes: [])
    let sizedEntry = try RemoteEntry(
      locator: entry.locator,
      kind: .file,
      stableID: entry.stableID,
      size: Int64(imageData.count)
    )
    let candidate = try #require(
      try OpticalDiscCandidateDetector().diskImageCandidate(for: sizedEntry)?.descriptor
    )
    let local = try await BDMVIOContextLocalImageProbe().probe(
      imageAt: imageURL,
      candidate: candidate
    )
    #expect(local.playlists.map(\.identifier) == ["00000.mpls", "00001.mpls"])
    #expect(local.playlists.first(where: \.isSelected)?.identifier == "00001.mpls")

    let session = try DiscAdapterFixtureSession(files: [entry.locator: imageData])
    let remote = try await BDMVIOContextRemoteImageProbe().probe(
      entry: sizedEntry,
      candidate: candidate,
      using: session,
      readTimeoutMilliseconds: 2_000
    )
    #expect(remote.playlists == local.playlists)
    #expect(remote.metrics.rangeReadRequestCount > 0)
    #expect(remote.metrics.rangeBytesRead > 0)
    #expect(remote.metrics.rangeBytesRead < imageData.count)
    #expect(await session.readCount == remote.metrics.rangeReadRequestCount)
  }

  @Test("A corrupt playlist inside UDF returns parseFailure locally and remotely")
  func malformedUDFPlaylist() async throws {
    let fixtureURL = try #require(Bundle.module.url(forResource: "minimal-bdmv", withExtension: "iso"))
    var data = try Data(contentsOf: fixtureURL)
    let header = try #require(data.range(of: Data("MPLS0100".utf8)))
    data.replaceSubrange((header.lowerBound + 8)..<(header.lowerBound + 12), with: [0x31, 0x32, 0x33, 0x34])
    let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent("stellar-corrupt-\(UUID()).iso")
    try data.write(to: imageURL)
    defer { try? FileManager.default.removeItem(at: imageURL) }
    let entry = try file("Corrupt.iso", bytes: Array(data))
    let candidate = try #require(try OpticalDiscCandidateDetector().diskImageCandidate(for: entry)?.descriptor)
    do {
      _ = try await BDMVIOContextLocalImageProbe().probe(imageAt: imageURL, candidate: candidate)
      Issue.record("corrupt local playlist should fail")
    } catch let error as SDKError {
      #expect(error.code == .parseFailure)
    }
    let session = try DiscAdapterFixtureSession(files: [entry.locator: data])
    do {
      _ = try await BDMVIOContextRemoteImageProbe().probe(
        entry: entry, candidate: candidate, using: session, readTimeoutMilliseconds: 2_000
      )
      Issue.record("corrupt remote playlist should fail")
    } catch let error as SDKError {
      #expect(error.code == .parseFailure)
    }
  }

  @Test("An opt-in real SMB image probe reports bounded-I/O metrics")
  func realSMBImageProbeMetrics() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let server = environment["STELLAR_TEST_SMB_SERVER"],
      let share = environment["STELLAR_TEST_SMB_SHARE"],
      let username = environment["STELLAR_TEST_SMB_USERNAME"],
      let password = environment["STELLAR_TEST_SMB_PASSWORD"],
      let imagePath = environment["STELLAR_TEST_SMB_IMAGE_PATH"]
    else { return }

    let sourceUID = "real-smb-disc-integration"
    let request = try SMB2ConnectionRequest(
      endpoint: SMB2Endpoint(server: server, share: share),
      credential: SMB2Credential(username: username, password: password),
      timeoutMilliseconds: 30_000
    )
    let connector = SMB2MediaSourceConnector(
      transport: AppleSMB2Transport(),
      configuration: try SMB2MediaSourceConfiguration(
        sourceUID: sourceUID,
        connectionRequest: request,
        stableIDScope: .persistent
      )
    )
    let session = try await connector.connect()
    do {
      let locator = try RemoteLocator(sourceUID: sourceUID, path: RemotePath(imagePath))
      let entry = try await session.stat(locator)
      let candidate = try #require(
        try OpticalDiscCandidateDetector().diskImageCandidate(for: entry)?.descriptor
      )
      let result = try await BDMVIOContextRemoteImageProbe().probe(
        entry: entry,
        candidate: candidate,
        using: session,
        readTimeoutMilliseconds: 30_000
      )
      await session.disconnect()

      print(
        "STELLAR_DISC_NAS_METRICS "
          + "elapsed_ms=\(result.metrics.elapsedMilliseconds) "
          + "list_requests=\(result.metrics.directoryListRequestCount) "
          + "range_requests=\(result.metrics.rangeReadRequestCount) "
          + "range_bytes=\(result.metrics.rangeBytesRead) "
          + "image_bytes=\(entry.size ?? -1) playlists=\(result.playlists.count)"
      )
      #expect(result.descriptor.confidence == .confirmed)
      #expect(!result.playlists.isEmpty)
      #expect(result.metrics.rangeBytesRead < (entry.size ?? 0))
    } catch {
      await session.disconnect()
      throw error
    }
  }

  @Test("An opt-in real SMB BDMV directory probe reports bounded-I/O metrics")
  func realSMBDirectoryProbeMetrics() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let server = environment["STELLAR_TEST_SMB_SERVER"],
      let share = environment["STELLAR_TEST_SMB_SHARE"],
      let username = environment["STELLAR_TEST_SMB_USERNAME"],
      let password = environment["STELLAR_TEST_SMB_PASSWORD"],
      let directoryPath = environment["STELLAR_TEST_SMB_DIRECTORY_PATH"]
    else { return }

    let sourceUID = "real-smb-disc-directory-integration"
    let request = try SMB2ConnectionRequest(
      endpoint: SMB2Endpoint(server: server, share: share),
      credential: SMB2Credential(username: username, password: password),
      timeoutMilliseconds: 30_000
    )
    let connector = SMB2MediaSourceConnector(
      transport: AppleSMB2Transport(),
      configuration: try SMB2MediaSourceConfiguration(
        sourceUID: sourceUID,
        connectionRequest: request,
        stableIDScope: .persistent
      )
    )
    let session = try await connector.connect()
    do {
      let locator = try RemoteLocator(sourceUID: sourceUID, path: RemotePath(directoryPath))
      var entries: [RemoteEntry] = []
      var cursor: String?
      repeat {
        let page = try await session.listDirectory(
          RemoteDirectoryPageRequest(directory: locator, cursor: cursor, limit: 500)
        )
        entries.append(contentsOf: page.items)
        cursor = page.nextCursor
      } while cursor != nil
      let classification = try await OpticalDiscMediaScanClassifier().classify(
        directory: locator,
        entries: entries,
        using: session
      )
      let candidate = try #require(classification.compositeMedia.first?.descriptor)
      let result = try await BDMVIOContextRemoteDirectoryProbe().probe(
        candidate: candidate,
        using: session,
        readTimeoutMilliseconds: 30_000
      )
      await session.disconnect()

      print(
        "STELLAR_DISC_NAS_DIRECTORY_METRICS "
          + "elapsed_ms=\(result.metrics.elapsedMilliseconds) "
          + "list_requests=\(result.metrics.directoryListRequestCount) "
          + "range_requests=\(result.metrics.rangeReadRequestCount) "
          + "range_bytes=\(result.metrics.rangeBytesRead) "
          + "playlists=\(result.playlists.count)"
      )
      #expect(result.descriptor.confidence == .confirmed)
      #expect(!result.playlists.isEmpty)
      #expect(result.metrics.directoryListRequestCount == 3)
    } catch {
      await session.disconnect()
      throw error
    }
  }

  @Test("A successful exact-revision probe cache prevents unchanged BDMV I/O")
  func durableProbeCache() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "stellar-disc-cache-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await StorageDatabase.open(
      kind: .library,
      at: directory.appendingPathComponent("library.sqlite")
    )
    let store = try LibraryStore(database: database)
    let fixture = try bdmvFixture()
    let sourceUID = fixture.candidate.locator.sourceUID
    try await store.registerSource(
      LibrarySourceDefinition(
        uid: sourceUID,
        kind: .smb,
        displayName: "Disc cache",
        rootURI: "smb://disc-cache"
      )
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let composite = try LibraryScanCompositeMedia(
      locator: fixture.candidate.locator,
      descriptorsJSON: String(
        decoding: try encoder.encode([fixture.candidate]),
        as: UTF8.self
      )
    )
    let root = try RemoteLocator(sourceUID: sourceUID, path: RemotePath())

    func publish(runUID: String, modifiedAt: Int64) async throws {
      let synthetic = try RemoteEntry(
        locator: fixture.candidate.locator,
        kind: .file,
        stableID: "disc-root",
        modifiedAtMilliseconds: modifiedAt
      )
      try await store.commit(
        LibraryScanPersistenceBatch(
          runUID: runUID,
          sourceUID: sourceUID,
          mode: "full",
          state: "completed",
          checkpointJSON: #"{"phase":"completed"}"#,
          coverageJSON: #"{"roots":[""]}"#,
          entries: [synthetic],
          compositeMedia: [composite],
          capabilities: fixture.session.capabilities,
          coveredRoots: [root],
          reconcileMissingEligible: true,
          discoveredEntryCount: 1
        )
      )
    }

    try await publish(runUID: "disc-cache-run-1", modifiedAt: 100)
    let discLibrary = DiscMediaLibrary(store: store)
    #expect(try await discLibrary.enqueueMissingProbeWork(sourceUID: sourceUID) == 1)
    let lease = try #require(
      try await store.claimScanFileWork(
        sourceUID: sourceUID,
        stage: .probe,
        workerID: "disc-cache-worker",
        limit: 1
      ).first
    )
    guard
      case .probed(let result) = try await discLibrary.process(
        lease,
        using: fixture.session,
        readTimeoutMilliseconds: 1_000
      )
    else {
      Issue.record("expected a fresh deep probe")
      return
    }
    let originalListCount = await fixture.session.listCount
    let originalReadCount = await fixture.session.readCount
    #expect(result.playlists.count == 2)

    try await publish(runUID: "disc-cache-run-2", modifiedAt: 100)
    #expect(try await discLibrary.enqueueMissingProbeWork(sourceUID: sourceUID) == 0)
    #expect(
      try await discLibrary.enqueueMissingProbeWork(
        sourceUID: sourceUID,
        retryTerminalFailures: true
      ) == 0)
    #expect(await fixture.session.listCount == originalListCount)
    #expect(await fixture.session.readCount == originalReadCount)
    guard
      case .confirmed(let cached)? = try await discLibrary.cachedState(
        sourceUID: sourceUID,
        relativePath: fixture.candidate.locator.path.relativePath
      )
    else {
      Issue.record("expected a current successful cache entry")
      return
    }
    #expect(cached == result)

    try await publish(runUID: "disc-cache-run-3", modifiedAt: 101)
    #expect(
      try await discLibrary.cachedState(
        sourceUID: sourceUID,
        relativePath: fixture.candidate.locator.path.relativePath
      ) == nil)
    #expect(try await discLibrary.enqueueMissingProbeWork(sourceUID: sourceUID) == 1)
    #expect(try await discLibrary.enqueueMissingProbeWork(sourceUID: sourceUID) == 0)
  }

  @Test("Closing a blocked range reader wakes it without waiting for timeout")
  func concurrentCloseCancelsRead() async throws {
    let entry = try file("Blocked.iso", bytes: [1, 2, 3])
    let session = try DiscAdapterFixtureSession(
      files: [entry.locator: Data([1, 2, 3])],
      readDelayMilliseconds: 10_000
    )
    let download = try RemoteRangeDownload(
      session: session,
      entry: entry,
      timeoutMilliseconds: 30_000
    )
    let readTask = Task.detached { () -> Int32 in
      var byte: UInt8 = 0
      return download.read(buffer: &byte, size: 1)
    }
    while await session.readCount == 0 { await Task.yield() }
    download.close()
    #expect(await readTask.value == -1)
  }

  @Test("Cancelling the calling task wakes a blocked synchronous range read")
  func taskCancellationWakesRead() async throws {
    let entry = try file("Cancelled.iso", bytes: [1, 2, 3])
    let session = try DiscAdapterFixtureSession(
      files: [entry.locator: Data([1, 2, 3])],
      readDelayMilliseconds: 10_000
    )
    let download = try RemoteRangeDownload(
      session: session,
      entry: entry,
      timeoutMilliseconds: 30_000
    )
    let readTask = Task.detached { () -> Int32 in
      var byte: UInt8 = 0
      return download.read(buffer: &byte, size: 1)
    }
    while await session.readCount == 0 { await Task.yield() }
    readTask.cancel()
    #expect(await readTask.value == -1)
    download.close()
  }

  private func bdmvFixture() throws -> (
    candidate: CompositeMediaDescriptor,
    session: DiscAdapterFixtureSession
  ) {
    let root = try directory("Movie")
    let bdmv = try directory("Movie/BDMV")
    let playlist = try directory("Movie/BDMV/PLAYLIST")
    let stream = try directory("Movie/BDMV/STREAM")
    let index = try file("Movie/BDMV/index.bdmv", bytes: [1])
    let firstMPLS = try file("Movie/BDMV/PLAYLIST/00000.mpls", bytes: mpls(clipID: "00001"))
    let mainMPLS = try file("Movie/BDMV/PLAYLIST/00001.mpls", bytes: mpls(clipID: "00002"))
    let duplicate = try file("Movie/BDMV/PLAYLIST/00002.mpls", bytes: mpls(clipID: "00001"))
    let firstClip = try file(
      "Movie/BDMV/STREAM/00001.m2ts", bytes: [UInt8](repeating: 1, count: 16))
    let mainClip = try file("Movie/BDMV/STREAM/00002.m2ts", bytes: [UInt8](repeating: 2, count: 32))
    let session = try DiscAdapterFixtureSession(
      directories: [
        bdmv.locator: [playlist, stream, index],
        playlist.locator: [firstMPLS, mainMPLS, duplicate],
        stream.locator: [firstClip, mainClip],
      ],
      files: [
        index.locator: Data([1]),
        firstMPLS.locator: Data(mpls(clipID: "00001")),
        mainMPLS.locator: Data(mpls(clipID: "00002")),
        duplicate.locator: Data(mpls(clipID: "00001")),
        firstClip.locator: Data(repeating: 1, count: 16),
        mainClip.locator: Data(repeating: 2, count: 32),
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
    return (candidate, session)
  }

  private func mpls(clipID: String) -> [UInt8] {
    precondition(clipID.utf8.count == 5)
    var bytes = [UInt8](repeating: 0, count: 96)
    func write(_ value: UInt32, at offset: Int) {
      bytes[offset] = UInt8((value >> 24) & 0xff)
      bytes[offset + 1] = UInt8((value >> 16) & 0xff)
      bytes[offset + 2] = UInt8((value >> 8) & 0xff)
      bytes[offset + 3] = UInt8(value & 0xff)
    }
    func write(_ value: UInt16, at offset: Int) {
      bytes[offset] = UInt8((value >> 8) & 0xff)
      bytes[offset + 1] = UInt8(value & 0xff)
    }
    bytes.replaceSubrange(0..<8, with: Array("MPLS0100".utf8))
    write(UInt32(20), at: 8)
    write(UInt32(84), at: 12)
    write(UInt32(0), at: 16)
    write(UInt32(56), at: 20)
    write(UInt16(1), at: 26)
    write(UInt16(0), at: 28)
    write(UInt16(48), at: 30)
    bytes.replaceSubrange(32..<37, with: Array(clipID.utf8))
    bytes.replaceSubrange(37..<41, with: Array("M2TS".utf8))
    bytes[42] = 1
    write(UInt32(0), at: 44)
    write(UInt32(450_000), at: 48)
    write(UInt16(14), at: 64)
    write(UInt32(2), at: 84)
    write(UInt16(0), at: 88)
    return bytes
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
  private let readError: SDKError?
  private(set) var readCount = 0
  private(set) var listCount = 0

  init(
    directories: [RemoteLocator: [RemoteEntry]] = [:],
    files: [RemoteLocator: Data],
    maximumReadSize: Int? = nil,
    readDelayMilliseconds: Int = 0,
    readError: SDKError? = nil
  ) throws {
    self.directories = directories
    self.files = files
    self.maximumReadSize = maximumReadSize
    self.readDelayMilliseconds = readDelayMilliseconds
    self.readError = readError
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
    listCount += 1
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
    if let readError { throw readError }
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

private actor DiscWebDAVTransport: WebDAVTransport {
  private struct Node: Sendable {
    let path: String
    let isDirectory: Bool
    let size: Int?
  }

  private let files: [String: Data]
  private let children: [String: [Node]]
  private(set) var depthOneRequestCount = 0

  init(files: [String: Data]) {
    self.files = files
    func node(_ path: String, directory: Bool = false) -> Node {
      Node(path: path, isDirectory: directory, size: files[path]?.count)
    }
    children = [
      "/media": [node("/media/Movie", directory: true)],
      "/media/Movie": [node("/media/Movie/BDMV", directory: true)],
      "/media/Movie/BDMV": [
        node("/media/Movie/BDMV/PLAYLIST", directory: true),
        node("/media/Movie/BDMV/STREAM", directory: true),
        node("/media/Movie/BDMV/index.bdmv"),
      ],
      "/media/Movie/BDMV/PLAYLIST": [
        node("/media/Movie/BDMV/PLAYLIST/00000.mpls"),
        node("/media/Movie/BDMV/PLAYLIST/00001.mpls"),
        node("/media/Movie/BDMV/PLAYLIST/00002.mpls"),
      ],
      "/media/Movie/BDMV/STREAM": [
        node("/media/Movie/BDMV/STREAM/00001.m2ts"),
        node("/media/Movie/BDMV/STREAM/00002.m2ts"),
      ],
    ]
  }

  func send(_ request: WebDAVHTTPRequest) async throws -> WebDAVHTTPResponse {
    let path = Self.normalized(request.url.path)
    if request.method == "GET" {
      guard let data = files[path], let range = request.headers["Range"],
        let bounds = Self.range(from: range)
      else { return WebDAVHTTPResponse(statusCode: 404) }
      let lower = min(data.count, bounds.lowerBound)
      let upper = min(data.count, bounds.upperBound + 1)
      return WebDAVHTTPResponse(
        statusCode: 206,
        body: lower < upper ? data[lower..<upper] : Data()
      )
    }
    guard request.method == "PROPFIND", let nodes = children[path] else {
      return WebDAVHTTPResponse(statusCode: 404)
    }
    let depth = request.headers["Depth"]
    let selfNode = Node(path: path, isDirectory: true, size: nil)
    if depth == "1" { depthOneRequestCount += 1 }
    let responseNodes = depth == "1" ? [selfNode] + nodes : [selfNode]
    return WebDAVHTTPResponse(statusCode: 207, body: Self.multistatus(responseNodes))
  }

  private static func normalized(_ path: String) -> String {
    path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
  }

  private static func range(from header: String) -> ClosedRange<Int>? {
    guard header.hasPrefix("bytes="),
      let separator = header.firstIndex(of: "-"),
      let start = Int(header[header.index(header.startIndex, offsetBy: 6)..<separator]),
      let end = Int(header[header.index(after: separator)...]), start >= 0, end >= start
    else { return nil }
    return start...end
  }

  private static func multistatus(_ nodes: [Node]) -> Data {
    let responses = nodes.map { node in
      let href = node.path + (node.isDirectory ? "/" : "")
      let resourceType =
        node.isDirectory
        ? "<d:resourcetype><d:collection/></d:resourcetype>"
        : "<d:resourcetype/>"
      let size = node.size.map { "<d:getcontentlength>\($0)</d:getcontentlength>" } ?? ""
      let response: String = """
        <d:response><d:href>\(href)</d:href><d:propstat><d:prop>\(resourceType)\(size)<d:getlastmodified>Sun, 16 Aug 2026 00:00:00 GMT</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        """
      return response
    }.joined()
    return Data(
      """
      <?xml version="1.0" encoding="utf-8"?>
      <d:multistatus xmlns:d="DAV:">\(responses)</d:multistatus>
      """.utf8
    )
  }
}

private actor DiscSMB2Transport: SMB2Transport {
  private let session: DiscSMB2Session

  init(session: DiscSMB2Session) {
    self.session = session
  }

  func connect(_: SMB2ConnectionRequest) async throws -> any SMB2Session { session }
}

private actor DiscSMB2Session: SMB2Session {
  nonisolated let connectionInfo = SMB2ConnectionInfo(
    dialect: .smb311,
    signingPolicy: .enabled,
    encryptionPolicy: .disabled,
    implementationVersion: "disc-fixture"
  )

  private let entriesByDirectory: [SMB2Path: [SMB2Entry]]
  private let entriesByPath: [SMB2Path: SMB2Entry]
  private let files: [SMB2Path: Data]
  private(set) var listRequestCount = 0
  private var disconnected = false

  init(
    entriesByDirectory: [SMB2Path: [SMB2Entry]],
    entriesByPath: [SMB2Path: SMB2Entry],
    files: [SMB2Path: Data]
  ) {
    self.entriesByDirectory = entriesByDirectory
    self.entriesByPath = entriesByPath
    self.files = files
  }

  func listDirectory(at path: SMB2Path) async throws -> [SMB2Entry] {
    try requireConnected()
    listRequestCount += 1
    guard let entries = entriesByDirectory[path] else {
      throw SDKError(code: .metadataNotFound, message: "SMB disc fixture directory is missing")
    }
    return entries
  }

  func stat(_ path: SMB2Path) async throws -> SMB2Entry {
    try requireConnected()
    guard let entry = entriesByPath[path] else {
      throw SDKError(code: .metadataNotFound, message: "SMB disc fixture entry is missing")
    }
    return entry
  }

  func read(at path: SMB2Path, range: SMB2ByteRange) async throws -> Data {
    try requireConnected()
    guard let data = files[path], range.offset < Int64(data.count) else { return Data() }
    let lower = Int(range.offset)
    let upper = min(data.count, lower + range.length)
    return data[lower..<upper]
  }

  func disconnect() async {
    disconnected = true
  }

  private func requireConnected() throws {
    guard !disconnected else {
      throw SDKError(code: .remoteUnavailable, message: "SMB disc fixture disconnected")
    }
  }
}

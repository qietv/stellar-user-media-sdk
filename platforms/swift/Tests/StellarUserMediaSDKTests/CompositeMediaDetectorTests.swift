import Foundation
import StellarCore
import StellarMediaLibrary
import StellarRemoteMedia
import Testing

@Suite("Composite media detector")
struct CompositeMediaDetectorTests {
  @Test("DVD requires both control files and matches sentinel names case-insensitively")
  func dvdStructure() throws {
    let root = try directory("Movies/Example DVD")
    let videoTS = try directory("Movies/Example DVD/video_ts")
    let ifo = try file("Movies/Example DVD/video_ts/video_ts.ifo")
    let bup = try file("Movies/Example DVD/video_ts/VIDEO_TS.BUP")
    let detector = OpticalDiscCandidateDetector()

    let detections = try detector.directoryCandidates(
      rootedAt: root,
      snapshots: [
        try snapshot(root, [videoTS]),
        try snapshot(videoTS, [ifo, bup]),
      ]
    )

    let detection = try #require(detections.first)
    #expect(detections.count == 1)
    #expect(detection.descriptor.kind == .dvdVideo)
    #expect(detection.descriptor.container == .directory)
    #expect(detection.descriptor.confidence == .candidate)
    #expect(detection.descriptor.locator == root.locator)
    #expect(detection.descriptor.entryPoint == ifo.locator)
    #expect(detection.suppressedDescendants == [videoTS.locator])
    #expect(detection.consumeAsLeaf)

    let incomplete = try detector.directoryCandidates(
      rootedAt: root,
      snapshots: [
        try snapshot(root, [videoTS]),
        try snapshot(videoTS, [ifo]),
      ]
    )
    #expect(incomplete.isEmpty)
  }

  @Test("BDMV and AVCHD wrappers resolve to the outer movie directory")
  func blurayStructures() throws {
    let detector = OpticalDiscCandidateDetector()

    let blurayRoot = try directory("Movies/Example Blu-ray")
    let bdmv = try directory("Movies/Example Blu-ray/bDmV")
    let index = try file("Movies/Example Blu-ray/bDmV/INDEX.BDMV")
    let bluray = try detector.directoryCandidates(
      rootedAt: blurayRoot,
      snapshots: [
        try snapshot(blurayRoot, [bdmv]),
        try snapshot(bdmv, [index]),
      ]
    )
    #expect(bluray.map(\.descriptor.kind) == [.bluray])
    #expect(bluray.first?.descriptor.locator == blurayRoot.locator)
    #expect(bluray.first?.descriptor.entryPoint == index.locator)

    let avchdRoot = try directory("Movies/Camera Archive")
    let avchd = try directory("Movies/Camera Archive/avchd")
    let wrappedBDMV = try directory("Movies/Camera Archive/avchd/BDMV")
    let wrappedIndex = try file("Movies/Camera Archive/avchd/BDMV/index.bdmv")
    let wrapped = try detector.directoryCandidates(
      rootedAt: avchdRoot,
      snapshots: [
        try snapshot(avchdRoot, [avchd]),
        try snapshot(avchd, [wrappedBDMV]),
        try snapshot(wrappedBDMV, [wrappedIndex]),
      ]
    )
    #expect(wrapped.map(\.descriptor.kind) == [.avchd])
    #expect(wrapped.first?.descriptor.locator == avchdRoot.locator)
    #expect(wrapped.first?.suppressedDescendants == [avchd.locator])
  }

  @Test("Disk images remain format-unknown candidates until a deep probe")
  func diskImages() throws {
    let detector = OpticalDiscCandidateDetector()

    for path in ["Movies/Movie.ISO", "Movies/Movie.Img"] {
      let entry = try file(path)
      let detection = try #require(try detector.diskImageCandidate(for: entry))
      #expect(detection.descriptor.kind == .unknownDiscImage)
      #expect(detection.descriptor.container == .diskImage)
      #expect(detection.descriptor.logicalRoot == entry.locator)
      #expect(detection.descriptor.entryPoint == nil)
    }

    #expect(try detector.diskImageCandidate(for: file("Movies/Movie.iso.txt")) == nil)
    #expect(try detector.diskImageCandidate(for: directory("Movies/Folder.iso")) == nil)
  }

  @Test("Missing nested snapshots and lookalike names do not consume ordinary directories")
  func insufficientEvidence() throws {
    let root = try directory("Movies/Ordinary")
    let bdmv = try directory("Movies/Ordinary/BDMV Extras")
    let exactBDMV = try directory("Movies/Ordinary/BDMV")
    let detector = OpticalDiscCandidateDetector()

    #expect(
      try detector.directoryCandidates(
        rootedAt: root,
        snapshots: [try snapshot(root, [bdmv])]
      ).isEmpty
    )
    #expect(
      try detector.directoryCandidates(
        rootedAt: root,
        snapshots: [try snapshot(root, [exactBDMV])]
      ).isEmpty
    )
  }

  @Test("A directly selected BDMV directory suppresses every observed internal entry")
  func directBDMVRoot() throws {
    let bdmv = try directory("Movies/Disc/BDMV")
    let playlist = try directory("Movies/Disc/BDMV/PLAYLIST")
    let stream = try directory("Movies/Disc/BDMV/STREAM")
    let index = try file("Movies/Disc/BDMV/index.bdmv")
    let detection = try #require(
      try OpticalDiscCandidateDetector().directDirectoryCandidate(
        rootedAt: bdmv,
        snapshot: snapshot(bdmv, [playlist, stream, index])
      )
    )

    #expect(detection.descriptor.kind == .bluray)
    #expect(detection.descriptor.locator == bdmv.locator)
    #expect(detection.descriptor.logicalRoot.path.relativePath == "Movies/Disc")
    #expect(
      Set(detection.suppressedDescendants) == [playlist.locator, stream.locator, index.locator]
    )
  }

  @Test("Descriptors round-trip with a versioned stable representation")
  func descriptorRoundTrip() throws {
    let image = try file("Movies/Archive.iso")
    let descriptor = try #require(
      try OpticalDiscCandidateDetector().diskImageCandidate(for: image)?.descriptor
    )
    let data = try JSONEncoder().encode(descriptor)
    let decoded = try JSONDecoder().decode(CompositeMediaDescriptor.self, from: data)

    #expect(decoded == descriptor)
    #expect(decoded.schemaVersion == CompositeMediaDescriptor.currentSchemaVersion)
  }

  @Test("Scanner indexes the outer BDMV directory once and never enters its internals")
  func scannerAtomicLeaf() async throws {
    let root = try directory("")
    let movie = try directory("Example Blu-ray")
    let bdmv = try directory("Example Blu-ray/BDMV")
    let index = try file("Example Blu-ray/BDMV/index.bdmv")
    let session = try DiscScanFixtureSession(
      entriesByDirectory: [
        root.locator: [movie],
        movie.locator: [bdmv],
        bdmv.locator: [index],
      ],
      stats: [
        root.locator: root,
        movie.locator: movie,
        bdmv.locator: bdmv,
      ]
    )
    let sink = CompositeRecordingScanSink()
    let request = try MediaScanRequest(
      runUID: "composite-atomic-leaf",
      sourceUID: root.locator.sourceUID,
      mode: .full,
      roots: [root.locator]
    )
    let result = try await MediaScanner(
      configuration: MediaScannerConfiguration(pageSize: 50, maxConcurrentDirectoryRequests: 1)
    ).scan(
      request,
      using: DiscScanFixtureConnector(session: session),
      sink: sink,
      traversalPolicy: TraverseAllMediaScanDirectories(),
      directoryClassifier: OpticalDiscMediaScanClassifier(probePageSize: 2)
    )

    #expect(result.checkpoint.phase == .completed)
    #expect(result.checkpoint.discoveredEntryCount == 1)
    #expect(result.checkpoint.processedPageCount == 2)
    #expect(await session.listCount(for: bdmv.locator) == 1)
    #expect(await session.listCount(for: movie.locator) == 1)

    let entries = await sink.entries
    #expect(entries.contains(where: { $0.locator == movie.locator && $0.kind == .directory }))
    #expect(entries.contains(where: { $0.locator == movie.locator && $0.kind == .file }))
    #expect(!entries.contains(where: { $0.locator == bdmv.locator }))
    #expect(!entries.contains(where: { $0.locator == index.locator }))

    let detections = await sink.compositeMedia
    #expect(detections.map(\.descriptor.kind) == [.bluray])
    #expect(detections.first?.descriptor.locator == movie.locator)
  }

  @Test("Scanner force-admits disk-image candidates before ordinary extension filtering")
  func scannerDiscImageAdmission() async throws {
    let root = try directory("")
    let image = try file("Example.ISO")
    let session = try DiscScanFixtureSession(
      entriesByDirectory: [root.locator: [image]],
      stats: [root.locator: root, image.locator: image]
    )
    let sink = CompositeRecordingScanSink()
    let request = try MediaScanRequest(
      runUID: "composite-disc-image",
      sourceUID: root.locator.sourceUID,
      mode: .full,
      roots: [root.locator]
    )

    _ = try await MediaScanner().scan(
      request,
      using: DiscScanFixtureConnector(session: session),
      sink: sink,
      traversalPolicy: RejectAllFilesTraversalPolicy(),
      directoryClassifier: OpticalDiscMediaScanClassifier()
    )

    #expect(await sink.entries.contains(where: { $0.locator == image.locator }))
    #expect(await sink.compositeMedia.map(\.descriptor.kind) == [.unknownDiscImage])
  }

  private func snapshot(
    _ directory: RemoteEntry,
    _ children: [RemoteEntry]
  ) throws -> CompositeMediaDirectorySnapshot {
    try CompositeMediaDirectorySnapshot(directory: directory, children: children)
  }

  private func directory(_ path: String) throws -> RemoteEntry {
    try entry(path, kind: .directory)
  }

  private func file(_ path: String) throws -> RemoteEntry {
    try entry(path, kind: .file)
  }

  private func entry(_ path: String, kind: RemoteEntryKind) throws -> RemoteEntry {
    try RemoteEntry(
      locator: RemoteLocator(sourceUID: "composite-fixture", path: RemotePath(path)),
      kind: kind,
      stableID: "\(kind.rawValue):\(path)"
    )
  }
}

private struct DiscScanFixtureConnector: MediaSourceConnector {
  let session: DiscScanFixtureSession

  func connect() async throws -> any MediaSourceSession { session }
}

private struct RejectAllFilesTraversalPolicy: MediaScanTraversalPolicy {
  func shouldIndexFile(_: RemoteEntry) -> Bool { false }
  func shouldTraverseDirectory(_: RemoteEntry) -> Bool { true }
}

private actor DiscScanFixtureSession: MediaSourceSession {
  nonisolated let sourceUID = "composite-fixture"
  nonisolated let capabilities: MediaSourceCapabilities

  private let entriesByDirectory: [RemoteLocator: [RemoteEntry]]
  private let stats: [RemoteLocator: RemoteEntry]
  private var listCounts: [RemoteLocator: Int] = [:]

  init(
    entriesByDirectory: [RemoteLocator: [RemoteEntry]],
    stats: [RemoteLocator: RemoteEntry]
  ) throws {
    self.entriesByDirectory = entriesByDirectory
    self.stats = stats
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
    guard request.cursor == nil, let entries = entriesByDirectory[request.directory] else {
      throw SDKError(code: .remoteUnavailable, message: "unexpected fixture directory request")
    }
    listCounts[request.directory, default: 0] += 1
    return try CursorPage(items: entries, nextCursor: nil)
  }

  func stat(_ locator: RemoteLocator) async throws -> RemoteEntry {
    guard let entry = stats[locator] else {
      throw SDKError(code: .metadataNotFound, message: "fixture entry was not found")
    }
    return entry
  }

  func read(at _: RemoteLocator, range _: RemoteByteRange) async throws -> Data {
    throw SDKError(code: .invalidConfiguration, message: "fixture range read is not implemented")
  }

  func disconnect() async {}

  func listCount(for locator: RemoteLocator) -> Int {
    listCounts[locator, default: 0]
  }
}

private actor CompositeRecordingScanSink: MediaScanSink {
  private(set) var entries: [RemoteEntry] = []
  private(set) var compositeMedia: [CompositeMediaDetection] = []

  func commit(_ batch: MediaScanBatch) async throws {
    entries.append(contentsOf: batch.entries)
    compositeMedia.append(contentsOf: batch.compositeMedia)
  }

  func loadEnumerationState(runUID _: String) async throws -> MediaScanEnumerationState? {
    nil
  }
}

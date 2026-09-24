import StellarMediaLibrary
import StellarRemoteMedia
import Testing

@Suite("Media scan scheduler")
struct MediaScanSchedulerTests {
  private let semantics = RemotePathSemantics(
    caseSensitivity: .insensitive,
    unicodeNormalization: .preserve
  )

  @Test("Full trigger subsumes compacted incremental scopes")
  func fullSubsumesIncremental() async throws {
    let scheduler = MediaScanScheduler()
    try await scheduler.submit(
      trigger(.incremental, paths: ["Movies", "Movies/New"], origin: .watcher, time: 1_000),
      pathSemantics: semantics
    )
    try await scheduler.submit(
      trigger(.incremental, paths: ["TV"], origin: .watcher, time: 2_000),
      pathSemantics: semantics
    )
    #expect(try await scheduler.nextReady(atMilliseconds: 3_999) == nil)
    let incremental = try #require(
      try await scheduler.nextReady(atMilliseconds: 4_000)
    )
    #expect(incremental.request.mode == .incremental)
    #expect(incremental.request.roots.map(\.path.relativePath) == ["TV", "Movies"])
    try await scheduler.finish(runUID: incremental.request.runUID)

    try await scheduler.submit(
      trigger(.incremental, paths: ["TV"], origin: .watcher, time: 5_000),
      pathSemantics: semantics
    )
    try await scheduler.submit(
      trigger(.full, paths: [""], origin: .scheduled, time: 5_100),
      pathSemantics: semantics
    )
    let full = try #require(try await scheduler.nextReady(atMilliseconds: 5_100))
    #expect(full.request.mode == .full)
    #expect(full.request.roots.map(\.path.relativePath) == [""])
    #expect(full.origins == [.watcher, .scheduled])
  }

  @Test("Repair does not erase discovery and one source stays active")
  func repairAndDiscoveryRemainSeparate() async throws {
    let scheduler = MediaScanScheduler()
    try await scheduler.submit(
      trigger(.full, paths: [""], origin: .scheduled, time: 1_000),
      pathSemantics: semantics
    )
    try await scheduler.submit(
      trigger(.repair, paths: [], origin: .manual, time: 1_001),
      pathSemantics: semantics
    )
    let repair = try #require(try await scheduler.nextReady(atMilliseconds: 1_001))
    #expect(repair.request.mode == .repair)
    #expect(try await scheduler.nextReady(atMilliseconds: 1_001) == nil)
    #expect(await scheduler.pendingRunCount() == 1)
    try await scheduler.finish(runUID: repair.request.runUID)
    let full = try #require(try await scheduler.nextReady(atMilliseconds: 1_001))
    #expect(full.request.mode == .full)
  }

  private func trigger(
    _ mode: MediaScanMode,
    paths: [String],
    origin: MediaScanTriggerOrigin,
    time: Int64
  ) throws -> MediaScanTrigger {
    try MediaScanTrigger(
      sourceUID: "source-1",
      mode: mode,
      roots: try paths.map {
        try RemoteLocator(sourceUID: "source-1", path: RemotePath($0))
      },
      origin: origin,
      submittedAtMilliseconds: time
    )
  }
}

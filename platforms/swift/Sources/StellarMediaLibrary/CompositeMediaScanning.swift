import Foundation
import StellarCore
import StellarRemoteMedia

/// The optional compound-media projection produced while processing one scanner page.
public struct MediaScanDirectoryClassification: Sendable {
  public let syntheticEntries: [RemoteEntry]
  public let compositeMedia: [CompositeMediaDetection]
  public let suppressedEntries: [RemoteLocator]
  public let forceIndexedFiles: [RemoteLocator]

  public init(
    syntheticEntries: [RemoteEntry] = [],
    compositeMedia: [CompositeMediaDetection] = [],
    suppressedEntries: [RemoteLocator] = [],
    forceIndexedFiles: [RemoteLocator] = []
  ) {
    self.syntheticEntries = syntheticEntries
    self.compositeMedia = compositeMedia
    self.suppressedEntries = suppressedEntries
    self.forceIndexedFiles = forceIndexedFiles
  }
}

/// An asynchronous classification seam for directory structures that cannot be decided per entry.
public protocol MediaScanDirectoryClassifier: Sendable {
  /// Classifies structures visible in one page before its child directories enter the frontier.
  func classify(
    directory: RemoteLocator,
    entries: [RemoteEntry],
    using session: any MediaSourceSession
  ) async throws -> MediaScanDirectoryClassification
}

/// The default classifier that preserves ordinary recursive scanner behavior.
public struct NoopMediaScanDirectoryClassifier: MediaScanDirectoryClassifier {
  public init() {}

  public func classify(
    directory _: RemoteLocator,
    entries _: [RemoteEntry],
    using _: any MediaSourceSession
  ) async throws -> MediaScanDirectoryClassification {
    MediaScanDirectoryClassification()
  }
}

/// Recognizes optical-disc directory sentinels and projects their outer directory as one item.
///
/// This classifier still performs only structural candidate detection. BDMVIOContext confirms and
/// opens the candidate in the later probe/playback stage.
public struct OpticalDiscMediaScanClassifier: MediaScanDirectoryClassifier {
  public let probePageSize: Int

  public init(probePageSize: Int = 500) throws {
    guard (1...10_000).contains(probePageSize) else {
      throw SDKError(
        code: .invalidConfiguration,
        message: "optical-disc probe page size is invalid"
      )
    }
    self.probePageSize = probePageSize
  }

  public func classify(
    directory: RemoteLocator,
    entries: [RemoteEntry],
    using session: any MediaSourceSession
  ) async throws -> MediaScanDirectoryClassification {
    let detector = OpticalDiscCandidateDetector()
    var imageDetections: [CompositeMediaDetection] = []
    var forcedImageLocators: [RemoteLocator] = []
    var sentinels: [RemoteEntry] = []
    for entry in entries {
      if let detection = try detector.diskImageCandidate(for: entry) {
        imageDetections.append(detection)
        forcedImageLocators.append(detection.descriptor.locator)
      } else if entry.kind == .directory,
        Self.isSentinelDirectoryName(entry.locator.path.name)
      {
        sentinels.append(entry)
      }
    }
    let directSentinel = Self.isDirectSentinelDirectoryName(directory.path.name)
    guard !sentinels.isEmpty || directSentinel else {
      return MediaScanDirectoryClassification(
        compositeMedia: imageDetections,
        forceIndexedFiles: forcedImageLocators
      )
    }

    let root = try await session.stat(directory)
    guard root.locator == directory, root.kind == .directory else {
      throw SDKError(code: .parseFailure, message: "disc candidate root changed during scan")
    }

    var snapshots = [try CompositeMediaDirectorySnapshot(directory: root, children: entries)]
    for sentinel in sentinels {
      let sentinelSnapshot = try await snapshot(of: sentinel, using: session)
      snapshots.append(sentinelSnapshot)

      guard Self.asciiCaseInsensitiveEqual(sentinel.locator.path.name, "AVCHD") else {
        continue
      }
      for bdmv in sentinelSnapshot.children
      where bdmv.kind == .directory
        && Self.asciiCaseInsensitiveEqual(bdmv.locator.path.name, "BDMV")
      {
        snapshots.append(try await snapshot(of: bdmv, using: session))
      }
    }

    var directoryDetections = try detector.directoryCandidates(
      rootedAt: root,
      snapshots: snapshots
    )
    if directoryDetections.isEmpty, directSentinel,
      let direct = try detector.directDirectoryCandidate(
        rootedAt: root,
        snapshot: snapshots[0]
      )
    {
      directoryDetections = [direct]
    }
    guard !directoryDetections.isEmpty else {
      return MediaScanDirectoryClassification(
        compositeMedia: imageDetections,
        forceIndexedFiles: forcedImageLocators
      )
    }

    let synthetic = try RemoteEntry(
      locator: root.locator,
      kind: .file,
      stableID: root.stableID,
      size: nil,
      modifiedAtMilliseconds: root.modifiedAtMilliseconds,
      entityTag: root.entityTag
    )
    return MediaScanDirectoryClassification(
      syntheticEntries: [synthetic],
      compositeMedia: imageDetections + directoryDetections,
      suppressedEntries: Self.uniqueLocators(
        directoryDetections.flatMap(\.suppressedDescendants)
      ),
      forceIndexedFiles: forcedImageLocators
    )
  }

  private func snapshot(
    of directory: RemoteEntry,
    using session: any MediaSourceSession
  ) async throws -> CompositeMediaDirectorySnapshot {
    var children: [RemoteEntry] = []
    var cursor: String?
    var seenCursors = Set<String>()
    repeat {
      try Task.checkCancellation()
      let request = try RemoteDirectoryPageRequest(
        directory: directory.locator,
        cursor: cursor,
        limit: probePageSize
      )
      let page = try await session.listDirectory(request)
      children.append(contentsOf: page.items)
      cursor = page.nextCursor
      if let cursor, !seenCursors.insert(cursor).inserted {
        throw SDKError(code: .parseFailure, message: "disc probe repeated a page cursor")
      }
    } while cursor != nil
    return try CompositeMediaDirectorySnapshot(directory: directory, children: children)
  }

  private static func isSentinelDirectoryName(_ name: String) -> Bool {
    asciiCaseInsensitiveEqual(name, "VIDEO_TS")
      || asciiCaseInsensitiveEqual(name, "BDMV")
      || asciiCaseInsensitiveEqual(name, "AVCHD")
  }

  private static func isDirectSentinelDirectoryName(_ name: String) -> Bool {
    asciiCaseInsensitiveEqual(name, "VIDEO_TS")
      || asciiCaseInsensitiveEqual(name, "BDMV")
  }

  private static func uniqueLocators(_ locators: [RemoteLocator]) -> [RemoteLocator] {
    var seen = Set<RemoteLocator>()
    return locators.filter { seen.insert($0).inserted }
  }

  private static func asciiCaseInsensitiveEqual<S: StringProtocol>(
    _ lhs: S,
    _ rhs: String
  ) -> Bool {
    lhs.utf8.elementsEqual(rhs.utf8) { left, right in
      let foldedLeft = (0x41...0x5A).contains(left) ? left + 0x20 : left
      let foldedRight = (0x41...0x5A).contains(right) ? right + 0x20 : right
      return foldedLeft == foldedRight
    }
  }
}

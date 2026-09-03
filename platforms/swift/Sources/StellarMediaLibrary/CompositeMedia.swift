import Foundation
import StellarCore
import StellarRemoteMedia

/// The physical container that exposes one logical optical-disc media item.
public enum CompositeMediaContainer: String, Codable, Equatable, Sendable {
  case directory
  case diskImage = "disk_image"
}

/// A source-independent optical-disc format classification.
public enum CompositeMediaKind: String, Codable, Equatable, Sendable {
  case bluray
  case avchd
  case dvdVideo = "dvd_video"
  case unknownDiscImage = "unknown_disc_image"
}

/// Whether a classification is structural-only or verified by a format parser.
public enum CompositeMediaConfidence: String, Codable, Equatable, Sendable {
  case candidate
  case confirmed
}

/// A stable projection of a compound directory or image as one logical media item.
public struct CompositeMediaDescriptor: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let locator: RemoteLocator
  public let logicalRoot: RemoteLocator
  public let container: CompositeMediaContainer
  public let kind: CompositeMediaKind
  public let confidence: CompositeMediaConfidence
  public let entryPoint: RemoteLocator?

  public init(
    locator: RemoteLocator,
    logicalRoot: RemoteLocator,
    container: CompositeMediaContainer,
    kind: CompositeMediaKind,
    confidence: CompositeMediaConfidence,
    entryPoint: RemoteLocator? = nil
  ) throws {
    try self.init(
      schemaVersion: Self.currentSchemaVersion,
      locator: locator,
      logicalRoot: logicalRoot,
      container: container,
      kind: kind,
      confidence: confidence,
      entryPoint: entryPoint
    )
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
        locator: container.decode(RemoteLocator.self, forKey: .locator),
        logicalRoot: container.decode(RemoteLocator.self, forKey: .logicalRoot),
        container: container.decode(CompositeMediaContainer.self, forKey: .container),
        kind: container.decode(CompositeMediaKind.self, forKey: .kind),
        confidence: container.decode(CompositeMediaConfidence.self, forKey: .confidence),
        entryPoint: container.decodeIfPresent(RemoteLocator.self, forKey: .entryPoint)
      )
    } catch let error as SDKError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message)
      )
    }
  }

  private init(
    schemaVersion: Int,
    locator: RemoteLocator,
    logicalRoot: RemoteLocator,
    container: CompositeMediaContainer,
    kind: CompositeMediaKind,
    confidence: CompositeMediaConfidence,
    entryPoint: RemoteLocator?
  ) throws {
    guard schemaVersion == Self.currentSchemaVersion,
      logicalRoot.sourceUID == locator.sourceUID,
      entryPoint?.sourceUID == nil || entryPoint?.sourceUID == locator.sourceUID,
      container != .diskImage || (logicalRoot == locator && entryPoint == nil),
      kind != .unknownDiscImage || container == .diskImage
    else {
      throw SDKError(code: .parseFailure, message: "composite media descriptor is invalid")
    }
    self.schemaVersion = schemaVersion
    self.locator = locator
    self.logicalRoot = logicalRoot
    self.container = container
    self.kind = kind
    self.confidence = confidence
    self.entryPoint = entryPoint
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case locator
    case logicalRoot = "logical_root"
    case container
    case kind
    case confidence
    case entryPoint = "entry_point"
  }
}

/// One observed directory snapshot consumed by the pure structure detector.
///
/// Sentinel-directory snapshots must be complete. The root snapshot may be one scanner page
/// because a candidate is classified when that page exposes its sentinel child.
public struct CompositeMediaDirectorySnapshot: Equatable, Sendable {
  public let directory: RemoteEntry
  public let children: [RemoteEntry]

  public init(directory: RemoteEntry, children: [RemoteEntry]) throws {
    guard directory.kind == .directory,
      children.allSatisfy({ child in
        child.locator.sourceUID == directory.locator.sourceUID
          && child.locator.path.parent == directory.locator.path
      })
    else {
      throw SDKError(code: .parseFailure, message: "composite media snapshot is invalid")
    }
    self.directory = directory
    self.children = children
  }
}

/// A detector result that tells the scanner to keep the outer item and suppress its internals.
public struct CompositeMediaDetection: Codable, Equatable, Sendable {
  public let descriptor: CompositeMediaDescriptor
  public let consumeAsLeaf: Bool
  public let suppressedDescendants: [RemoteLocator]

  public init(
    descriptor: CompositeMediaDescriptor,
    consumeAsLeaf: Bool,
    suppressedDescendants: [RemoteLocator]
  ) {
    self.descriptor = descriptor
    self.consumeAsLeaf = consumeAsLeaf
    self.suppressedDescendants = suppressedDescendants
  }
}

/// Cheap optical-disc candidate detection over caller-provided directory snapshots.
///
/// This type performs no I/O and does not parse UDF, MPLS, IFO, or media payloads. Blu-ray
/// candidates must be confirmed later by the BDMVIOContext-backed probe.
public struct OpticalDiscCandidateDetector: Sendable {
  public init() {}

  /// Recognizes a supported disk-image extension without guessing its contained disc format.
  public func diskImageCandidate(for entry: RemoteEntry) throws -> CompositeMediaDetection? {
    guard entry.kind == .file,
      let pathExtension = Self.pathExtension(of: entry.locator.path.name),
      Self.asciiCaseInsensitiveEqual(pathExtension, "iso")
        || Self.asciiCaseInsensitiveEqual(pathExtension, "img")
    else {
      return nil
    }

    return CompositeMediaDetection(
      descriptor: try CompositeMediaDescriptor(
        locator: entry.locator,
        logicalRoot: entry.locator,
        container: .diskImage,
        kind: .unknownDiscImage,
        confidence: .candidate
      ),
      consumeAsLeaf: true,
      suppressedDescendants: []
    )
  }

  /// Finds every valid optical-disc structure rooted at `root`.
  ///
  /// `snapshots` must contain an observed snapshot for `root` and a complete snapshot for each
  /// sentinel directory the caller wants to validate. A missing nested snapshot is treated as
  /// insufficient evidence, not as a malformed disc. Returning multiple candidates preserves
  /// ambiguous fixture evidence for the later authoritative parser instead of silently choosing
  /// one format.
  public func directoryCandidates(
    rootedAt root: RemoteEntry,
    snapshots: [CompositeMediaDirectorySnapshot]
  ) throws -> [CompositeMediaDetection] {
    guard root.kind == .directory else { return [] }

    var snapshotByLocator: [RemoteLocator: CompositeMediaDirectorySnapshot] = [:]
    for snapshot in snapshots {
      guard snapshot.directory.locator.sourceUID == root.locator.sourceUID else {
        throw SDKError(code: .parseFailure, message: "composite media snapshots cross sources")
      }
      snapshotByLocator[snapshot.directory.locator] = snapshot
    }
    guard let rootSnapshot = snapshotByLocator[root.locator] else { return [] }

    var detections: [CompositeMediaDetection] = []
    if let videoTS = Self.childDirectory(named: "VIDEO_TS", in: rootSnapshot),
      let contents = snapshotByLocator[videoTS.locator],
      let ifo = Self.childFile(named: "VIDEO_TS.IFO", in: contents),
      Self.childFile(named: "VIDEO_TS.BUP", in: contents) != nil
    {
      detections.append(
        try directoryDetection(
          root: root,
          kind: .dvdVideo,
          entryPoint: ifo.locator,
          suppressedRoot: videoTS.locator
        )
      )
    }

    if let bdmv = Self.childDirectory(named: "BDMV", in: rootSnapshot),
      let contents = snapshotByLocator[bdmv.locator],
      let index = Self.childFile(named: "index.bdmv", in: contents)
    {
      detections.append(
        try directoryDetection(
          root: root,
          kind: .bluray,
          entryPoint: index.locator,
          suppressedRoot: bdmv.locator
        )
      )
    }

    if let avchd = Self.childDirectory(named: "AVCHD", in: rootSnapshot),
      let avchdContents = snapshotByLocator[avchd.locator],
      let bdmv = Self.childDirectory(named: "BDMV", in: avchdContents),
      let bdmvContents = snapshotByLocator[bdmv.locator],
      let index = Self.childFile(named: "index.bdmv", in: bdmvContents)
    {
      detections.append(
        try directoryDetection(
          root: root,
          kind: .avchd,
          entryPoint: index.locator,
          suppressedRoot: avchd.locator
        )
      )
    }
    return detections
  }

  /// Recognizes a caller-selected `BDMV` or `VIDEO_TS` directory as the logical leaf itself.
  public func directDirectoryCandidate(
    rootedAt root: RemoteEntry,
    snapshot: CompositeMediaDirectorySnapshot
  ) throws -> CompositeMediaDetection? {
    guard root.kind == .directory, snapshot.directory.locator == root.locator else { return nil }
    let name = root.locator.path.name
    let logicalRoot =
      try root.locator.path.parent.map {
        try RemoteLocator(sourceUID: root.locator.sourceUID, path: $0)
      } ?? root.locator

    let kind: CompositeMediaKind
    let entryPoint: RemoteLocator
    if Self.asciiCaseInsensitiveEqual(name, "BDMV"),
      let index = Self.childFile(named: "index.bdmv", in: snapshot)
    {
      kind = .bluray
      entryPoint = index.locator
    } else if Self.asciiCaseInsensitiveEqual(name, "VIDEO_TS"),
      let ifo = Self.childFile(named: "VIDEO_TS.IFO", in: snapshot),
      Self.childFile(named: "VIDEO_TS.BUP", in: snapshot) != nil
    {
      kind = .dvdVideo
      entryPoint = ifo.locator
    } else {
      return nil
    }

    return CompositeMediaDetection(
      descriptor: try CompositeMediaDescriptor(
        locator: root.locator,
        logicalRoot: logicalRoot,
        container: .directory,
        kind: kind,
        confidence: .candidate,
        entryPoint: entryPoint
      ),
      consumeAsLeaf: true,
      suppressedDescendants: snapshot.children.map(\.locator)
    )
  }

  private func directoryDetection(
    root: RemoteEntry,
    kind: CompositeMediaKind,
    entryPoint: RemoteLocator,
    suppressedRoot: RemoteLocator
  ) throws -> CompositeMediaDetection {
    CompositeMediaDetection(
      descriptor: try CompositeMediaDescriptor(
        locator: root.locator,
        logicalRoot: root.locator,
        container: .directory,
        kind: kind,
        confidence: .candidate,
        entryPoint: entryPoint
      ),
      consumeAsLeaf: true,
      suppressedDescendants: [suppressedRoot]
    )
  }

  private static func childDirectory(
    named name: String,
    in snapshot: CompositeMediaDirectorySnapshot
  ) -> RemoteEntry? {
    child(named: name, kind: .directory, in: snapshot)
  }

  private static func childFile(
    named name: String,
    in snapshot: CompositeMediaDirectorySnapshot
  ) -> RemoteEntry? {
    child(named: name, kind: .file, in: snapshot)
  }

  private static func child(
    named name: String,
    kind: RemoteEntryKind,
    in snapshot: CompositeMediaDirectorySnapshot
  ) -> RemoteEntry? {
    snapshot.children.first { entry in
      entry.kind == kind && asciiCaseInsensitiveEqual(entry.locator.path.name, name)
    }
  }

  private static func pathExtension(of name: String) -> Substring? {
    guard let separator = name.lastIndex(of: "."), separator != name.startIndex else {
      return nil
    }
    let start = name.index(after: separator)
    guard start != name.endIndex else { return nil }
    return name[start...]
  }

  private static func asciiCaseInsensitiveEqual<S: StringProtocol>(
    _ lhs: S,
    _ rhs: String
  ) -> Bool {
    lhs.utf8.elementsEqual(rhs.utf8) { left, right in
      asciiLowercased(left) == asciiLowercased(right)
    }
  }

  private static func asciiLowercased(_ byte: UInt8) -> UInt8 {
    (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
  }
}

internal import BDMVIOContext
import Foundation
internal import KSPlayer
import StellarCore
import StellarMediaLibrary
import StellarRemoteMedia

/// The versioned primary-title rule used by disc probing and cache invalidation.
public enum DiscPlaylistSelectionRule: String, Codable, Equatable, Sendable {
  case maximumPlaylistSize = "maximum_playlist_size"

  public static let currentVersion = 1
}

/// One contiguous file segment in a playlist.
public struct DiscPlaylistSegment: Codable, Equatable, Sendable {
  public let index: Int
  public let startMilliseconds: Int64
  public let durationMilliseconds: Int64
  public let sizeBytes: Int64
  public let endOffsetBytes: Int64

  public init(
    index: Int,
    startMilliseconds: Int64,
    durationMilliseconds: Int64,
    sizeBytes: Int64,
    endOffsetBytes: Int64
  ) throws {
    guard index >= 0, startMilliseconds >= 0, durationMilliseconds >= 0,
      sizeBytes >= 0, endOffsetBytes >= sizeBytes
    else {
      throw SDKError(code: .invalidConfiguration, message: "disc playlist segment is invalid")
    }
    self.index = index
    self.startMilliseconds = startMilliseconds
    self.durationMilliseconds = durationMilliseconds
    self.sizeBytes = sizeBytes
    self.endOffsetBytes = endOffsetBytes
  }

  private enum CodingKeys: String, CodingKey {
    case index
    case startMilliseconds = "start_ms"
    case durationMilliseconds = "duration_ms"
    case sizeBytes = "size_bytes"
    case endOffsetBytes = "end_offset_bytes"
  }
}

/// One playlist projected without exposing BDMVIOContext or KSPlayer protocol types.
public struct DiscPlaylistSummary: Codable, Equatable, Sendable {
  public let identifier: String
  public let durationMilliseconds: Int64
  public let sizeBytes: Int64
  public let isSelected: Bool
  public let segments: [DiscPlaylistSegment]

  public init(
    identifier: String,
    durationMilliseconds: Int64,
    sizeBytes: Int64,
    isSelected: Bool,
    segments: [DiscPlaylistSegment] = []
  ) throws {
    guard !identifier.isEmpty, !identifier.contains("\0"), durationMilliseconds >= 0,
      sizeBytes >= 0, segments.indices.allSatisfy({ segments[$0].index == $0 })
    else {
      throw SDKError(code: .invalidConfiguration, message: "disc playlist summary is invalid")
    }
    self.identifier = identifier
    self.durationMilliseconds = durationMilliseconds
    self.sizeBytes = sizeBytes
    self.isSelected = isSelected
    self.segments = segments
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      identifier: container.decode(String.self, forKey: .identifier),
      durationMilliseconds: container.decode(Int64.self, forKey: .durationMilliseconds),
      sizeBytes: container.decode(Int64.self, forKey: .sizeBytes),
      isSelected: container.decode(Bool.self, forKey: .isSelected),
      segments: container.decodeIfPresent([DiscPlaylistSegment].self, forKey: .segments) ?? []
    )
  }

  private enum CodingKeys: String, CodingKey {
    case identifier
    case durationMilliseconds = "duration_ms"
    case sizeBytes = "size_bytes"
    case isSelected = "is_selected"
    case segments
  }
}

/// Source I/O performed by the first deep probe. Cached reads preserve these diagnostics.
public struct DiscMediaProbeMetrics: Codable, Equatable, Sendable {
  public static let zero = try! DiscMediaProbeMetrics(elapsedMilliseconds: 0)

  public let elapsedMilliseconds: Int64
  public let directoryListRequestCount: Int
  public let rangeReadRequestCount: Int
  public let rangeBytesRead: Int64

  public init(
    elapsedMilliseconds: Int64,
    directoryListRequestCount: Int = 0,
    rangeReadRequestCount: Int = 0,
    rangeBytesRead: Int64 = 0
  ) throws {
    guard elapsedMilliseconds >= 0, directoryListRequestCount >= 0,
      rangeReadRequestCount >= 0, rangeBytesRead >= 0
    else {
      throw SDKError(code: .invalidConfiguration, message: "disc probe metrics are invalid")
    }
    self.elapsedMilliseconds = elapsedMilliseconds
    self.directoryListRequestCount = directoryListRequestCount
    self.rangeReadRequestCount = rangeReadRequestCount
    self.rangeBytesRead = rangeBytesRead
  }

  private enum CodingKeys: String, CodingKey {
    case elapsedMilliseconds = "elapsed_ms"
    case directoryListRequestCount = "directory_list_requests"
    case rangeReadRequestCount = "range_read_requests"
    case rangeBytesRead = "range_bytes_read"
  }
}

/// A typed failure retained independently from the generic queue error code.
public enum DiscMediaProbeFailure: String, Codable, Equatable, Sendable {
  case unsupported
  case corruptStructure = "corrupt_structure"
  case encrypted
  case cancelled
  case remoteUnavailable = "remote_unavailable"
  case dependencyFailure = "dependency_failure"

  public var isRetryable: Bool {
    switch self {
    case .cancelled, .remoteUnavailable, .dependencyFailure: true
    case .unsupported, .corruptStructure, .encrypted: false
    }
  }
}

/// A stable handoff from library UI to a player-specific BDMV byte-stream opener.
public struct DiscMediaPlaybackSelection: Codable, Equatable, Sendable {
  public let descriptor: CompositeMediaDescriptor
  public let playlistIdentifier: String
  public let durationMilliseconds: Int64
  public let segments: [DiscPlaylistSegment]

  public init(
    descriptor: CompositeMediaDescriptor,
    playlistIdentifier: String,
    durationMilliseconds: Int64,
    segments: [DiscPlaylistSegment]
  ) throws {
    guard descriptor.confidence == .confirmed, !playlistIdentifier.isEmpty,
      !playlistIdentifier.contains("\0"), durationMilliseconds >= 0
    else {
      throw SDKError(code: .invalidConfiguration, message: "disc playback selection is invalid")
    }
    self.descriptor = descriptor
    self.playlistIdentifier = playlistIdentifier
    self.durationMilliseconds = durationMilliseconds
    self.segments = segments
  }

  private enum CodingKeys: String, CodingKey {
    case descriptor
    case playlistIdentifier = "playlist_identifier"
    case durationMilliseconds = "duration_ms"
    case segments
  }
}

/// One elementary-stream PID and its normalized language code.
public struct DiscStreamLanguage: Codable, Equatable, Sendable {
  public let packetIdentifier: Int32
  public let languageCode: String

  public init(packetIdentifier: Int32, languageCode: String) throws {
    guard packetIdentifier >= 0, !languageCode.isEmpty, !languageCode.contains("\0") else {
      throw SDKError(code: .invalidConfiguration, message: "disc stream language is invalid")
    }
    self.packetIdentifier = packetIdentifier
    self.languageCode = languageCode
  }

  private enum CodingKeys: String, CodingKey {
    case packetIdentifier = "packet_identifier"
    case languageCode = "language_code"
  }
}

/// A stable, dependency-free result from a BDMVIOContext-backed local UDF image probe.
public struct DiscMediaProbeResult: Codable, Equatable, Sendable {
  public let descriptor: CompositeMediaDescriptor
  public let playlists: [DiscPlaylistSummary]
  public let audioLanguages: [DiscStreamLanguage]
  public let subtitleLanguages: [DiscStreamLanguage]
  public let selectionRule: DiscPlaylistSelectionRule
  public let selectionRuleVersion: Int
  public let metrics: DiscMediaProbeMetrics

  public init(
    descriptor: CompositeMediaDescriptor,
    playlists: [DiscPlaylistSummary],
    audioLanguages: [DiscStreamLanguage],
    subtitleLanguages: [DiscStreamLanguage],
    selectionRule: DiscPlaylistSelectionRule = .maximumPlaylistSize,
    selectionRuleVersion: Int = DiscPlaylistSelectionRule.currentVersion,
    metrics: DiscMediaProbeMetrics = .zero
  ) throws {
    guard descriptor.confidence == .confirmed, !playlists.isEmpty,
      playlists.filter(\.isSelected).count == 1, selectionRuleVersion > 0
    else {
      throw SDKError(code: .invalidConfiguration, message: "disc probe result is invalid")
    }
    self.descriptor = descriptor
    self.playlists = playlists
    self.audioLanguages = audioLanguages
    self.subtitleLanguages = subtitleLanguages
    self.selectionRule = selectionRule
    self.selectionRuleVersion = selectionRuleVersion
    self.metrics = metrics
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      descriptor: container.decode(CompositeMediaDescriptor.self, forKey: .descriptor),
      playlists: container.decode([DiscPlaylistSummary].self, forKey: .playlists),
      audioLanguages: container.decode([DiscStreamLanguage].self, forKey: .audioLanguages),
      subtitleLanguages: container.decode([DiscStreamLanguage].self, forKey: .subtitleLanguages),
      selectionRule: container.decodeIfPresent(
        DiscPlaylistSelectionRule.self, forKey: .selectionRule)
        ?? .maximumPlaylistSize,
      selectionRuleVersion: container.decodeIfPresent(Int.self, forKey: .selectionRuleVersion)
        ?? DiscPlaylistSelectionRule.currentVersion,
      metrics: container.decodeIfPresent(DiscMediaProbeMetrics.self, forKey: .metrics)
        ?? (try DiscMediaProbeMetrics(elapsedMilliseconds: 0))
    )
  }

  public func playbackSelection(
    playlistIdentifier: String? = nil
  ) throws -> DiscMediaPlaybackSelection {
    let playlist: DiscPlaylistSummary?
    if let playlistIdentifier {
      playlist = playlists.first { $0.identifier == playlistIdentifier }
    } else {
      playlist = playlists.first(where: \.isSelected)
    }
    guard let playlist else {
      throw SDKError(code: .metadataNotFound, message: "disc playlist was not found")
    }
    return try DiscMediaPlaybackSelection(
      descriptor: descriptor,
      playlistIdentifier: playlist.identifier,
      durationMilliseconds: playlist.durationMilliseconds,
      segments: playlist.segments
    )
  }

  private enum CodingKeys: String, CodingKey {
    case descriptor
    case playlists
    case audioLanguages = "audio_languages"
    case subtitleLanguages = "subtitle_languages"
    case selectionRule = "selection_rule"
    case selectionRuleVersion = "selection_rule_version"
    case metrics
  }
}

/// Opens a local UDF image with BDMVIOContext and projects its playlists into stable SDK DTOs.
public struct BDMVIOContextLocalImageProbe: Sendable {
  public init() {}

  public func probe(
    imageAt url: URL,
    candidate: CompositeMediaDescriptor,
    streamIdentifier: String? = nil
  ) async throws -> DiscMediaProbeResult {
    guard url.isFileURL, candidate.container == .diskImage,
      candidate.confidence == .candidate,
      streamIdentifier?.isEmpty != true,
      streamIdentifier?.contains("\0") != true
    else {
      throw SDKError(code: .invalidConfiguration, message: "disc image probe request is invalid")
    }
    try Task.checkCancellation()
    let startedAt = DispatchTime.now().uptimeNanoseconds

    let task = Task.detached(priority: .utility) {
      try await BDMVIOContext(
        download: LocalFileDownload(url: url),
        streamName: streamIdentifier
      )
    }
    let context: BDMVIOContext
    do {
      context = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
    } catch is CancellationError {
      throw SDKError(code: .cancelled, message: "disc image probe was cancelled")
    } catch {
      throw SDKError(code: .parseFailure, message: "BDMVIOContext could not parse disc image")
    }
    defer { context.close() }
    try Task.checkCancellation()
    return try BDMVProbeProjection.result(
      context: context,
      candidate: candidate,
      metrics: DiscMediaProbeMetrics(
        elapsedMilliseconds: BDMVProbeProjection.elapsedMilliseconds(since: startedAt)
      )
    )
  }
}

/// Opens an SDK-backed remote UDF image through BDMVIOContext without downloading it in full.
public struct BDMVIOContextRemoteImageProbe: Sendable {
  public init() {}

  public func probe(
    entry: RemoteEntry,
    candidate: CompositeMediaDescriptor,
    using session: any MediaSourceSession,
    streamIdentifier: String? = nil,
    readTimeoutMilliseconds: Int = 30_000
  ) async throws -> DiscMediaProbeResult {
    let capabilities = await session.capabilities
    guard capabilities.supportsRangeReads else {
      throw SDKError(
        code: .invalidConfiguration,
        message: "disc source does not support reliable range reads"
      )
    }
    guard entry.locator == candidate.locator,
      candidate.container == .diskImage, candidate.confidence == .candidate,
      streamIdentifier?.isEmpty != true, streamIdentifier?.contains("\0") != true
    else {
      throw SDKError(code: .invalidConfiguration, message: "remote disc image probe is invalid")
    }
    let startedAt = DispatchTime.now().uptimeNanoseconds
    let metrics = DiscProbeMetricsAccumulator()
    let failureRecorder = DiscProbeIOFailureRecorder()
    let download = try RemoteRangeDownload(
      session: session,
      entry: entry,
      timeoutMilliseconds: readTimeoutMilliseconds,
      readAheadBytes: 128 * 1_024,
      metrics: metrics,
      failureRecorder: failureRecorder
    )
    let task = Task.detached(priority: .utility) {
      try await BDMVIOContext(download: download, streamName: streamIdentifier)
    }
    let context: BDMVIOContext
    do {
      context = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        download.close()
        task.cancel()
      }
    } catch {
      download.close()
      if let ioFailure = failureRecorder.failure() {
        throw BDMVProbeProjection.error(from: ioFailure)
      }
      throw BDMVProbeProjection.error(from: error)
    }
    defer { context.close() }
    try Task.checkCancellation()
    return try BDMVProbeProjection.result(
      context: context,
      candidate: candidate,
      metrics: metrics.snapshot(
        elapsedMilliseconds: BDMVProbeProjection.elapsedMilliseconds(since: startedAt)
      )
    )
  }
}

/// Confirms a BDMV, AVCHD, or DVD-Video directory through BDMVIOContext's FilesManager entry point.
public struct BDMVIOContextRemoteDirectoryProbe: Sendable {
  public init() {}

  public func probe(
    candidate: CompositeMediaDescriptor,
    using session: any MediaSourceSession,
    streamIdentifier: String? = nil,
    pageSize: Int = 500,
    readTimeoutMilliseconds: Int = 30_000
  ) async throws -> DiscMediaProbeResult {
    let capabilities = await session.capabilities
    guard capabilities.supportsRangeReads else {
      throw SDKError(
        code: .invalidConfiguration,
        message: "disc source does not support reliable range reads"
      )
    }
    guard candidate.container == .directory,
      candidate.kind == .bluray || candidate.kind == .avchd || candidate.kind == .dvdVideo,
      candidate.confidence == .candidate,
      streamIdentifier?.isEmpty != true,
      streamIdentifier?.contains("\0") != true
    else {
      throw SDKError(code: .invalidConfiguration, message: "remote BDMV probe is invalid")
    }
    let startedAt = DispatchTime.now().uptimeNanoseconds
    let manager = try RemoteBDMVFilesManager(
      session: session,
      candidate: candidate,
      pageSize: pageSize,
      readTimeoutMilliseconds: readTimeoutMilliseconds
    )
    let task = Task.detached(priority: .utility) {
      try await BDMVIOContext(filesManager: manager, streamName: streamIdentifier)
    }
    let context: BDMVIOContext
    do {
      context = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        manager.close()
        task.cancel()
      }
    } catch {
      manager.close()
      if let ioFailure = manager.recordedIOFailure() {
        throw BDMVProbeProjection.error(from: ioFailure)
      }
      throw BDMVProbeProjection.error(from: error)
    }
    defer { context.close() }
    try Task.checkCancellation()
    return try BDMVProbeProjection.result(
      context: context,
      candidate: candidate,
      confirmedKind: candidate.kind,
      metrics: manager.metrics(
        elapsedMilliseconds: BDMVProbeProjection.elapsedMilliseconds(since: startedAt)
      )
    )
  }
}

private enum BDMVProbeProjection {
  static func result(
    context: BDMVIOContext,
    candidate: CompositeMediaDescriptor,
    confirmedKind: CompositeMediaKind? = nil,
    metrics: DiscMediaProbeMetrics
  ) throws -> DiscMediaProbeResult {
    let selectedName = context.currentStream?.name
    guard let selectedIndex = context.playlists.firstIndex(where: { $0.name == selectedName })
    else {
      throw SDKError(code: .parseFailure, message: "BDMVIOContext selected no playlist")
    }
    let descriptor = try CompositeMediaDescriptor(
      locator: candidate.locator,
      logicalRoot: candidate.logicalRoot,
      container: candidate.container,
      kind: confirmedKind ?? detectedKind(from: context.playlists),
      confidence: .confirmed
    )
    let playlists = try context.playlists.enumerated().map { index, playlist in
      try DiscPlaylistSummary(
        identifier: playlist.name,
        durationMilliseconds: milliseconds(playlist.duration),
        sizeBytes: max(0, playlist.playFiles.last?.end ?? 0),
        isSelected: index == selectedIndex,
        segments: try playlist.playFiles.enumerated().map { segmentIndex, segment in
          try DiscPlaylistSegment(
            index: segmentIndex,
            startMilliseconds: milliseconds(segment.startTime),
            durationMilliseconds: milliseconds(segment.duration),
            sizeBytes: max(0, segment.size),
            endOffsetBytes: max(0, segment.end)
          )
        }
      )
    }
    return try DiscMediaProbeResult(
      descriptor: descriptor,
      playlists: playlists,
      audioLanguages: try languages(context.audioLanguageCodeMap),
      subtitleLanguages: try languages(context.subtitleLanguageCodeMap),
      metrics: metrics
    )
  }

  static func error(from error: any Error) -> SDKError {
    if error is CancellationError {
      return SDKError(code: .cancelled, message: "disc probe was cancelled")
    }
    if let error = error as? SDKError { return error }
    return SDKError(code: .parseFailure, message: "BDMVIOContext could not parse disc media")
  }

  private static func detectedKind(from playlists: [any MovieStream]) -> CompositeMediaKind {
    playlists.contains(where: { $0.name.lowercased().hasSuffix(".mpls") })
      ? .bluray : .dvdVideo
  }

  private static func milliseconds(_ seconds: TimeInterval) -> Int64 {
    guard seconds.isFinite, seconds > 0 else { return 0 }
    let value = seconds * 1_000
    return value >= Double(Int64.max) ? Int64.max : Int64(value.rounded())
  }

  static func elapsedMilliseconds(since startedAt: UInt64) -> Int64 {
    let elapsed = DispatchTime.now().uptimeNanoseconds &- startedAt
    return Int64(min(elapsed / 1_000_000, UInt64(Int64.max)))
  }

  private static func languages(
    _ values: [Int32: String]
  ) throws -> [DiscStreamLanguage] {
    try values.keys.sorted().map { packetIdentifier in
      try DiscStreamLanguage(
        packetIdentifier: packetIdentifier,
        languageCode: values[packetIdentifier] ?? "und"
      )
    }
  }
}

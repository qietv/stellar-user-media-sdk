internal import BDMVIOContext
import Foundation
internal import KSPlayer
import StellarCore
import StellarMediaLibrary
import StellarRemoteMedia

/// One playlist projected without exposing BDMVIOContext or KSPlayer protocol types.
public struct DiscPlaylistSummary: Codable, Equatable, Sendable {
  public let identifier: String
  public let durationMilliseconds: Int64
  public let sizeBytes: Int64
  public let isSelected: Bool

  public init(
    identifier: String,
    durationMilliseconds: Int64,
    sizeBytes: Int64,
    isSelected: Bool
  ) throws {
    guard !identifier.isEmpty, !identifier.contains("\0"), durationMilliseconds >= 0,
      sizeBytes >= 0
    else {
      throw SDKError(code: .invalidConfiguration, message: "disc playlist summary is invalid")
    }
    self.identifier = identifier
    self.durationMilliseconds = durationMilliseconds
    self.sizeBytes = sizeBytes
    self.isSelected = isSelected
  }

  private enum CodingKeys: String, CodingKey {
    case identifier
    case durationMilliseconds = "duration_ms"
    case sizeBytes = "size_bytes"
    case isSelected = "is_selected"
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

  public init(
    descriptor: CompositeMediaDescriptor,
    playlists: [DiscPlaylistSummary],
    audioLanguages: [DiscStreamLanguage],
    subtitleLanguages: [DiscStreamLanguage]
  ) throws {
    guard descriptor.confidence == .confirmed, !playlists.isEmpty,
      playlists.filter(\.isSelected).count == 1
    else {
      throw SDKError(code: .invalidConfiguration, message: "disc probe result is invalid")
    }
    self.descriptor = descriptor
    self.playlists = playlists
    self.audioLanguages = audioLanguages
    self.subtitleLanguages = subtitleLanguages
  }

  private enum CodingKeys: String, CodingKey {
    case descriptor
    case playlists
    case audioLanguages = "audio_languages"
    case subtitleLanguages = "subtitle_languages"
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
    return try BDMVProbeProjection.result(context: context, candidate: candidate)
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
    guard capabilities.supportsRangeReads, entry.locator == candidate.locator,
      candidate.container == .diskImage, candidate.confidence == .candidate,
      streamIdentifier?.isEmpty != true, streamIdentifier?.contains("\0") != true
    else {
      throw SDKError(code: .invalidConfiguration, message: "remote disc image probe is invalid")
    }
    let download = try RemoteRangeDownload(
      session: session,
      entry: entry,
      timeoutMilliseconds: readTimeoutMilliseconds
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
      throw BDMVProbeProjection.error(from: error)
    }
    defer { context.close() }
    try Task.checkCancellation()
    return try BDMVProbeProjection.result(context: context, candidate: candidate)
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
    guard capabilities.supportsRangeReads,
      candidate.container == .directory,
      candidate.kind == .bluray || candidate.kind == .avchd || candidate.kind == .dvdVideo,
      candidate.confidence == .candidate,
      streamIdentifier?.isEmpty != true,
      streamIdentifier?.contains("\0") != true
    else {
      throw SDKError(code: .invalidConfiguration, message: "remote BDMV probe is invalid")
    }
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
      throw BDMVProbeProjection.error(from: error)
    }
    defer { context.close() }
    try Task.checkCancellation()
    return try BDMVProbeProjection.result(
      context: context,
      candidate: candidate,
      confirmedKind: candidate.kind
    )
  }
}

private enum BDMVProbeProjection {
  static func result(
    context: BDMVIOContext,
    candidate: CompositeMediaDescriptor,
    confirmedKind: CompositeMediaKind? = nil
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
        isSelected: index == selectedIndex
      )
    }
    return try DiscMediaProbeResult(
      descriptor: descriptor,
      playlists: playlists,
      audioLanguages: try languages(context.audioLanguageCodeMap),
      subtitleLanguages: try languages(context.subtitleLanguageCodeMap)
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

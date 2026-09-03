import CStellarFFmpegScreenshot
import Foundation
import StellarCore
import StellarMediaLibrary
import StellarRemoteMedia

/// Libavformat-backed technical inspection over the shared seekable range-read abstraction.
///
/// The probe is deliberately opt-in. It reads only the byte ranges requested by libavformat and
/// never materializes a complete SMB or WebDAV file.
public struct FFmpegMediaTechnicalProbe: MediaTechnicalProbing {
  public static let provider = "stellar-ffmpeg"
  public static let version = 1

  public init() {}

  public func probe(
    _ request: MediaTechnicalProbeRequest,
    using session: any MediaSourceSession
  ) async throws -> MediaTechnicalProbeResult {
    guard request.locator.sourceUID == session.sourceUID else {
      throw SDKError(code: .invalidConfiguration, message: "technical probe source UID differs")
    }
    let capabilities = await session.capabilities
    guard capabilities.supportsRangeReads else {
      throw SDKError(
        code: .invalidConfiguration,
        message: "technical probe source does not support seekable range reads"
      )
    }
    let size: Int64
    if let requestedSize = request.sizeBytes, requestedSize > 0 {
      size = requestedSize
    } else {
      let entry = try await session.stat(request.locator)
      guard entry.kind == .file, let entrySize = entry.size, entrySize > 0 else {
        throw SDKError(code: .parseFailure, message: "technical probe requires a sized file")
      }
      size = entrySize
    }

    let reader = RemoteFFmpegRangeReader(
      session: session,
      locator: request.locator,
      size: size
    )
    guard let job = FFmpegTechnicalProbeJob(reader: reader) else {
      throw SDKError(code: .unknown, message: "FFmpeg probe context could not be created")
    }
    return try await job.probe(filenameHint: request.locator.path.name)
  }
}

private final class FFmpegTechnicalProbeJob: @unchecked Sendable {
  private let context: OpaquePointer
  private let reader: RemoteFFmpegRangeReader

  init?(reader: RemoteFFmpegRangeReader) {
    guard let context = stellar_ffmpeg_capture_context_create() else { return nil }
    self.context = context
    self.reader = reader
  }

  deinit {
    reader.cancel()
    stellar_ffmpeg_capture_context_destroy(context)
  }

  func cancel() {
    reader.cancel()
    stellar_ffmpeg_capture_context_cancel(context)
  }

  func probe(filenameHint: String) async throws -> MediaTechnicalProbeResult {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async { [self] in
          do {
            continuation.resume(returning: try probeSynchronously(filenameHint: filenameHint))
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    } onCancel: {
      self.cancel()
    }
  }

  private func probeSynchronously(filenameHint: String) throws -> MediaTechnicalProbeResult {
    var probe = StellarFFmpegTechnicalProbe()
    defer { stellar_ffmpeg_technical_probe_destroy(&probe) }
    let opaque = Unmanaged.passUnretained(reader).toOpaque()
    let status = filenameHint.withCString { hint in
      stellar_ffmpeg_probe_with_io(
        context,
        opaque,
        remoteFFmpegReadCallback,
        remoteFFmpegSeekCallback,
        hint,
        &probe
      )
    }
    if status == Int32(STELLAR_FFMPEG_CAPTURE_CANCELLED) {
      throw CancellationError()
    }
    guard status == Int32(STELLAR_FFMPEG_CAPTURE_OK) else {
      throw SDKError(
        code: .parseFailure,
        message: "FFmpeg could not inspect remote media (code \(status))"
      )
    }

    var streams: [MediaTechnicalStream] = []
    if let streamPointer = probe.streams, probe.stream_count > 0 {
      streams.reserveCapacity(Int(probe.stream_count))
      for offset in 0..<Int(probe.stream_count) {
        let source = streamPointer.advanced(by: offset).pointee
        guard let kind = Self.kind(source.kind) else { continue }
        streams.append(
          try MediaTechnicalStream(
            streamIndex: Int(source.stream_index),
            kind: kind,
            codec: Self.string(source.codec),
            language: Self.string(source.language) ?? "und",
            title: Self.string(source.title),
            bitrate: Self.positive(source.bit_rate),
            width: Self.positive(source.width),
            height: Self.positive(source.height),
            frameRate: Self.positive(source.frame_rate),
            hdrProfile: Self.hdrProfile(source.hdr_profile),
            channelCount: Self.positive(source.channel_count),
            channelLayout: Self.string(source.channel_layout),
            sampleRate: Self.positive(source.sample_rate),
            isDefault: source.is_default,
            isForced: source.is_forced
          )
        )
      }
    }
    let summary = try MediaTechnicalSummary(
      container: Self.string(probe.container),
      durationMilliseconds: Self.positive(probe.duration_milliseconds),
      overallBitrate: Self.positive(probe.overall_bit_rate),
      videoCodec: Self.string(probe.video_codec),
      width: Self.positive(probe.width),
      height: Self.positive(probe.height),
      frameRate: Self.positive(probe.frame_rate),
      hdrProfile: Self.hdrProfile(probe.hdr_profile),
      audioCodec: Self.string(probe.audio_codec),
      audioChannels: Self.positive(probe.audio_channels),
      hasEmbeddedCover: probe.has_embedded_cover
    )
    return try MediaTechnicalProbeResult(
      probeProvider: FFmpegMediaTechnicalProbe.provider,
      probeVersion: FFmpegMediaTechnicalProbe.version,
      summary: summary,
      streams: streams
    )
  }

  private static func string(_ value: UnsafeMutablePointer<CChar>?) -> String? {
    guard let value else { return nil }
    let decoded = String(cString: value)
    return decoded.isEmpty ? nil : decoded
  }

  private static func positive(_ value: Int64) -> Int64? { value > 0 ? value : nil }
  private static func positive(_ value: Int32) -> Int? { value > 0 ? Int(value) : nil }
  private static func positive(_ value: Double) -> Double? {
    value.isFinite && value > 0 ? value : nil
  }

  private static func kind(_ value: Int32) -> MediaTechnicalStreamKind? {
    switch value {
    case Int32(STELLAR_FFMPEG_STREAM_VIDEO): .video
    case Int32(STELLAR_FFMPEG_STREAM_AUDIO): .audio
    case Int32(STELLAR_FFMPEG_STREAM_SUBTITLE): .subtitle
    case Int32(STELLAR_FFMPEG_STREAM_ATTACHMENT): .attachment
    default: nil
    }
  }

  private static func hdrProfile(_ value: UnsafeMutablePointer<CChar>?) -> String? {
    guard let value = string(value)?.lowercased() else { return nil }
    if value.contains("smpte2084") { return "pq" }
    if value.contains("arib") || value.contains("hlg") { return "hlg" }
    return nil
  }
}

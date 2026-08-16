import Foundation
import StellarCore
import StellarRemoteMedia

/// A normalized request for technical inspection of one source file.
public struct MediaTechnicalProbeRequest: Codable, Equatable, Sendable {
  public let locator: RemoteLocator
  public let sizeBytes: Int64?
  public let modifiedAtMilliseconds: Int64?
  public let entityTag: String?

  public init(
    locator: RemoteLocator,
    sizeBytes: Int64? = nil,
    modifiedAtMilliseconds: Int64? = nil,
    entityTag: String? = nil
  ) throws {
    guard sizeBytes.map({ $0 >= 0 }) ?? true, entityTag?.contains("\0") != true else {
      throw SDKError(code: .invalidConfiguration, message: "technical probe request is invalid")
    }
    self.locator = locator
    self.sizeBytes = sizeBytes
    self.modifiedAtMilliseconds = modifiedAtMilliseconds
    self.entityTag = entityTag
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        locator: container.decode(RemoteLocator.self, forKey: .locator),
        sizeBytes: container.decodeIfPresent(Int64.self, forKey: .sizeBytes),
        modifiedAtMilliseconds: container.decodeIfPresent(
          Int64.self,
          forKey: .modifiedAtMilliseconds
        ),
        entityTag: container.decodeIfPresent(String.self, forKey: .entityTag)
      )
    } catch let error as SDKError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message)
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case locator
    case sizeBytes = "size_bytes"
    case modifiedAtMilliseconds = "modified_at_ms"
    case entityTag = "etag"
  }
}

/// The compact technical projection stored with a media file.
public struct MediaTechnicalSummary: Codable, Equatable, Sendable {
  public let container: String?
  public let durationMilliseconds: Int64?
  public let overallBitrate: Int64?
  public let videoCodec: String?
  public let width: Int?
  public let height: Int?
  public let frameRate: Double?
  public let hdrProfile: String?
  public let audioCodec: String?
  public let audioChannels: Double?
  public let hasEmbeddedCover: Bool

  public init(
    container: String? = nil,
    durationMilliseconds: Int64? = nil,
    overallBitrate: Int64? = nil,
    videoCodec: String? = nil,
    width: Int? = nil,
    height: Int? = nil,
    frameRate: Double? = nil,
    hdrProfile: String? = nil,
    audioCodec: String? = nil,
    audioChannels: Double? = nil,
    hasEmbeddedCover: Bool = false
  ) throws {
    let strings = [container, videoCodec, hdrProfile, audioCodec]
    guard strings.allSatisfy({ $0?.contains("\0") != true }),
      durationMilliseconds.map({ $0 >= 0 }) ?? true,
      overallBitrate.map({ $0 >= 0 }) ?? true,
      width.map({ $0 > 0 }) ?? true,
      height.map({ $0 > 0 }) ?? true,
      frameRate.map({ $0.isFinite && $0 > 0 }) ?? true,
      audioChannels.map({ $0.isFinite && $0 >= 0 }) ?? true
    else {
      throw SDKError(code: .parseFailure, message: "technical media summary is invalid")
    }
    self.container = container
    self.durationMilliseconds = durationMilliseconds
    self.overallBitrate = overallBitrate
    self.videoCodec = videoCodec
    self.width = width
    self.height = height
    self.frameRate = frameRate
    self.hdrProfile = hdrProfile
    self.audioCodec = audioCodec
    self.audioChannels = audioChannels
    self.hasEmbeddedCover = hasEmbeddedCover
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        container: container.decodeIfPresent(String.self, forKey: .container),
        durationMilliseconds: container.decodeIfPresent(Int64.self, forKey: .durationMilliseconds),
        overallBitrate: container.decodeIfPresent(Int64.self, forKey: .overallBitrate),
        videoCodec: container.decodeIfPresent(String.self, forKey: .videoCodec),
        width: container.decodeIfPresent(Int.self, forKey: .width),
        height: container.decodeIfPresent(Int.self, forKey: .height),
        frameRate: container.decodeIfPresent(Double.self, forKey: .frameRate),
        hdrProfile: container.decodeIfPresent(String.self, forKey: .hdrProfile),
        audioCodec: container.decodeIfPresent(String.self, forKey: .audioCodec),
        audioChannels: container.decodeIfPresent(Double.self, forKey: .audioChannels),
        hasEmbeddedCover: container.decodeIfPresent(Bool.self, forKey: .hasEmbeddedCover) ?? false
      )
    } catch let error as SDKError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message)
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case container
    case durationMilliseconds = "duration_ms"
    case overallBitrate = "overall_bitrate"
    case videoCodec = "video_codec"
    case width
    case height
    case frameRate = "frame_rate"
    case hdrProfile = "hdr_profile"
    case audioCodec = "audio_codec"
    case audioChannels = "audio_channels"
    case hasEmbeddedCover = "embedded_cover"
  }
}

/// A normalized stream category. Unknown future values remain decodable.
public enum MediaTechnicalStreamKind: String, Sendable {
  case video
  case audio
  case subtitle
  case attachment
  case unknown
}

extension MediaTechnicalStreamKind: Codable {
  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = MediaTechnicalStreamKind(rawValue: value) ?? .unknown
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// Technical information for one container stream.
public struct MediaTechnicalStream: Codable, Equatable, Sendable {
  public let streamIndex: Int
  public let kind: MediaTechnicalStreamKind
  public let codec: String?
  public let language: String
  public let title: String?
  public let bitrate: Int64?
  public let width: Int?
  public let height: Int?
  public let frameRate: Double?
  public let hdrProfile: String?
  public let channelCount: Double?
  public let channelLayout: String?
  public let sampleRate: Int?
  public let isDefault: Bool
  public let isForced: Bool

  public init(
    streamIndex: Int,
    kind: MediaTechnicalStreamKind,
    codec: String? = nil,
    language: String = "und",
    title: String? = nil,
    bitrate: Int64? = nil,
    width: Int? = nil,
    height: Int? = nil,
    frameRate: Double? = nil,
    hdrProfile: String? = nil,
    channelCount: Double? = nil,
    channelLayout: String? = nil,
    sampleRate: Int? = nil,
    isDefault: Bool = false,
    isForced: Bool = false
  ) throws {
    let strings = [codec, Optional(language), title, hdrProfile, channelLayout]
    guard streamIndex >= 0, !language.isEmpty,
      strings.allSatisfy({ $0?.contains("\0") != true }),
      bitrate.map({ $0 >= 0 }) ?? true,
      width.map({ $0 > 0 }) ?? true,
      height.map({ $0 > 0 }) ?? true,
      frameRate.map({ $0.isFinite && $0 > 0 }) ?? true,
      channelCount.map({ $0.isFinite && $0 >= 0 }) ?? true,
      sampleRate.map({ $0 > 0 }) ?? true
    else {
      throw SDKError(code: .parseFailure, message: "technical media stream is invalid")
    }
    self.streamIndex = streamIndex
    self.kind = kind
    self.codec = codec
    self.language = language
    self.title = title
    self.bitrate = bitrate
    self.width = width
    self.height = height
    self.frameRate = frameRate
    self.hdrProfile = hdrProfile
    self.channelCount = channelCount
    self.channelLayout = channelLayout
    self.sampleRate = sampleRate
    self.isDefault = isDefault
    self.isForced = isForced
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        streamIndex: container.decode(Int.self, forKey: .streamIndex),
        kind: container.decode(MediaTechnicalStreamKind.self, forKey: .kind),
        codec: container.decodeIfPresent(String.self, forKey: .codec),
        language: container.decodeIfPresent(String.self, forKey: .language) ?? "und",
        title: container.decodeIfPresent(String.self, forKey: .title),
        bitrate: container.decodeIfPresent(Int64.self, forKey: .bitrate),
        width: container.decodeIfPresent(Int.self, forKey: .width),
        height: container.decodeIfPresent(Int.self, forKey: .height),
        frameRate: container.decodeIfPresent(Double.self, forKey: .frameRate),
        hdrProfile: container.decodeIfPresent(String.self, forKey: .hdrProfile),
        channelCount: container.decodeIfPresent(Double.self, forKey: .channelCount),
        channelLayout: container.decodeIfPresent(String.self, forKey: .channelLayout),
        sampleRate: container.decodeIfPresent(Int.self, forKey: .sampleRate),
        isDefault: container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false,
        isForced: container.decodeIfPresent(Bool.self, forKey: .isForced) ?? false
      )
    } catch let error as SDKError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message)
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case streamIndex = "stream_index"
    case kind
    case codec
    case language
    case title
    case bitrate = "bit_rate"
    case width
    case height
    case frameRate = "frame_rate"
    case hdrProfile = "hdr_profile"
    case channelCount = "channel_count"
    case channelLayout = "channel_layout"
    case sampleRate = "sample_rate"
    case isDefault = "is_default"
    case isForced = "is_forced"
  }
}

/// One complete, atomically persistable technical probe result.
public struct MediaTechnicalProbeResult: Codable, Equatable, Sendable {
  public let probeProvider: String
  public let probeVersion: Int
  public let summary: MediaTechnicalSummary
  public let streams: [MediaTechnicalStream]

  public init(
    probeProvider: String,
    probeVersion: Int,
    summary: MediaTechnicalSummary,
    streams: [MediaTechnicalStream]
  ) throws {
    guard !probeProvider.isEmpty, !probeProvider.contains("\0"), probeVersion > 0,
      Set(streams.map(\.streamIndex)).count == streams.count
    else {
      throw SDKError(code: .parseFailure, message: "technical probe result is invalid")
    }
    self.probeProvider = probeProvider
    self.probeVersion = probeVersion
    self.summary = summary
    self.streams = streams.sorted { $0.streamIndex < $1.streamIndex }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        probeProvider: container.decode(String.self, forKey: .probeProvider),
        probeVersion: container.decode(Int.self, forKey: .probeVersion),
        summary: container.decode(MediaTechnicalSummary.self, forKey: .summary),
        streams: container.decode([MediaTechnicalStream].self, forKey: .streams)
      )
    } catch let error as SDKError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message)
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case probeProvider = "probe_provider"
    case probeVersion = "probe_version"
    case summary
    case streams
  }
}

/// Injectable container-inspection boundary; implementations may use bounded range reads.
public protocol MediaTechnicalProbing: Sendable {
  func probe(
    _ request: MediaTechnicalProbeRequest,
    using session: any MediaSourceSession
  ) async throws -> MediaTechnicalProbeResult
}

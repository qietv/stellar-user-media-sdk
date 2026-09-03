import Foundation
import StellarCore
import StellarRemoteMedia
import StellarStorage

/// One classified sidecar and any normalized metadata parsed from it.
public struct MediaSidecarIntake: Equatable, Sendable {
  public let descriptor: MediaSidecarDescriptor
  public let modifiedAtMilliseconds: Int64?
  public let sha256: String?
  public let metadata: LocalMetadataDocument?

  public init(
    descriptor: MediaSidecarDescriptor,
    modifiedAtMilliseconds: Int64? = nil,
    sha256: String? = nil,
    metadata: LocalMetadataDocument? = nil
  ) throws {
    let metadataKinds: Set<MediaSidecarKind> = [.nfo, .metadataJSON]
    guard metadata == nil || metadataKinds.contains(descriptor.kind) else {
      throw SDKError(code: .invalidConfiguration, message: "sidecar metadata kind is invalid")
    }
    if let sha256 {
      guard sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
        throw SDKError(code: .invalidConfiguration, message: "sidecar digest is invalid")
      }
    }
    self.descriptor = descriptor
    self.modifiedAtMilliseconds = modifiedAtMilliseconds
    self.sha256 = sha256
    self.metadata = metadata
  }
}

/// Complete local metadata ready to commit for one scanned file.
public struct MediaMetadataIntakeBatch: Sendable {
  public let sourceUID: String
  public let mediaRelativePath: String
  public let filename: MediaFilenameAnalysis
  public let sidecars: [MediaSidecarIntake]
  public let technicalProbe: MediaTechnicalProbeResult?

  public init(
    sourceUID: String,
    mediaRelativePath: String,
    filename: MediaFilenameAnalysis,
    sidecars: [MediaSidecarIntake],
    technicalProbe: MediaTechnicalProbeResult? = nil
  ) throws {
    let mediaPath = try RemotePath(mediaRelativePath)
    guard !sourceUID.isEmpty, !sourceUID.contains("\0"), !mediaPath.isRoot,
      Set(sidecars.map(\.descriptor.relativePath)).count == sidecars.count
    else {
      throw SDKError(code: .invalidConfiguration, message: "media metadata intake is invalid")
    }
    self.sourceUID = sourceUID
    self.mediaRelativePath = mediaPath.relativePath
    self.filename = filename
    self.sidecars = sidecars.sorted {
      $0.descriptor.relativePath < $1.descriptor.relativePath
    }
    self.technicalProbe = technicalProbe
  }
}

/// Persists normalized filename, sidecar, NFO/JSON, and probe data in one SQLite transaction.
public struct SQLiteMediaMetadataStore: Sendable {
  public let store: LibraryStore

  public init(store: LibraryStore) {
    self.store = store
  }

  public func persist(_ batch: MediaMetadataIntakeBatch) async throws {
    do {
      let parse = try makeParseRecord(batch.filename)
      let sidecars = try batch.sidecars.map(makeSidecarRecord)
      let probe = try batch.technicalProbe.map(makeProbeRecord)
      let persistence = try LibraryMetadataIntakeBatch(
        sourceUID: batch.sourceUID,
        mediaRelativePath: batch.mediaRelativePath,
        parseResult: parse,
        sidecars: sidecars,
        technicalProbe: probe
      )
      try await store.commitMetadataIntake(persistence)
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "metadata intake normalization failed")
    }
  }

  /// Persists one optional technical probe and completes its claimed queue item atomically.
  public func persistTechnicalProbe(
    _ result: MediaTechnicalProbeResult,
    completing lease: LibraryScanWorkLease
  ) async throws {
    do {
      try await store.commitTechnicalProbe(
        try makeProbeRecord(result),
        completing: lease
      )
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .storageFailure, message: "technical probe persistence failed")
    }
  }

  private func makeParseRecord(_ analysis: MediaFilenameAnalysis) throws
    -> LibraryFilenameParseRecord
  {
    let parsed = analysis.parsed
    guard ![.series, .season].contains(parsed.kind) else {
      throw SDKError(
        code: .invalidConfiguration,
        message: "directory parse cannot be stored as a file"
      )
    }
    let providerJSON =
      analysis.evidence.providerHints.isEmpty
      ? nil : try canonicalJSON(analysis.evidence.providerHints)
    let tokenJSON = try canonicalJSON(
      FilenameTokenPayload(
        rawTokens: analysis.evidence.rawTokens,
        noiseTokens: analysis.evidence.noiseTokens,
        sourceName: parsed.sourceName,
        isSample: parsed.isSample
      )
    )
    return try LibraryFilenameParseRecord(
      mediaKind: parsed.kind.rawValue,
      cleanTitle: parsed.title.isEmpty ? nil : parsed.title,
      hintYear: parsed.year,
      seasonNumber: parsed.season,
      episodeStart: parsed.episode,
      episodeEnd: parsed.episodeEnd,
      edition: parsed.edition,
      releaseGroup: analysis.evidence.releaseGroup,
      languageHint: analysis.evidence.languageHint,
      providerHintsJSON: providerJSON,
      rawTokensJSON: tokenJSON,
      confidence: analysis.evidence.confidence,
      parserVersion: analysis.parserVersion
    )
  }

  private func makeSidecarRecord(_ intake: MediaSidecarIntake) throws -> LibrarySidecarRecord {
    let descriptor = intake.descriptor
    let storedKind = descriptor.kind == .unknown ? MediaSidecarKind.other : descriptor.kind
    let payload: String?
    if intake.metadata != nil || descriptor.isHearingImpaired {
      payload = try canonicalJSON(
        SidecarParsedPayload(
          isHearingImpaired: descriptor.isHearingImpaired,
          metadata: intake.metadata
        )
      )
    } else {
      payload = nil
    }
    return try LibrarySidecarRecord(
      kind: storedKind.rawValue,
      relativePath: descriptor.relativePath,
      language: descriptor.language,
      isForced: descriptor.isForced,
      modifiedAtMilliseconds: intake.modifiedAtMilliseconds,
      sha256: intake.sha256,
      parsedJSON: payload
    )
  }

  private func makeProbeRecord(_ result: MediaTechnicalProbeResult) throws
    -> LibraryTechnicalProbeRecord
  {
    let summary = LibraryTechnicalSummaryRecord(
      container: result.summary.container,
      durationMilliseconds: result.summary.durationMilliseconds,
      overallBitrate: result.summary.overallBitrate,
      videoCodec: result.summary.videoCodec,
      width: result.summary.width,
      height: result.summary.height,
      frameRate: result.summary.frameRate,
      hdrProfile: result.summary.hdrProfile,
      audioCodec: result.summary.audioCodec,
      audioChannels: result.summary.audioChannels,
      hasEmbeddedCover: result.summary.hasEmbeddedCover
    )
    let streams = try result.streams.map { stream in
      guard stream.kind != .unknown else {
        throw SDKError(code: .invalidConfiguration, message: "unknown stream kind cannot be stored")
      }
      return try LibraryTechnicalStreamRecord(
        streamIndex: stream.streamIndex,
        kind: stream.kind.rawValue,
        codec: stream.codec,
        language: stream.language,
        title: stream.title,
        bitrate: stream.bitrate,
        width: stream.width,
        height: stream.height,
        frameRate: stream.frameRate,
        hdrProfile: stream.hdrProfile,
        channelCount: stream.channelCount,
        channelLayout: stream.channelLayout,
        sampleRate: stream.sampleRate,
        isDefault: stream.isDefault,
        isForced: stream.isForced
      )
    }
    return try LibraryTechnicalProbeRecord(
      summary: summary,
      streams: streams,
      probeProvider: result.probeProvider,
      probeVersion: result.probeVersion
    )
  }

  private func canonicalJSON<Value: Encodable>(_ value: Value) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }
}

private struct FilenameTokenPayload: Encodable {
  let schemaVersion = 1
  let rawTokens: [String]
  let noiseTokens: [String]
  let sourceName: String
  let isSample: Bool

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case rawTokens = "raw_tokens"
    case noiseTokens = "noise_tokens"
    case sourceName = "source_name"
    case isSample = "is_sample"
  }
}

private struct SidecarParsedPayload: Encodable {
  let schemaVersion = 1
  let isHearingImpaired: Bool
  let metadata: LocalMetadataDocument?

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case isHearingImpaired = "hearing_impaired"
    case metadata
  }
}

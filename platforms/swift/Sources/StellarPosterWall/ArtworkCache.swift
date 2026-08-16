import Foundation
import StellarCore

/// One stable artwork variant requested by a PosterWall consumer.
public struct PosterWallArtworkVariantRequest: Codable, Equatable, Sendable {
  public let artworkUID: String
  public let provider: String
  public let remoteReference: String
  public let targetPixelWidth: Int
  public let targetPixelHeight: Int
  public let transformVersion: Int

  public init(
    artworkUID: String,
    provider: String,
    remoteReference: String,
    targetPixelWidth: Int,
    targetPixelHeight: Int,
    transformVersion: Int = 1
  ) throws {
    let components = URLComponents(string: remoteReference)
    let hasTransientURLData =
      components?.user != nil || components?.password != nil
      || components?.query != nil || components?.fragment != nil
    guard !artworkUID.isEmpty, !artworkUID.contains("\0"),
      !provider.isEmpty, !provider.contains("\0"),
      !remoteReference.isEmpty, !remoteReference.contains("\0"), !hasTransientURLData,
      (1...16_384).contains(targetPixelWidth), (1...16_384).contains(targetPixelHeight),
      transformVersion > 0
    else {
      throw SDKError(code: .invalidConfiguration, message: "artwork variant request is invalid")
    }
    self.artworkUID = artworkUID
    self.provider = provider
    self.remoteReference = remoteReference
    self.targetPixelWidth = targetPixelWidth
    self.targetPixelHeight = targetPixelHeight
    self.transformVersion = transformVersion
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        artworkUID: container.decode(String.self, forKey: .artworkUID),
        provider: container.decode(String.self, forKey: .provider),
        remoteReference: container.decode(String.self, forKey: .remoteReference),
        targetPixelWidth: container.decode(Int.self, forKey: .targetPixelWidth),
        targetPixelHeight: container.decode(Int.self, forKey: .targetPixelHeight),
        transformVersion: container.decodeIfPresent(Int.self, forKey: .transformVersion) ?? 1
      )
    } catch let error as SDKError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message)
      )
    }
  }

  /// A deterministic identity that includes provider, reference, target size, and transform.
  public var cacheIdentity: String {
    "v1|a\(artworkUID.utf8.count):\(artworkUID)"
      + "|p\(provider.utf8.count):\(provider)"
      + "|r\(remoteReference.utf8.count):\(remoteReference)"
      + "|w\(targetPixelWidth)|h\(targetPixelHeight)|t\(transformVersion)"
  }

  private enum CodingKeys: String, CodingKey {
    case artworkUID = "artwork_uid"
    case provider
    case remoteReference = "remote_reference"
    case targetPixelWidth = "target_pixel_width"
    case targetPixelHeight = "target_pixel_height"
    case transformVersion = "transform_version"
  }
}

/// One regenerable local artwork-cache entry.
public struct PosterWallArtworkCacheRecord: Codable, Equatable, Sendable {
  public let request: PosterWallArtworkVariantRequest
  public let localRelativePath: String
  public let byteCount: Int64
  public let lastAccessedAtMilliseconds: Int64

  public init(
    request: PosterWallArtworkVariantRequest,
    localRelativePath: String,
    byteCount: Int64,
    lastAccessedAtMilliseconds: Int64
  ) throws {
    let path = localRelativePath.replacingOccurrences(of: "\\", with: "/")
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
      !components.contains(".."), !components.contains("."),
      !components.contains(where: { $0.isEmpty }), byteCount >= 0,
      lastAccessedAtMilliseconds >= 0
    else {
      throw SDKError(code: .invalidConfiguration, message: "artwork cache record is invalid")
    }
    self.request = request
    self.localRelativePath = path
    self.byteCount = byteCount
    self.lastAccessedAtMilliseconds = lastAccessedAtMilliseconds
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        request: container.decode(PosterWallArtworkVariantRequest.self, forKey: .request),
        localRelativePath: container.decode(String.self, forKey: .localRelativePath),
        byteCount: container.decode(Int64.self, forKey: .byteCount),
        lastAccessedAtMilliseconds: container.decode(
          Int64.self,
          forKey: .lastAccessedAtMilliseconds
        )
      )
    } catch let error as SDKError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message)
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case request
    case localRelativePath = "local_relative_path"
    case byteCount = "byte_count"
    case lastAccessedAtMilliseconds = "last_accessed_at_ms"
  }
}

/// Replaceable index boundary for regenerable artwork variants.
public protocol PosterWallArtworkCacheIndexing: Sendable {
  func record(for request: PosterWallArtworkVariantRequest) async throws
    -> PosterWallArtworkCacheRecord?
  func store(_ record: PosterWallArtworkCacheRecord) async throws
  func remove(_ request: PosterWallArtworkVariantRequest) async throws
}

/// A deterministic in-memory artwork index for tests and ephemeral hosts.
public actor InMemoryPosterWallArtworkCacheIndex: PosterWallArtworkCacheIndexing {
  private var records: [String: PosterWallArtworkCacheRecord] = [:]

  public init() {}

  public func record(for request: PosterWallArtworkVariantRequest) async throws
    -> PosterWallArtworkCacheRecord?
  {
    records[request.cacheIdentity]
  }

  public func store(_ record: PosterWallArtworkCacheRecord) async throws {
    records[record.request.cacheIdentity] = record
  }

  public func remove(_ request: PosterWallArtworkVariantRequest) async throws {
    records.removeValue(forKey: request.cacheIdentity)
  }
}

/// Replaceable prefetch boundary that lets platform hosts enforce network and power policy.
public protocol PosterWallArtworkPrefetching: Sendable {
  func prefetch(_ requests: [PosterWallArtworkVariantRequest]) async throws
}

/// A prefetcher that intentionally performs no network or filesystem work.
public struct NoopPosterWallArtworkPrefetcher: PosterWallArtworkPrefetching {
  public init() {}

  public func prefetch(_: [PosterWallArtworkVariantRequest]) async throws {}
}

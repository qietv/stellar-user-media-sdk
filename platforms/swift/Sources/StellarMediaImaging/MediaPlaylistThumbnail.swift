import CoreGraphics
import Foundation
import ImageIO
import StellarCore
import StellarRemoteMedia

/// One remote media item that can contribute a frame to a playlist thumbnail.
public struct MediaPlaylistThumbnailItem: Equatable, Sendable {
  public let locator: RemoteLocator
  public let timestampMilliseconds: Int64

  public init(locator: RemoteLocator, timestampMilliseconds: Int64 = 0) throws {
    guard timestampMilliseconds >= 0 else {
      throw SDKError(
        code: .invalidConfiguration,
        message: "playlist thumbnail timestamp is invalid"
      )
    }
    self.locator = locator
    self.timestampMilliseconds = timestampMilliseconds
  }
}

/// Validated output and work limits for a playlist thumbnail.
public struct MediaPlaylistThumbnailRequest: Equatable, Sendable {
  public let width: Int
  public let height: Int
  public let format: MediaScreenshotImageFormat
  public let jpegQuality: Double
  public let maximumItems: Int
  public let maximumConcurrentCaptures: Int

  public init(
    width: Int = 640,
    height: Int = 360,
    format: MediaScreenshotImageFormat = .jpeg,
    jpegQuality: Double = 0.9,
    maximumItems: Int = 4,
    maximumConcurrentCaptures: Int = 2
  ) throws {
    guard (16...16_384).contains(width), (16...16_384).contains(height),
      jpegQuality.isFinite, (0...1).contains(jpegQuality),
      (1...4).contains(maximumItems),
      (1...2).contains(maximumConcurrentCaptures)
    else {
      throw SDKError(code: .invalidConfiguration, message: "playlist thumbnail request is invalid")
    }
    self.width = width
    self.height = height
    self.format = format
    self.jpegQuality = jpegQuality
    self.maximumItems = maximumItems
    self.maximumConcurrentCaptures = maximumConcurrentCaptures
  }
}

/// Playlist-thumbnail boundary shared by generated remote frames and cached screenshot inputs.
public protocol MediaPlaylistThumbnailGenerating: Sendable {
  func capture(
    _ items: [MediaPlaylistThumbnailItem],
    using sessions: [String: any MediaSourceSession],
    request: MediaPlaylistThumbnailRequest
  ) async throws -> MediaScreenshotResult

  func compose(
    _ frames: [MediaScreenshotResult],
    request: MediaPlaylistThumbnailRequest
  ) throws -> MediaScreenshotResult
}

/// Generates a deterministic one-to-four-frame visual asset for a playlist.
///
/// Remote frames are decoded by ``FFmpegMediaScreenshotGenerator``. Consequently every input
/// keeps the source credentials outside FFmpeg and is read through seekable range requests.
public struct FFmpegMediaPlaylistThumbnailGenerator: MediaPlaylistThumbnailGenerating {
  private let screenshotGenerator = FFmpegMediaScreenshotGenerator()

  public init() {}

  /// Captures the selected playlist items and composes them in playlist order.
  public func capture(
    _ items: [MediaPlaylistThumbnailItem],
    using sessions: [String: any MediaSourceSession],
    request: MediaPlaylistThumbnailRequest
  ) async throws -> MediaScreenshotResult {
    let selectedItems = Array(items.prefix(request.maximumItems))
    guard !selectedItems.isEmpty else {
      throw SDKError(code: .metadataNotFound, message: "playlist has no thumbnail inputs")
    }
    for item in selectedItems where sessions[item.locator.sourceUID] == nil {
      throw SDKError(
        code: .invalidConfiguration,
        message: "playlist thumbnail source session is missing"
      )
    }

    let maximumDimension = max(request.width, request.height)
    var frames = [MediaScreenshotResult?](repeating: nil, count: selectedItems.count)
    var iterator = Array(selectedItems.enumerated()).makeIterator()
    try await withThrowingTaskGroup(of: IndexedPlaylistFrame.self) { group in
      for _ in 0..<min(request.maximumConcurrentCaptures, selectedItems.count) {
        guard let (index, item) = iterator.next(),
          let session = sessions[item.locator.sourceUID]
        else { break }
        group.addTask {
          let frame = try await screenshotGenerator.capture(
            item.locator,
            using: session,
            request: MediaScreenshotRequest(
              timestampMilliseconds: item.timestampMilliseconds,
              format: .png,
              maximumPixelDimension: maximumDimension
            )
          )
          return IndexedPlaylistFrame(index: index, frame: frame)
        }
      }

      while let completed = try await group.next() {
        frames[completed.index] = completed.frame
        if let (index, item) = iterator.next(),
          let session = sessions[item.locator.sourceUID]
        {
          group.addTask {
            let frame = try await screenshotGenerator.capture(
              item.locator,
              using: session,
              request: MediaScreenshotRequest(
                timestampMilliseconds: item.timestampMilliseconds,
                format: .png,
                maximumPixelDimension: maximumDimension
              )
            )
            return IndexedPlaylistFrame(index: index, frame: frame)
          }
        }
      }
    }
    return try compose(frames.compactMap(\.self), request: request)
  }

  /// Composes already-cached screenshots without reading the source media again.
  public func compose(
    _ frames: [MediaScreenshotResult],
    request: MediaPlaylistThumbnailRequest
  ) throws -> MediaScreenshotResult {
    let selectedFrames = Array(frames.prefix(request.maximumItems))
    guard !selectedFrames.isEmpty else {
      throw SDKError(code: .metadataNotFound, message: "playlist has no thumbnail frames")
    }
    let images = try selectedFrames.map { frame -> CGImage in
      guard let source = CGImageSourceCreateWithData(frame.data as CFData, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else {
        throw SDKError(code: .parseFailure, message: "playlist thumbnail frame is invalid")
      }
      return image
    }
    guard
      let context = CGContext(
        data: nil,
        width: request.width,
        height: request.height,
        bitsPerComponent: 8,
        bytesPerRow: request.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      throw SDKError(code: .parseFailure, message: "playlist thumbnail canvas is unavailable")
    }
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: request.width, height: request.height))

    for (image, rectangle) in zip(images, layout(count: images.count, request: request)) {
      drawAspectFill(image, in: rectangle, context: context)
    }
    guard let image = context.makeImage() else {
      throw SDKError(code: .parseFailure, message: "playlist thumbnail composition failed")
    }
    let data = try encode(image, request: request)
    return try MediaScreenshotResult(
      data: data,
      format: request.format,
      width: request.width,
      height: request.height
    )
  }

  private func layout(
    count: Int,
    request: MediaPlaylistThumbnailRequest
  ) -> [CGRect] {
    let width = CGFloat(request.width)
    let height = CGFloat(request.height)
    switch count {
    case 1:
      return [CGRect(x: 0, y: 0, width: width, height: height)]
    case 2:
      let split = floor(width / 2)
      return [
        CGRect(x: 0, y: 0, width: split, height: height),
        CGRect(x: split, y: 0, width: width - split, height: height),
      ]
    case 3:
      let splitX = floor(width / 2)
      let splitY = floor(height / 2)
      return [
        CGRect(x: 0, y: 0, width: splitX, height: height),
        CGRect(x: splitX, y: splitY, width: width - splitX, height: height - splitY),
        CGRect(x: splitX, y: 0, width: width - splitX, height: splitY),
      ]
    default:
      let splitX = floor(width / 2)
      let splitY = floor(height / 2)
      return [
        CGRect(x: 0, y: splitY, width: splitX, height: height - splitY),
        CGRect(x: splitX, y: splitY, width: width - splitX, height: height - splitY),
        CGRect(x: 0, y: 0, width: splitX, height: splitY),
        CGRect(x: splitX, y: 0, width: width - splitX, height: splitY),
      ]
    }
  }

  private func drawAspectFill(_ image: CGImage, in rectangle: CGRect, context: CGContext) {
    let scale = max(
      rectangle.width / CGFloat(image.width),
      rectangle.height / CGFloat(image.height)
    )
    let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    let destination = CGRect(
      x: rectangle.midX - size.width / 2,
      y: rectangle.midY - size.height / 2,
      width: size.width,
      height: size.height
    )
    context.saveGState()
    context.clip(to: rectangle)
    context.interpolationQuality = .high
    context.draw(image, in: destination)
    context.restoreGState()
  }

  private func encode(
    _ image: CGImage,
    request: MediaPlaylistThumbnailRequest
  ) throws -> Data {
    let output = NSMutableData()
    let typeIdentifier: CFString =
      request.format == .png ? "public.png" as CFString : "public.jpeg" as CFString
    guard let destination = CGImageDestinationCreateWithData(output, typeIdentifier, 1, nil) else {
      throw SDKError(code: .parseFailure, message: "playlist thumbnail encoder is unavailable")
    }
    let properties: CFDictionary?
    switch request.format {
    case .jpeg:
      properties = [kCGImageDestinationLossyCompressionQuality: request.jpegQuality] as CFDictionary
    case .png:
      properties = nil
    }
    CGImageDestinationAddImage(destination, image, properties)
    guard CGImageDestinationFinalize(destination), output.length > 0 else {
      throw SDKError(code: .parseFailure, message: "playlist thumbnail encoding failed")
    }
    return output as Data
  }
}

private struct IndexedPlaylistFrame: Sendable {
  let index: Int
  let frame: MediaScreenshotResult
}

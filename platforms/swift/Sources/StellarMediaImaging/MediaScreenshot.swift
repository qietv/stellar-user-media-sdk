import CStellarFFmpegScreenshot
import CoreGraphics
import Foundation
import ImageIO
import StellarCore
import StellarRemoteMedia

/// Encoded image format returned by a media screenshot request.
public enum MediaScreenshotImageFormat: String, Codable, CaseIterable, Sendable {
  case jpeg
  case png

  public var mimeType: String {
    switch self {
    case .jpeg: "image/jpeg"
    case .png: "image/png"
    }
  }
}

/// Validated options for decoding one video frame into an image.
public struct MediaScreenshotRequest: Equatable, Sendable {
  public let timestampMilliseconds: Int64
  public let format: MediaScreenshotImageFormat
  public let maximumPixelDimension: Int?
  public let jpegQuality: Double

  public init(
    timestampMilliseconds: Int64,
    format: MediaScreenshotImageFormat = .jpeg,
    maximumPixelDimension: Int? = nil,
    jpegQuality: Double = 0.9
  ) throws {
    guard timestampMilliseconds >= 0,
      maximumPixelDimension.map({ (16...16_384).contains($0) }) ?? true,
      jpegQuality.isFinite,
      (0...1).contains(jpegQuality)
    else {
      throw SDKError(code: .invalidConfiguration, message: "screenshot request is invalid")
    }
    self.timestampMilliseconds = timestampMilliseconds
    self.format = format
    self.maximumPixelDimension = maximumPixelDimension
    self.jpegQuality = jpegQuality
  }
}

/// One encoded screenshot and its decoded pixel dimensions.
public struct MediaScreenshotResult: Equatable, Sendable {
  public let data: Data
  public let format: MediaScreenshotImageFormat
  public let width: Int
  public let height: Int

  public init(
    data: Data,
    format: MediaScreenshotImageFormat,
    width: Int,
    height: Int
  ) throws {
    guard !data.isEmpty, width > 0, height > 0 else {
      throw SDKError(code: .parseFailure, message: "screenshot result is invalid")
    }
    self.data = data
    self.format = format
    self.width = width
    self.height = height
  }

  public var mimeType: String { format.mimeType }
}

/// Screenshot boundary shared by local files and connected media-source sessions.
public protocol MediaScreenshotGenerating: Sendable {
  func capture(
    fileAt sourceURL: URL,
    request: MediaScreenshotRequest
  ) async throws -> MediaScreenshotResult

  func capture(
    _ locator: RemoteLocator,
    using session: any MediaSourceSession,
    request: MediaScreenshotRequest
  ) async throws -> MediaScreenshotResult
}

/// FFmpegKit-backed screenshot generator.
///
/// Remote sources are materialized in bounded chunks for the initial implementation.
/// This keeps SMB/WebDAV credentials and URLs outside FFmpeg while preserving a future
/// migration path to custom AVIO without changing the public API.
public struct FFmpegMediaScreenshotGenerator: MediaScreenshotGenerating {
  private static let remoteReadChunkSize = 4 * 1_024 * 1_024
  private static let maximumRemoteFileSize: Int64 = 128 * 1_024 * 1_024 * 1_024

  public init() {}

  public func capture(
    fileAt sourceURL: URL,
    request: MediaScreenshotRequest
  ) async throws -> MediaScreenshotResult {
    try checkCancellation()
    guard sourceURL.isFileURL, !sourceURL.path.isEmpty else {
      throw SDKError(
        code: .invalidConfiguration,
        message: "screenshot input must be a local file URL"
      )
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else {
      throw SDKError(code: .metadataNotFound, message: "screenshot input file was not found")
    }

    let decodedFrame: FFmpegDecodedFrame
    do {
      decodedFrame = try await FFmpegFrameDecoder.decode(
        filePath: sourceURL.path,
        timestampMilliseconds: request.timestampMilliseconds,
        maximumPixelDimension: request.maximumPixelDimension
      )
    } catch is CancellationError {
      throw SDKError(code: .cancelled, message: "screenshot generation cancelled")
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .unknown, message: "screenshot execution failed")
    }
    try checkCancellation()
    let data = try encode(decodedFrame, request: request)
    try checkCancellation()
    return try MediaScreenshotResult(
      data: data,
      format: request.format,
      width: decodedFrame.width,
      height: decodedFrame.height
    )
  }

  public func capture(
    _ locator: RemoteLocator,
    using session: any MediaSourceSession,
    request: MediaScreenshotRequest
  ) async throws -> MediaScreenshotResult {
    guard locator.sourceUID == session.sourceUID else {
      throw SDKError(code: .invalidConfiguration, message: "screenshot source UID does not match")
    }
    let entry = try await session.stat(locator)
    guard entry.kind == .file, let size = entry.size, size > 0 else {
      throw SDKError(code: .parseFailure, message: "screenshot source is not a sized media file")
    }
    guard size <= Self.maximumRemoteFileSize else {
      throw SDKError(
        code: .invalidConfiguration, message: "remote media file is too large to stage")
    }

    let stagedURL = temporaryURL(fileExtension: safePathExtension(locator.path.relativePath))
    guard FileManager.default.createFile(atPath: stagedURL.path, contents: nil) else {
      throw SDKError(
        code: .storageFailure, message: "remote media staging file could not be created")
    }
    defer { try? FileManager.default.removeItem(at: stagedURL) }

    let handle: FileHandle
    do {
      handle = try FileHandle(forWritingTo: stagedURL)
    } catch {
      throw SDKError(
        code: .storageFailure, message: "remote media staging file could not be opened")
    }
    defer { try? handle.close() }

    var offset: Int64 = 0
    while offset < size {
      try checkCancellation()
      let length = Int(min(Int64(Self.remoteReadChunkSize), size - offset))
      let data = try await session.read(
        at: locator,
        range: RemoteByteRange(offset: offset, length: length)
      )
      guard !data.isEmpty, data.count <= length else {
        throw SDKError(code: .parseFailure, message: "remote media read returned invalid data")
      }
      do {
        try handle.write(contentsOf: data)
      } catch {
        throw SDKError(code: .storageFailure, message: "remote media staging write failed")
      }
      offset += Int64(data.count)
    }
    do {
      try handle.synchronize()
      try handle.close()
    } catch {
      throw SDKError(code: .storageFailure, message: "remote media staging flush failed")
    }
    return try await capture(fileAt: stagedURL, request: request)
  }

  private func encode(
    _ frame: FFmpegDecodedFrame,
    request: MediaScreenshotRequest
  ) throws -> Data {
    guard let provider = CGDataProvider(data: frame.data as CFData),
      let image = CGImage(
        width: frame.width,
        height: frame.height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: frame.bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Little.union(
          CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
        ),
        provider: provider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
      )
    else {
      throw SDKError(code: .parseFailure, message: "decoded screenshot pixels are invalid")
    }

    let output = NSMutableData()
    let typeIdentifier: CFString =
      request.format == .png ? "public.png" as CFString : "public.jpeg" as CFString
    guard let destination = CGImageDestinationCreateWithData(output, typeIdentifier, 1, nil) else {
      throw SDKError(code: .parseFailure, message: "screenshot image encoder is unavailable")
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
      throw SDKError(code: .parseFailure, message: "screenshot image encoding failed")
    }
    return output as Data
  }

  private func safePathExtension(_ path: String) -> String {
    let pathExtension = (path as NSString).pathExtension.lowercased()
    guard (1...16).contains(pathExtension.count),
      pathExtension.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) })
    else {
      return "media"
    }
    return pathExtension
  }

  private func temporaryURL(fileExtension: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("stellar-screenshot-\(UUID().uuidString)")
      .appendingPathExtension(fileExtension)
  }

  private func checkCancellation() throws {
    guard !Task.isCancelled else {
      throw SDKError(code: .cancelled, message: "screenshot generation cancelled")
    }
  }
}

private struct FFmpegDecodedFrame: Sendable {
  let data: Data
  let width: Int
  let height: Int
  let bytesPerRow: Int
}

private enum FFmpegFrameDecoder {
  static func decode(
    filePath: String,
    timestampMilliseconds: Int64,
    maximumPixelDimension: Int?
  ) async throws -> FFmpegDecodedFrame {
    guard let job = FFmpegFrameDecodeJob() else {
      throw SDKError(code: .unknown, message: "FFmpeg capture context could not be created")
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            continuation.resume(
              returning: try job.decode(
                filePath: filePath,
                timestampMilliseconds: timestampMilliseconds,
                maximumPixelDimension: maximumPixelDimension
              ))
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    } onCancel: {
      job.cancel()
    }
  }
}

private final class FFmpegFrameDecodeJob: @unchecked Sendable {
  private let context: OpaquePointer

  init?() {
    guard let context = stellar_ffmpeg_capture_context_create() else { return nil }
    self.context = context
  }

  deinit {
    stellar_ffmpeg_capture_context_destroy(context)
  }

  func cancel() {
    stellar_ffmpeg_capture_context_cancel(context)
  }

  func decode(
    filePath: String,
    timestampMilliseconds: Int64,
    maximumPixelDimension: Int?
  ) throws -> FFmpegDecodedFrame {
    var frame = StellarFFmpegDecodedFrame()
    defer { stellar_ffmpeg_decoded_frame_destroy(&frame) }
    let status = filePath.withCString { path in
      stellar_ffmpeg_capture_frame(
        context,
        path,
        timestampMilliseconds,
        Int32(maximumPixelDimension ?? 0),
        &frame
      )
    }
    if status == Int32(STELLAR_FFMPEG_CAPTURE_CANCELLED) {
      throw CancellationError()
    }
    guard status == Int32(STELLAR_FFMPEG_CAPTURE_OK),
      let bytes = frame.bytes,
      frame.byte_count > 0,
      frame.width > 0,
      frame.height > 0,
      frame.bytes_per_row > 0
    else {
      let message: String
      switch status {
      case Int32(STELLAR_FFMPEG_CAPTURE_NO_VIDEO):
        message = "media does not contain a decodable video stream"
      case Int32(STELLAR_FFMPEG_CAPTURE_NO_FRAME):
        message = "media does not contain a frame at the requested timestamp"
      default:
        message = "FFmpeg could not decode a screenshot (code \(status))"
      }
      throw SDKError(code: .parseFailure, message: message)
    }
    return FFmpegDecodedFrame(
      data: Data(bytes: bytes, count: frame.byte_count),
      width: Int(frame.width),
      height: Int(frame.height),
      bytesPerRow: Int(frame.bytes_per_row)
    )
  }
}

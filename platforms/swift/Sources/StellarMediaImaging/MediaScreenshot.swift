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
/// Remote sources use source-independent range reads through a seekable custom AVIO bridge.
/// SMB/WebDAV credentials and URLs stay outside FFmpeg, and a screenshot never stages the
/// complete remote media file.
public struct FFmpegMediaScreenshotGenerator: MediaScreenshotGenerating {
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
    let capabilities = await session.capabilities
    guard capabilities.supportsRangeReads else {
      throw SDKError(
        code: .invalidConfiguration,
        message: "screenshot source does not support seekable range reads"
      )
    }
    let entry = try await session.stat(locator)
    guard entry.kind == .file, let size = entry.size, size > 0 else {
      throw SDKError(code: .parseFailure, message: "screenshot source is not a sized media file")
    }
    let reader = RemoteFFmpegRangeReader(session: session, locator: locator, size: size)
    guard let job = FFmpegRemoteFrameDecodeJob(reader: reader) else {
      throw SDKError(code: .unknown, message: "FFmpeg capture context could not be created")
    }
    let decodedFrame: FFmpegDecodedFrame
    do {
      decodedFrame = try await job.decode(
        filenameHint: locator.path.name,
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
    return try MediaScreenshotResult(
      data: data,
      format: request.format,
      width: decodedFrame.width,
      height: decodedFrame.height
    )
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

  private func checkCancellation() throws {
    guard !Task.isCancelled else {
      throw SDKError(code: .cancelled, message: "screenshot generation cancelled")
    }
  }
}

final class RemoteFFmpegRangeReader: @unchecked Sendable {
  private static let avSeekSize: Int32 = 0x10000
  private static let avSeekForce: Int32 = 0x20000
  private static let cacheBlockSize = 256 * 1_024
  private static let maximumCachedBlocks = 8
  private static let readTimeoutSeconds = 30

  private let session: any MediaSourceSession
  private let locator: RemoteLocator
  private let size: Int64
  private let operationLock = NSLock()
  private let stateLock = NSLock()
  private var position: Int64 = 0
  private var cancelled = false
  private var cachedBlocks: [Int64: Data] = [:]
  private var cachedBlockOrder: [Int64] = []

  init(session: any MediaSourceSession, locator: RemoteLocator, size: Int64) {
    self.session = session
    self.locator = locator
    self.size = size
  }

  func read(into buffer: UnsafeMutablePointer<UInt8>?, capacity: Int32) -> Int32 {
    guard capacity > 0, let buffer else { return capacity == 0 ? 0 : -1 }
    operationLock.lock()
    defer { operationLock.unlock() }
    guard !isCancelled else { return -1 }
    guard position < size else { return 0 }

    let requestedLength = Int(min(Int64(capacity), size - position))
    let offset = position
    guard case .success(let data) = cachedRead(offset: offset, length: requestedLength) else {
      return -1
    }
    guard !isCancelled else { return -1 }
    let count = min(requestedLength, data.count)
    data.withUnsafeBytes { bytes in
      guard let source = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
      buffer.update(from: source, count: count)
    }
    position = offset + Int64(count)
    return Int32(count)
  }

  func seek(offset: Int64, whence rawWhence: Int32) -> Int64 {
    operationLock.lock()
    defer { operationLock.unlock() }
    guard !isCancelled else { return -1 }
    let whence = rawWhence & ~Self.avSeekForce
    if whence == Self.avSeekSize { return size }
    let target: Int64
    switch whence {
    case SEEK_SET:
      target = offset
    case SEEK_CUR:
      let (value, overflow) = position.addingReportingOverflow(offset)
      guard !overflow else { return -1 }
      target = value
    case SEEK_END:
      let (value, overflow) = size.addingReportingOverflow(offset)
      guard !overflow else { return -1 }
      target = value
    default:
      return -1
    }
    guard (0...size).contains(target) else { return -1 }
    position = target
    return target
  }

  func cancel() {
    stateLock.lock()
    cancelled = true
    stateLock.unlock()
  }

  private var isCancelled: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return cancelled
  }

  private func cachedRead(offset: Int64, length: Int) -> Result<Data, any Error> {
    var result = Data()
    result.reserveCapacity(length)
    while result.count < length {
      let nextOffset = offset + Int64(result.count)
      let blockSize = Int64(Self.cacheBlockSize)
      let blockOffset = (nextOffset / blockSize) * blockSize
      let block: Data
      if let cached = cachedBlocks[blockOffset] {
        block = cached
        touchCachedBlock(at: blockOffset)
      } else {
        let fetchLength = Int(min(blockSize, size - blockOffset))
        switch blockingRemoteRead(offset: blockOffset, length: fetchLength) {
        case .success(let fetched):
          block = fetched
          cache(fetched, at: blockOffset)
        case .failure(let error):
          return .failure(error)
        }
      }

      let blockIndex = Int(nextOffset - blockOffset)
      guard blockIndex < block.count else { break }
      let accepted = min(length - result.count, block.count - blockIndex)
      result.append(block[blockIndex..<(blockIndex + accepted)])
      guard accepted > 0 else { break }
    }
    return .success(result)
  }

  private func cache(_ data: Data, at offset: Int64) {
    cachedBlocks[offset] = data
    touchCachedBlock(at: offset)
    while cachedBlockOrder.count > Self.maximumCachedBlocks {
      let evicted = cachedBlockOrder.removeFirst()
      cachedBlocks.removeValue(forKey: evicted)
    }
  }

  private func touchCachedBlock(at offset: Int64) {
    cachedBlockOrder.removeAll { $0 == offset }
    cachedBlockOrder.append(offset)
  }

  private func blockingRemoteRead(offset: Int64, length: Int) -> Result<Data, any Error> {
    let semaphore = DispatchSemaphore(value: 0)
    let resultBox = RemoteScreenshotReadResultBox()
    let task = Task.detached(priority: .utility) { [session, locator] in
      do {
        var result = Data()
        result.reserveCapacity(length)
        var nextOffset = offset
        while result.count < length {
          try Task.checkCancellation()
          let remaining = length - result.count
          let chunk = try await session.read(
            at: locator,
            range: RemoteByteRange(offset: nextOffset, length: remaining)
          )
          guard !chunk.isEmpty else { break }
          let accepted = min(remaining, chunk.count)
          result.append(chunk.prefix(accepted))
          nextOffset += Int64(accepted)
        }
        resultBox.store(.success(result))
      } catch {
        resultBox.store(.failure(error))
      }
      semaphore.signal()
    }
    let deadline = DispatchTime.now() + .seconds(Self.readTimeoutSeconds)
    while semaphore.wait(timeout: .now() + .milliseconds(25)) == .timedOut {
      if isCancelled {
        task.cancel()
        return .failure(SDKError(code: .cancelled, message: "remote screenshot read cancelled"))
      }
      if DispatchTime.now() >= deadline {
        task.cancel()
        return .failure(
          SDKError(code: .remoteUnavailable, message: "remote screenshot read timed out"))
      }
    }
    return resultBox.take()
      ?? .failure(SDKError(code: .remoteUnavailable, message: "remote screenshot read failed"))
  }
}

private final class RemoteScreenshotReadResultBox: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<Data, any Error>?

  func store(_ result: Result<Data, any Error>) {
    lock.lock()
    self.result = result
    lock.unlock()
  }

  func take() -> Result<Data, any Error>? {
    lock.lock()
    defer { lock.unlock() }
    return result
  }
}

let remoteFFmpegReadCallback:
  @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?, Int32) -> Int32 =
    { opaque, buffer, capacity in
      guard let opaque else { return -1 }
      return Unmanaged<RemoteFFmpegRangeReader>.fromOpaque(opaque).takeUnretainedValue()
        .read(into: buffer, capacity: capacity)
    }

let remoteFFmpegSeekCallback: @convention(c) (UnsafeMutableRawPointer?, Int64, Int32) -> Int64 =
  { opaque, offset, whence in
    guard let opaque else { return -1 }
    return Unmanaged<RemoteFFmpegRangeReader>.fromOpaque(opaque).takeUnretainedValue()
      .seek(offset: offset, whence: whence)
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

private final class FFmpegRemoteFrameDecodeJob: @unchecked Sendable {
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

  func decode(
    filenameHint: String,
    timestampMilliseconds: Int64,
    maximumPixelDimension: Int?
  ) async throws -> FFmpegDecodedFrame {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async { [self] in
          do {
            continuation.resume(
              returning: try decodeSynchronously(
                filenameHint: filenameHint,
                timestampMilliseconds: timestampMilliseconds,
                maximumPixelDimension: maximumPixelDimension
              ))
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    } onCancel: {
      self.cancel()
    }
  }

  private func decodeSynchronously(
    filenameHint: String,
    timestampMilliseconds: Int64,
    maximumPixelDimension: Int?
  ) throws -> FFmpegDecodedFrame {
    var frame = StellarFFmpegDecodedFrame()
    defer { stellar_ffmpeg_decoded_frame_destroy(&frame) }
    let opaque = Unmanaged.passUnretained(reader).toOpaque()
    let status = filenameHint.withCString { hint in
      stellar_ffmpeg_capture_frame_with_io(
        context,
        opaque,
        remoteFFmpegReadCallback,
        remoteFFmpegSeekCallback,
        hint,
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
        message = "FFmpeg could not decode a remote screenshot (code \(status))"
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

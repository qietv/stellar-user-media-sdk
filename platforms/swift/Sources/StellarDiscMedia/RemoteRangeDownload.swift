import Foundation
internal import KSPlayer
import StellarCore
import StellarRemoteMedia

/// Synchronous KSPlayer reads backed by the SDK's asynchronous source-independent range API.
///
/// udfread requires synchronous callbacks. Callers must run BDMVIOContext work on a detached,
/// bounded worker rather than on the main actor.
final class RemoteRangeDownload: DownloadProtocol, CustomStringConvertible, @unchecked Sendable {
  let description: String

  private let session: any MediaSourceSession
  private let locator: RemoteLocator
  private let size: Int64
  private let timeoutMilliseconds: Int
  private let readAheadBytes: Int
  private let metrics: DiscProbeMetricsAccumulator?
  private let failureRecorder: DiscProbeIOFailureRecorder?
  private let operationLock = NSLock()
  private let stateLock = NSLock()
  private var position: Int64 = 0
  private var isClosed = false
  private var cachedOffset: Int64 = 0
  private var cachedData = Data()

  init(
    session: any MediaSourceSession,
    entry: RemoteEntry,
    description suppliedDescription: String? = nil,
    timeoutMilliseconds: Int = 30_000,
    readAheadBytes: Int = 0,
    metrics: DiscProbeMetricsAccumulator? = nil,
    failureRecorder: DiscProbeIOFailureRecorder? = nil
  ) throws {
    guard entry.kind == .file, let size = entry.size, size >= 0,
      (100...300_000).contains(timeoutMilliseconds),
      suppliedDescription?.isEmpty != true,
      suppliedDescription?.contains("\0") != true,
      suppliedDescription?.contains("/") != true,
      (0...4 * 1_024 * 1_024).contains(readAheadBytes)
    else {
      throw SDKError(code: .invalidConfiguration, message: "remote disc file is invalid")
    }
    self.session = session
    locator = entry.locator
    self.size = size
    self.timeoutMilliseconds = timeoutMilliseconds
    self.readAheadBytes = readAheadBytes
    self.metrics = metrics
    self.failureRecorder = failureRecorder
    description = suppliedDescription ?? entry.locator.path.name
  }

  func read(buffer: UnsafeMutablePointer<UInt8>?, size requestedSize: Int32) -> Int32 {
    guard requestedSize > 0, let buffer else { return requestedSize == 0 ? 0 : -1 }
    operationLock.lock()
    defer { operationLock.unlock() }

    let offset: Int64
    stateLock.lock()
    if isClosed {
      stateLock.unlock()
      return -1
    }
    offset = position
    stateLock.unlock()
    guard offset < size else { return 0 }

    let requestLength = Int(min(Int64(requestedSize), size - offset))
    let data: Data
    let cachedIndex = offset - cachedOffset
    if cachedIndex >= 0, cachedIndex < Int64(cachedData.count),
      Int64(cachedData.count) - cachedIndex >= Int64(requestLength)
    {
      let start = Int(cachedIndex)
      data = cachedData[start..<(start + requestLength)]
    } else {
      let fetchLength = Int(min(size - offset, Int64(max(requestLength, readAheadBytes))))
      let result = blockingRead(offset: offset, length: fetchLength)
      guard case .success(let fetched) = result else { return -1 }
      cachedOffset = offset
      cachedData = fetched
      data = fetched.prefix(requestLength)
    }

    stateLock.lock()
    guard !isClosed else {
      stateLock.unlock()
      return -1
    }
    let count = min(data.count, requestLength)
    data.withUnsafeBytes { bytes in
      guard let source = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
      buffer.update(from: source, count: count)
    }
    position = offset + Int64(count)
    stateLock.unlock()
    return Int32(count)
  }

  func seek(offset: Int64, whence: Int32) -> Int64 {
    operationLock.lock()
    defer { operationLock.unlock() }
    stateLock.lock()
    defer { stateLock.unlock() }
    guard !isClosed else { return -1 }

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

  func fileSize() -> Int64 { size }

  func close() {
    stateLock.lock()
    isClosed = true
    stateLock.unlock()
  }

  private func blockingRead(offset: Int64, length: Int) -> Result<Data, any Error> {
    let semaphore = DispatchSemaphore(value: 0)
    let resultBox = RemoteReadResultBox()
    let metrics = self.metrics
    let failureRecorder = self.failureRecorder
    let task = Task.detached(priority: .utility) {
      [session, locator, metrics, failureRecorder] in
      do {
        var result = Data()
        result.reserveCapacity(length)
        var nextOffset = offset
        while result.count < length {
          try Task.checkCancellation()
          let remaining = length - result.count
          let range = try RemoteByteRange(offset: nextOffset, length: remaining)
          let chunk = try await session.read(at: locator, range: range)
          metrics?.recordRangeRead(byteCount: chunk.count)
          guard !chunk.isEmpty else { break }
          let accepted = min(chunk.count, remaining)
          result.append(chunk.prefix(accepted))
          nextOffset += Int64(accepted)
        }
        resultBox.store(.success(result))
      } catch {
        failureRecorder?.record(error)
        resultBox.store(.failure(error))
      }
      semaphore.signal()
    }
    let deadline = DispatchTime.now() + .milliseconds(timeoutMilliseconds)
    while semaphore.wait(timeout: .now() + .milliseconds(25)) == .timedOut {
      stateLock.lock()
      let closed = isClosed
      stateLock.unlock()
      let cancelled = withUnsafeCurrentTask { $0?.isCancelled ?? false }
      if closed || cancelled || DispatchTime.now() >= deadline {
        task.cancel()
        let error = SDKError(
          code: cancelled ? .cancelled : .remoteUnavailable,
          message: cancelled ? "remote disc read was cancelled" : "remote disc read timed out"
        )
        failureRecorder?.record(error)
        return .failure(error)
      }
    }
    return resultBox.take()
      ?? .failure(SDKError(code: .remoteUnavailable, message: "remote disc read failed"))
  }
}

final class DiscProbeIOFailureRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var firstFailure: (any Error)?

  func record(_ error: any Error) {
    lock.lock()
    if firstFailure == nil { firstFailure = error }
    lock.unlock()
  }

  func failure() -> (any Error)? {
    lock.lock()
    defer { lock.unlock() }
    return firstFailure
  }
}

final class DiscProbeMetricsAccumulator: @unchecked Sendable {
  private let lock = NSLock()
  private var directoryListRequestCount = 0
  private var rangeReadRequestCount = 0
  private var rangeBytesRead: Int64 = 0

  func recordDirectoryListRequest() {
    lock.lock()
    directoryListRequestCount += 1
    lock.unlock()
  }

  func recordRangeRead(byteCount: Int) {
    lock.lock()
    rangeReadRequestCount += 1
    rangeBytesRead += Int64(max(0, byteCount))
    lock.unlock()
  }

  func snapshot(elapsedMilliseconds: Int64) throws -> DiscMediaProbeMetrics {
    lock.lock()
    let lists = directoryListRequestCount
    let reads = rangeReadRequestCount
    let bytes = rangeBytesRead
    lock.unlock()
    return try DiscMediaProbeMetrics(
      elapsedMilliseconds: elapsedMilliseconds,
      directoryListRequestCount: lists,
      rangeReadRequestCount: reads,
      rangeBytesRead: bytes
    )
  }
}

private final class RemoteReadResultBox: @unchecked Sendable {
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

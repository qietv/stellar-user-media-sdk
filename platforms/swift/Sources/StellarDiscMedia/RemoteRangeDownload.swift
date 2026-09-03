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
  private let operationLock = NSLock()
  private let stateLock = NSLock()
  private var position: Int64 = 0
  private var isClosed = false

  init(
    session: any MediaSourceSession,
    entry: RemoteEntry,
    description suppliedDescription: String? = nil,
    timeoutMilliseconds: Int = 30_000
  ) throws {
    guard entry.kind == .file, let size = entry.size, size >= 0,
      (100...300_000).contains(timeoutMilliseconds),
      suppliedDescription?.isEmpty != true,
      suppliedDescription?.contains("\0") != true,
      suppliedDescription?.contains("/") != true
    else {
      throw SDKError(code: .invalidConfiguration, message: "remote disc file is invalid")
    }
    self.session = session
    locator = entry.locator
    self.size = size
    self.timeoutMilliseconds = timeoutMilliseconds
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
    let result = blockingRead(offset: offset, length: requestLength)
    guard case .success(let data) = result else { return -1 }

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
    let task = Task.detached(priority: .utility) { [session, locator] in
      do {
        var result = Data()
        result.reserveCapacity(length)
        var nextOffset = offset
        while result.count < length {
          try Task.checkCancellation()
          let remaining = length - result.count
          let range = try RemoteByteRange(offset: nextOffset, length: remaining)
          let chunk = try await session.read(at: locator, range: range)
          guard !chunk.isEmpty else { break }
          let accepted = min(chunk.count, remaining)
          result.append(chunk.prefix(accepted))
          nextOffset += Int64(accepted)
        }
        resultBox.store(.success(result))
      } catch {
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
        return .failure(
          SDKError(
            code: cancelled ? .cancelled : .remoteUnavailable,
            message: cancelled ? "remote disc read was cancelled" : "remote disc read timed out"
          )
        )
      }
    }
    return resultBox.take()
      ?? .failure(SDKError(code: .remoteUnavailable, message: "remote disc read failed"))
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

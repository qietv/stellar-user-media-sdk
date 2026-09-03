import Foundation
internal import KSPlayer
import StellarCore
import StellarMediaLibrary
import StellarRemoteMedia

/// Presents an SDK media-source directory as the virtual root expected by BDMVIOContext.
final class RemoteBDMVFilesManager: FilesManager, @unchecked Sendable {
  private let session: any MediaSourceSession
  private let sentinelRoot: RemoteLocator
  private let virtualSentinel: String
  private let pageSize: Int
  private let readTimeoutMilliseconds: Int
  private let stateLock = NSLock()
  private var downloads: [RemoteRangeDownload] = []
  private var isClosed = false

  init(
    session: any MediaSourceSession,
    candidate: CompositeMediaDescriptor,
    pageSize: Int = 500,
    readTimeoutMilliseconds: Int = 30_000
  ) throws {
    guard candidate.container == .directory,
      candidate.kind == .bluray || candidate.kind == .avchd || candidate.kind == .dvdVideo,
      candidate.confidence == .candidate,
      (1...10_000).contains(pageSize),
      (100...300_000).contains(readTimeoutMilliseconds)
    else {
      throw SDKError(code: .invalidConfiguration, message: "remote disc request is invalid")
    }
    let resolvedSentinel: RemotePath
    let resolvedVirtualSentinel: String
    switch candidate.kind {
    case .bluray, .avchd:
      guard let entryPoint = candidate.entryPoint,
        Self.asciiCaseInsensitiveEqual(entryPoint.path.name, "index.bdmv"),
        let bdmvDirectory = entryPoint.path.parent,
        Self.asciiCaseInsensitiveEqual(bdmvDirectory.name, "BDMV"),
        let resolvedVirtualRoot = bdmvDirectory.parent,
        candidate.kind == .bluray
          ? resolvedVirtualRoot == candidate.logicalRoot.path
          : resolvedVirtualRoot.parent == candidate.logicalRoot.path
      else {
        throw SDKError(code: .invalidConfiguration, message: "remote BDMV entry point is invalid")
      }
      resolvedSentinel = bdmvDirectory
      resolvedVirtualSentinel = "BDMV"
    case .dvdVideo:
      guard let entryPoint = candidate.entryPoint,
        Self.asciiCaseInsensitiveEqual(entryPoint.path.name, "VIDEO_TS.IFO"),
        let videoTSDirectory = entryPoint.path.parent,
        Self.asciiCaseInsensitiveEqual(videoTSDirectory.name, "VIDEO_TS"),
        videoTSDirectory.parent == candidate.logicalRoot.path
      else {
        throw SDKError(code: .invalidConfiguration, message: "remote DVD entry point is invalid")
      }
      resolvedSentinel = videoTSDirectory
      resolvedVirtualSentinel = "VIDEO_TS"
    case .unknownDiscImage:
      throw SDKError(code: .invalidConfiguration, message: "remote disc kind is invalid")
    }
    self.session = session
    self.pageSize = pageSize
    self.readTimeoutMilliseconds = readTimeoutMilliseconds
    sentinelRoot = try RemoteLocator(
      sourceUID: candidate.logicalRoot.sourceUID,
      path: resolvedSentinel
    )
    virtualSentinel = resolvedVirtualSentinel
  }

  func contentsOfDirectory(atPath path: String) async throws -> [FileObject] {
    if virtualSentinel == "VIDEO_TS", Self.isSingleComponentPath(path, named: "BDMV") {
      return []
    }
    let directory = try await resolve(path)
    let entries = try await entries(in: directory)
    return entries.map { entry in
      let observedName = entry.locator.path.name
      let virtualName = canonicalDirectoryName(observedName, kind: entry.kind, parentPath: path)
      let virtualPath = Self.appendingVirtualName(virtualName, to: path)
      var values = [URLResourceKey: Sendable & Codable]()
      values[.nameKey] = virtualName
      values[.pathKey] = virtualPath
      values[.fileResourceTypeKey] =
        entry.kind == .directory ? URLFileResourceType.directory : .regular
      if let size = entry.size { values[.fileSizeKey] = size }
      if let modified = entry.modifiedAtMilliseconds {
        values[.contentModificationDateKey] = Date(
          timeIntervalSince1970: Double(modified) / 1_000
        )
      }
      return FileObject(
        url: URL(fileURLWithPath: virtualPath),
        allValues: values
      )
    }
  }

  func downloads(
    atPath path: String
  ) async throws -> [DownloadProtocol & CustomStringConvertible] {
    let directory = try await resolve(path)
    let entries = try await entries(in: directory).filter { $0.kind == .file }.sorted {
      let left = Self.asciiLowercased($0.locator.path.name)
      let right = Self.asciiLowercased($1.locator.path.name)
      return left == right ? $0.locator.path.name < $1.locator.path.name : left < right
    }
    let readers = try entries.map {
      try RemoteRangeDownload(
        session: session,
        entry: $0,
        description: canonicalFileName($0.locator.path.name),
        timeoutMilliseconds: readTimeoutMilliseconds
      )
    }
    guard register(readers) else {
      for reader in readers {
        reader.close()
      }
      throw SDKError(code: .cancelled, message: "remote BDMV manager is closed")
    }
    return readers
  }

  func close() {
    stateLock.lock()
    guard !isClosed else {
      stateLock.unlock()
      return
    }
    isClosed = true
    let active = downloads
    downloads.removeAll()
    stateLock.unlock()
    for download in active {
      download.close()
    }
  }

  private func entries(in directory: RemoteLocator) async throws -> [RemoteEntry] {
    guard !closedSnapshot() else {
      throw SDKError(code: .cancelled, message: "remote BDMV manager is closed")
    }

    var result: [RemoteEntry] = []
    var cursor: String?
    var seenCursors = Set<String>()
    repeat {
      try Task.checkCancellation()
      let request = try RemoteDirectoryPageRequest(
        directory: directory,
        cursor: cursor,
        limit: pageSize
      )
      let page = try await session.listDirectory(request)
      guard
        page.items.allSatisfy({ item in
          item.locator.sourceUID == directory.sourceUID
            && item.locator.path.parent == directory.path
        })
      else {
        throw SDKError(code: .parseFailure, message: "BDMV directory escaped its logical root")
      }
      result.append(contentsOf: page.items)
      cursor = page.nextCursor
      if let cursor, !seenCursors.insert(cursor).inserted {
        throw SDKError(code: .parseFailure, message: "BDMV directory repeated a page cursor")
      }
    } while cursor != nil
    return result
  }

  private func register(_ readers: [RemoteRangeDownload]) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard !isClosed else { return false }
    downloads.append(contentsOf: readers)
    return true
  }

  private func closedSnapshot() -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return isClosed
  }

  private func resolve(_ virtualPath: String) async throws -> RemoteLocator {
    guard virtualPath.hasPrefix("/"), !virtualPath.contains("\0") else {
      throw SDKError(code: .invalidConfiguration, message: "BDMV virtual path is invalid")
    }
    let components = virtualPath.split(separator: "/").map(String.init)
    guard let first = components.first, Self.asciiCaseInsensitiveEqual(first, virtualSentinel)
    else {
      throw SDKError(code: .invalidConfiguration, message: "disc virtual path is outside its root")
    }

    var directory = sentinelRoot
    for component in components.dropFirst() {
      let children = try await entries(in: directory).filter { $0.kind == .directory }
      let matching = children.filter {
        Self.asciiCaseInsensitiveEqual($0.locator.path.name, component)
      }
      guard
        let child = matching.first(where: { $0.locator.path.name == component }) ?? matching.first,
        matching.count == 1 || child.locator.path.name == component
      else {
        throw SDKError(code: .parseFailure, message: "BDMV virtual directory is ambiguous")
      }
      directory = child.locator
    }
    return directory
  }

  private static func appendingVirtualName(_ name: String, to path: String) -> String {
    path == "/" ? "/\(name)" : "\(path)/\(name)"
  }

  private func canonicalDirectoryName(
    _ name: String,
    kind: RemoteEntryKind,
    parentPath: String
  ) -> String {
    guard kind == .directory, virtualSentinel == "BDMV",
      Self.isSingleComponentPath(parentPath, named: "BDMV")
    else {
      return name
    }
    if Self.asciiCaseInsensitiveEqual(name, "PLAYLIST") { return "PLAYLIST" }
    if Self.asciiCaseInsensitiveEqual(name, "STREAM") { return "STREAM" }
    return name
  }

  private func canonicalFileName(_ name: String) -> String {
    if virtualSentinel == "VIDEO_TS" {
      return Self.asciiUppercased(name)
    }
    guard let separator = name.lastIndex(of: ".") else { return name }
    let pathExtension = name[name.index(after: separator)...]
    guard
      Self.asciiCaseInsensitiveEqual(pathExtension, "mpls")
        || Self.asciiCaseInsensitiveEqual(pathExtension, "m2ts")
        || Self.asciiCaseInsensitiveEqual(pathExtension, "mts")
    else {
      return name
    }
    return String(name[...separator]) + Self.asciiLowercased(pathExtension)
  }

  private static func isSingleComponentPath(_ path: String, named name: String) -> Bool {
    let components = path.split(separator: "/")
    return components.count == 1 && asciiCaseInsensitiveEqual(components[0], name)
  }

  private static func asciiCaseInsensitiveEqual<S: StringProtocol>(
    _ lhs: S,
    _ rhs: String
  ) -> Bool {
    let lhsBytes = lhs.utf8
    let rhsBytes = rhs.utf8
    guard lhsBytes.count == rhsBytes.count else { return false }
    return zip(lhsBytes, rhsBytes).allSatisfy { left, right in
      let foldedLeft = (65...90).contains(left) ? left + 32 : left
      let foldedRight = (65...90).contains(right) ? right + 32 : right
      return foldedLeft == foldedRight
    }
  }

  private static func asciiLowercased<S: StringProtocol>(_ value: S) -> String {
    String(decoding: value.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
  }

  private static func asciiUppercased<S: StringProtocol>(_ value: S) -> String {
    String(decoding: value.utf8.map { (97...122).contains($0) ? $0 - 32 : $0 }, as: UTF8.self)
  }
}

import Foundation
import StellarCore

/// These cursors refer to a live directory handle or temporary spool, never to a sorted offset.
package enum RemoteDirectorySessionCursor {
  package static func make() -> String { "scan-session-v1:\(UUID().uuidString)" }

  package static func requiresRestart(_ cursor: String) -> Bool {
    cursor.hasPrefix("scan-session-v1:") || cursor.hasPrefix("local-v1:")
      || cursor.hasPrefix("webdav-v1:") || cursor.hasPrefix("smb-v1:")
  }
}

/// Disk-backed, source-order entries for legacy transports that return complete arrays.
/// The producer and consumer use this object serially. No directory-sized array is retained.
package final class RemoteDirectoryEntrySpool: @unchecked Sendable {
  private let url: URL
  private var writer: FileHandle?
  private var readOffset: UInt64 = 0
  private var byteCount: UInt64 = 0
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  package init() throws {
    url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    guard
      FileManager.default.createFile(
        atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]
      )
    else {
      throw SDKError(code: .storageFailure, message: "directory spool could not be created")
    }
    do {
      writer = try FileHandle(forWritingTo: url)
    } catch {
      try? FileManager.default.removeItem(at: url)
      throw SDKError(code: .storageFailure, message: "directory spool could not be opened")
    }
  }

  deinit {
    try? writer?.close()
    try? FileManager.default.removeItem(at: url)
  }

  package func append(_ entry: RemoteEntry) throws {
    try Task.checkCancellation()
    guard let writer else {
      throw SDKError(code: .storageFailure, message: "directory spool is sealed")
    }
    let data = try encoder.encode(entry)
    guard data.count <= Self.maximumRecordSize else {
      throw SDKError(code: .parseFailure, message: "directory entry exceeds the size limit")
    }
    var length = UInt32(data.count).bigEndian
    do {
      try withUnsafeBytes(of: &length) { try writer.write(contentsOf: $0) }
      try writer.write(contentsOf: data)
      byteCount += UInt64(data.count + 4)
    } catch {
      throw SDKError(code: .storageFailure, message: "directory spool write failed")
    }
  }

  package func readPage(limit: Int) throws -> (items: [RemoteEntry], hasMore: Bool) {
    try writer?.close()
    writer = nil
    let reader = try FileHandle(forReadingFrom: url)
    defer { try? reader.close() }
    try reader.seek(toOffset: readOffset)
    var items: [RemoteEntry] = []
    while items.count < limit, readOffset < byteCount {
      try Task.checkCancellation()
      guard let header = try reader.read(upToCount: 4), header.count == 4 else {
        throw SDKError(code: .storageFailure, message: "directory spool is truncated")
      }
      let length = header.reduce(0) { ($0 << 8) | Int($1) }
      guard length > 0, length <= Self.maximumRecordSize,
        let data = try reader.read(upToCount: length), data.count == length
      else {
        throw SDKError(code: .storageFailure, message: "directory spool record is invalid")
      }
      items.append(try decoder.decode(RemoteEntry.self, from: data))
      readOffset += UInt64(length + 4)
    }
    return (items, readOffset < byteCount)
  }

  private static let maximumRecordSize = 1_048_576
}

/// Session-bound paging over a disk spool. Sorting and whole-directory fingerprints are unnecessary.
package struct RemoteDirectorySpoolPaginator: Sendable {
  private let pathSemantics: RemotePathSemantics
  private var spools: [String: PagingState] = [:]

  package init(pathSemantics: RemotePathSemantics) {
    self.pathSemantics = pathSemantics
  }

  package mutating func cachedPage(
    for request: RemoteDirectoryPageRequest
  ) throws -> CursorPage<RemoteEntry>? {
    guard let cursor = request.cursor else { return nil }
    guard let state = spools[cursor], state.directory == request.directory
    else {
      throw SDKError(code: .conflict, message: "directory cursor expired; restart discovery")
    }
    spools.removeValue(forKey: cursor)
    return try page(from: state.spool, for: request)
  }

  /// Compatibility for injected transports that still expose only an array API.
  package mutating func storeAndPage(
    _ entries: [RemoteEntry],
    for request: RemoteDirectoryPageRequest,
    exclusionMarkerFileNames: Set<String> = []
  ) throws -> CursorPage<RemoteEntry> {
    let spool = try RemoteDirectoryEntrySpool()
    for entry in entries {
      if isExclusionMarker(entry, names: exclusionMarkerFileNames) {
        return try CursorPage(items: [], nextCursor: nil)
      }
      try spool.append(entry)
    }
    return try storeAndPage(spool, for: request)
  }

  package func isExclusionMarker(_ entry: RemoteEntry, names: Set<String>) -> Bool {
    guard entry.kind == .file else { return false }
    if pathSemantics.caseSensitivity == .insensitive {
      return names.contains { $0.lowercased() == entry.locator.path.name.lowercased() }
    }
    return names.contains(entry.locator.path.name)
  }

  package mutating func storeAndPage(
    _ spool: RemoteDirectoryEntrySpool, for request: RemoteDirectoryPageRequest
  ) throws -> CursorPage<RemoteEntry> {
    guard request.cursor == nil else {
      throw SDKError(code: .conflict, message: "directory cursor expired; restart discovery")
    }
    return try page(from: spool, for: request)
  }

  package mutating func removeAll() { spools.removeAll() }

  private mutating func page(
    from spool: RemoteDirectoryEntrySpool, for request: RemoteDirectoryPageRequest
  ) throws -> CursorPage<RemoteEntry> {
    let page = try spool.readPage(limit: request.limit)
    let cursor = page.hasMore ? RemoteDirectorySessionCursor.make() : nil
    if let cursor {
      spools[cursor] = PagingState(spool: spool, directory: request.directory)
    }
    return try CursorPage(items: page.items, nextCursor: cursor)
  }

  private struct PagingState: Sendable {
    let spool: RemoteDirectoryEntrySpool
    let directory: RemoteLocator
  }
}

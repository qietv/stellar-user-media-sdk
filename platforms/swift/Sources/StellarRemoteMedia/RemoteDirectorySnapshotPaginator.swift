import Foundation
import StellarCore

/// Package-shared paging state for sources that can only enumerate a whole directory.
///
/// A source loads and normalizes a directory once. Later logical pages are sliced from the
/// retained snapshot. If a process or connection resumes without that in-memory snapshot, the
/// source may load it once again; the cursor fingerprint then rejects a changed directory.
package struct RemoteDirectorySnapshotPaginator: Sendable {
  private let cursorNamespace: String
  private let pathSemantics: RemotePathSemantics
  private var snapshots: [RemoteLocator: Snapshot] = [:]

  package init(
    cursorNamespace: String,
    pathSemantics: RemotePathSemantics
  ) {
    self.cursorNamespace = cursorNamespace
    self.pathSemantics = pathSemantics
  }

  /// Returns a page from an already retained snapshot, or `nil` when the directory must be read.
  package mutating func cachedPage(
    for request: RemoteDirectoryPageRequest
  ) throws -> CursorPage<RemoteEntry>? {
    guard let rawCursor = request.cursor else { return nil }
    let cursor = try Cursor(rawCursor, namespace: cursorNamespace)
    guard let snapshot = snapshots[request.directory] else { return nil }
    guard snapshot.fingerprint == cursor.fingerprint else {
      snapshots.removeValue(forKey: request.directory)
      throw SDKError(code: .conflict, message: "directory changed during pagination")
    }
    return try page(from: snapshot, offset: cursor.offset, for: request)
  }

  /// Normalizes one complete directory response and returns the requested logical page.
  package mutating func storeAndPage(
    _ entries: [RemoteEntry],
    for request: RemoteDirectoryPageRequest
  ) throws -> CursorPage<RemoteEntry> {
    let snapshot = Snapshot(
      entries: Self.sorted(entries, using: pathSemantics),
      semantics: pathSemantics
    )
    let offset: Int
    if let rawCursor = request.cursor {
      let cursor = try Cursor(rawCursor, namespace: cursorNamespace)
      guard cursor.fingerprint == snapshot.fingerprint else {
        snapshots.removeValue(forKey: request.directory)
        throw SDKError(code: .conflict, message: "directory changed during pagination")
      }
      offset = cursor.offset
    } else {
      offset = 0
    }
    return try page(from: snapshot, offset: offset, for: request)
  }

  /// Releases all retained directory snapshots when the source session closes.
  package mutating func removeAll() {
    snapshots.removeAll(keepingCapacity: false)
  }

  private mutating func page(
    from snapshot: Snapshot,
    offset: Int,
    for request: RemoteDirectoryPageRequest
  ) throws -> CursorPage<RemoteEntry> {
    guard offset <= snapshot.entries.count else {
      snapshots.removeValue(forKey: request.directory)
      throw SDKError(code: .conflict, message: "directory changed during pagination")
    }
    let upperBound = min(snapshot.entries.count, offset + request.limit)
    let entries = Array(snapshot.entries[offset..<upperBound])
    let nextCursor: String?
    if upperBound < snapshot.entries.count {
      snapshots[request.directory] = snapshot
      nextCursor =
        Cursor(
          offset: upperBound,
          fingerprint: snapshot.fingerprint,
          namespace: cursorNamespace
        ).rawValue
    } else {
      snapshots.removeValue(forKey: request.directory)
      nextCursor = nil
    }
    return try CursorPage(items: entries, nextCursor: nextCursor)
  }

  private static func sorted(
    _ entries: [RemoteEntry],
    using semantics: RemotePathSemantics
  ) -> [RemoteEntry] {
    entries.sorted { left, right in
      let leftKey = left.locator.pathComparisonKey(using: semantics)
      let rightKey = right.locator.pathComparisonKey(using: semantics)
      if leftKey == rightKey {
        return left.locator.path.relativePath < right.locator.path.relativePath
      }
      return leftKey < rightKey
    }
  }

  private struct Snapshot: Sendable {
    let entries: [RemoteEntry]
    let fingerprint: String

    init(entries: [RemoteEntry], semantics: RemotePathSemantics) {
      self.entries = entries
      fingerprint = Self.fingerprint(entries, semantics: semantics)
    }

    private static func fingerprint(
      _ entries: [RemoteEntry],
      semantics: RemotePathSemantics
    ) -> String {
      var hash: UInt64 = 14_695_981_039_346_656_037
      for entry in entries {
        let fields = [
          entry.locator.pathComparisonKey(using: semantics),
          entry.kind.rawValue,
          entry.stableID ?? "",
          entry.size.map(String.init) ?? "",
          entry.modifiedAtMilliseconds.map(String.init) ?? "",
          entry.entityTag ?? "",
        ]
        for byte in fields.joined(separator: "\u{1f}").utf8 {
          hash ^= UInt64(byte)
          hash &*= 1_099_511_628_211
        }
        hash ^= 0xff
        hash &*= 1_099_511_628_211
      }
      return String(format: "%016llx", hash)
    }
  }

  private struct Cursor {
    let offset: Int
    let fingerprint: String
    let namespace: String

    var rawValue: String { "\(namespace):\(offset):\(fingerprint)" }

    init(offset: Int, fingerprint: String, namespace: String) {
      self.offset = offset
      self.fingerprint = fingerprint
      self.namespace = namespace
    }

    init(_ rawValue: String, namespace: String) throws {
      let components = rawValue.split(separator: ":", omittingEmptySubsequences: false)
      guard components.count == 3,
        components[0] == Substring(namespace),
        let offset = Int(components[1]),
        offset > 0,
        components[2].count == 16,
        components[2].allSatisfy({ $0.isHexDigit })
      else {
        throw SDKError(code: .invalidConfiguration, message: "remote page cursor is invalid")
      }
      self.offset = offset
      fingerprint = String(components[2])
      self.namespace = namespace
    }
  }
}

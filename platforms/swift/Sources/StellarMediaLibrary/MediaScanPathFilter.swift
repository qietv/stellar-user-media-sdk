import Foundation
import StellarCore
import StellarRemoteMedia

/// A source-independent path and file-admission policy for media discovery.
///
/// Scope comparison keys are normalized once at initialization. The hot per-entry path only
/// performs string prefix checks plus an optional file-extension lookup, so Local, SMB, WebDAV,
/// and server-cursor sources can share the same filtering behavior.
public struct MediaScanPathFilter: MediaScanTraversalPolicy, Sendable {
  public let pathSemantics: RemotePathSemantics
  public let includedRoots: [RemotePath]
  public let excludedRoots: [RemotePath]
  public let allowedFileExtensions: Set<String>?
  public let excludedDirectoryNames: Set<String>
  public let ignoresHiddenDirectories: Bool
  public let exclusionMarkerFileNames: [String]

  private let includedRootKeys: [String]
  private let excludedRootKeys: [String]

  /// Creates a reusable scan filter.
  ///
  /// - Parameters:
  ///   - includedRoots: Library scopes. The source root is used when the array is empty.
  ///   - excludedRoots: Subtrees that must not be enumerated or indexed.
  ///   - allowedFileExtensions: Lowercase or mixed-case extensions without a leading dot.
  ///     Pass `nil` to admit every file type.
  ///   - excludedDirectoryNames: Source-independent service or recycle directory names.
  ///   - ignoresHiddenDirectories: Whether dot-prefixed directories should be skipped.
  ///   - exclusionMarkerFileNames: Marker files checked before a logical directory page is
  ///     exposed. The common value is `[".nomedia"]`. Snapshot adapters reuse their directory
  ///     response; true cursor adapters may perform a bounded `stat` for each configured marker.
  public init(
    pathSemantics: RemotePathSemantics,
    includedRoots: [RemotePath] = [],
    excludedRoots: [RemotePath] = [],
    allowedFileExtensions: Set<String>? = nil,
    excludedDirectoryNames: Set<String> = [],
    ignoresHiddenDirectories: Bool = false,
    exclusionMarkerFileNames: [String] = []
  ) throws {
    let included = includedRoots.isEmpty ? [try RemotePath()] : includedRoots
    let normalizedExtensions = try allowedFileExtensions.map { extensions in
      try Set(extensions.map(Self.normalizedExtension))
    }
    let normalizedNames = Set(excludedDirectoryNames.map(Self.foldASCIIName))
    guard excludedDirectoryNames.allSatisfy(Self.validPathComponent),
      exclusionMarkerFileNames.allSatisfy(Self.validPathComponent)
    else {
      throw SDKError(code: .invalidConfiguration, message: "scan path filter is invalid")
    }

    self.pathSemantics = pathSemantics
    self.includedRoots = Self.compact(included, semantics: pathSemantics)
    self.excludedRoots = Self.compact(excludedRoots, semantics: pathSemantics)
    self.allowedFileExtensions = normalizedExtensions
    self.excludedDirectoryNames = normalizedNames
    self.ignoresHiddenDirectories = ignoresHiddenDirectories
    self.exclusionMarkerFileNames = exclusionMarkerFileNames
    includedRootKeys = self.includedRoots.map { $0.comparisonKey(using: pathSemantics) }
    excludedRootKeys = self.excludedRoots.map { $0.comparisonKey(using: pathSemantics) }
  }

  public func shouldIndexFile(_ entry: RemoteEntry) -> Bool {
    let key = entry.locator.pathComparisonKey(using: pathSemantics)
    guard isIncluded(key), !isExcluded(key) else { return false }
    guard let allowedFileExtensions else { return true }
    guard let fileExtension = Self.fileExtension(of: entry.locator.path.name) else {
      return false
    }
    return allowedFileExtensions.contains(fileExtension)
  }

  public func shouldTraverseDirectory(_ entry: RemoteEntry) -> Bool {
    shouldTraverse(entry.locator.path)
  }

  public var directoryExclusionMarkerFileNames: Set<String> {
    Set(exclusionMarkerFileNames)
  }

  private func shouldTraverse(_ path: RemotePath) -> Bool {
    if !path.isRoot {
      let name = path.name
      if ignoresHiddenDirectories, name.utf8.first == 46 { return false }
      if excludedDirectoryNames.contains(Self.foldASCIIName(name)) { return false }
    }
    let key = path.comparisonKey(using: pathSemantics)
    guard !isExcluded(key) else { return false }
    return includedRootKeys.contains { includedKey in
      Self.isEqualOrDescendant(key, of: includedKey)
        || Self.isEqualOrDescendant(includedKey, of: key)
    }
  }

  private func isIncluded(_ key: String) -> Bool {
    includedRootKeys.contains { Self.isEqualOrDescendant(key, of: $0) }
  }

  private func isExcluded(_ key: String) -> Bool {
    excludedRootKeys.contains { Self.isEqualOrDescendant(key, of: $0) }
  }

  private static func compact(
    _ paths: [RemotePath],
    semantics: RemotePathSemantics
  ) -> [RemotePath] {
    let sorted = paths.sorted {
      let left = $0.comparisonKey(using: semantics)
      let right = $1.comparisonKey(using: semantics)
      return (left.utf8.count, left) < (right.utf8.count, right)
    }
    var accepted: [(path: RemotePath, key: String)] = []
    accepted.reserveCapacity(sorted.count)
    for path in sorted {
      let key = path.comparisonKey(using: semantics)
      guard !accepted.contains(where: { isEqualOrDescendant(key, of: $0.key) }) else {
        continue
      }
      accepted.append((path, key))
    }
    return accepted.map(\.path)
  }

  private static func isEqualOrDescendant(_ candidate: String, of root: String) -> Bool {
    root.isEmpty || candidate == root || candidate.hasPrefix("\(root)/")
  }

  private static func normalizedExtension(_ value: String) throws -> String {
    let normalized = value.hasPrefix(".") ? String(value.dropFirst()) : value
    guard !normalized.isEmpty, !normalized.contains("\0"), !normalized.contains("/") else {
      throw SDKError(code: .invalidConfiguration, message: "scan file extension is invalid")
    }
    return foldASCIIName(normalized)
  }

  private static func fileExtension(of name: String) -> String? {
    guard let separator = name.utf8.lastIndex(of: 46), separator != name.startIndex else {
      return nil
    }
    let start = name.index(after: separator)
    guard start != name.endIndex else { return nil }
    return foldASCIIName(String(name[start...]))
  }

  private static func foldASCIIName(_ value: String) -> String {
    var requiresFold = false
    for byte in value.utf8 {
      if byte >= 0x80 { return value.lowercased() }
      requiresFold = requiresFold || (0x41...0x5A).contains(byte)
    }
    guard requiresFold else { return value }
    return String(decoding: value.utf8.map { byte in
      (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
    }, as: UTF8.self)
  }

  private static func validPathComponent(_ value: String) -> Bool {
    !value.isEmpty && value != "." && value != ".."
      && !value.utf8.contains(0) && !value.utf8.contains(47)
  }
}

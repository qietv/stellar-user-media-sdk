import Foundation
import StellarCore

/// A normalized path relative to the configured root inside an SMB share.
public struct SMB2Path: Equatable, Hashable, Sendable, CustomStringConvertible {
  /// The normalized slash-separated path. Treat this value as sensitive in diagnostics.
  public let relativePath: String

  /// Creates a share-relative path and rejects parent traversal or NUL bytes.
  public init(_ path: String = "") throws {
    guard !path.utf8.contains(0), !path.utf8.contains(92) else {
      throw SDKError(code: .invalidConfiguration, message: "SMB path contains invalid characters")
    }
    var components: [Substring] = []
    for component in path.split(separator: "/", omittingEmptySubsequences: true) {
      if component == "." {
        continue
      }
      guard component != ".." else {
        throw SDKError(code: .invalidConfiguration, message: "SMB path must not traverse parents")
      }
      components.append(component)
    }
    relativePath = components.joined(separator: "/")
  }

  private init(normalizedRelativePath: String) {
    relativePath = normalizedRelativePath
  }

  /// Whether this path names the root of the share.
  public var isRoot: Bool { relativePath.isEmpty }

  /// The last path component, or an empty string for the share root.
  public var name: String {
    guard let separator = relativePath.utf8.lastIndex(of: 47) else { return relativePath }
    return String(relativePath[relativePath.index(after: separator)...])
  }

  /// Returns a child path without accepting separators or traversal components in the name.
  public func appending(component: String) throws -> SMB2Path {
    guard !component.isEmpty, component != ".", component != "..",
      !component.utf8.contains(47), !component.utf8.contains(92), !component.utf8.contains(0)
    else {
      throw SDKError(code: .invalidConfiguration, message: "invalid SMB path component")
    }
    return SMB2Path(
      normalizedRelativePath: isRoot ? component : "\(relativePath)/\(component)"
    )
  }

  /// A redacted representation safe for routine diagnostics.
  public var description: String { SensitiveDataRedactor.pathPlaceholder }
}

/// A non-secret SMB server/share address.
public struct SMB2Endpoint: Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  /// Hostname, IP address, or bracketed IPv6 address without URL userinfo.
  public let server: String
  /// Optional explicit TCP port.
  public let port: UInt16?
  /// Share name without path separators.
  public let share: String
  /// Root below the share used by the connector.
  public let rootPath: SMB2Path

  /// Creates a validated endpoint. Credentials must be supplied separately.
  public init(server: String, port: UInt16? = nil, share: String, rootPath: String = "") throws {
    let normalizedServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedShare = share.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedServer.isEmpty, !normalizedShare.isEmpty else {
      throw SDKError(code: .invalidConfiguration, message: "SMB server and share are required")
    }
    guard !normalizedServer.contains("://"), !normalizedServer.contains("@"),
      !normalizedServer.contains("/"), !normalizedServer.contains("\\"),
      !normalizedServer.contains("\0")
    else {
      throw SDKError(
        code: .invalidConfiguration,
        message: "SMB server must not contain URL credentials or path data"
      )
    }
    if normalizedServer.contains(":"),
      !(normalizedServer.hasPrefix("[") && normalizedServer.hasSuffix("]"))
    {
      throw SDKError(
        code: .invalidConfiguration,
        message: "IPv6 SMB servers must use brackets and ports must use the port field"
      )
    }
    guard !normalizedShare.contains("/"), !normalizedShare.contains("\\"),
      !normalizedShare.contains("\0"), normalizedShare != ".", normalizedShare != "..",
      port != 0
    else {
      throw SDKError(code: .invalidConfiguration, message: "SMB share is invalid")
    }
    self.server = normalizedServer
    self.port = port
    self.share = normalizedShare
    self.rootPath = try SMB2Path(rootPath)
  }

  /// A representation that hides the server, share, and root path.
  public var description: String { "<SMB2Endpoint redacted>" }

  /// A representation that hides the server, share, and root path.
  public var debugDescription: String { description }
}

/// Ephemeral NTLMSSP credential material that always renders as redacted.
public struct SMB2Credential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  package let domain: String?
  package let username: String
  package let password: String

  /// Creates credential material for one connection attempt.
  public init(domain: String? = nil, username: String, password: String) throws {
    let normalizedDomain = domain?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedUsername.isEmpty, !normalizedUsername.contains("\0"),
      !password.contains("\0"), normalizedDomain?.contains("\0") != true
    else {
      throw SDKError(code: .invalidConfiguration, message: "SMB credential is invalid")
    }
    self.domain = normalizedDomain?.isEmpty == true ? nil : normalizedDomain
    self.username = normalizedUsername
    self.password = password
  }

  /// A representation that never contains the domain, username, or password.
  public var description: String { "<SMB2Credential redacted>" }

  /// A representation that never contains the domain, username, or password.
  public var debugDescription: String { description }
}

/// SMB dialect reported after negotiation.
public enum SMB2Dialect: Equatable, Sendable, CustomStringConvertible {
  case smb202
  case smb210
  case smb300
  case smb302
  case smb311
  case unknown(UInt16)

  /// Converts the protocol's 16-bit dialect value without rejecting future dialects.
  public init(wireValue: UInt16) {
    switch wireValue {
    case 0x0202: self = .smb202
    case 0x0210: self = .smb210
    case 0x0300: self = .smb300
    case 0x0302: self = .smb302
    case 0x0311: self = .smb311
    default: self = .unknown(wireValue)
    }
  }

  /// The protocol's 16-bit dialect value.
  public var wireValue: UInt16 {
    switch self {
    case .smb202: 0x0202
    case .smb210: 0x0210
    case .smb300: 0x0300
    case .smb302: 0x0302
    case .smb311: 0x0311
    case .unknown(let value): value
    }
  }

  /// A stable diagnostic label that contains no connection information.
  public var description: String {
    switch self {
    case .smb202: "2.0.2"
    case .smb210: "2.1"
    case .smb300: "3.0"
    case .smb302: "3.0.2"
    case .smb311: "3.1.1"
    case .unknown(let value): "unknown-0x\(String(value, radix: 16))"
    }
  }
}

/// Dialect constraint applied during SMB negotiation.
public enum SMB2VersionPolicy: Equatable, Sendable {
  case anySupported
  case smb2Only
  case smb3Only
  case exact(SMB2Dialect)
}

/// Signing requirement for a connection attempt.
public enum SMB2SigningPolicy: Equatable, Sendable {
  case enabled
  case required
}

/// Encryption requirement for a connection attempt.
public enum SMB2EncryptionPolicy: Equatable, Sendable {
  case disabled
  case required
}

/// Complete, non-persistable input for one SMB connection attempt.
public struct SMB2ConnectionRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible
{
  public let endpoint: SMB2Endpoint
  public let credential: SMB2Credential
  public let versionPolicy: SMB2VersionPolicy
  public let signingPolicy: SMB2SigningPolicy
  public let encryptionPolicy: SMB2EncryptionPolicy
  public let timeoutMilliseconds: Int64

  /// Creates a validated request with signing enabled and a 30-second timeout.
  public init(
    endpoint: SMB2Endpoint,
    credential: SMB2Credential,
    versionPolicy: SMB2VersionPolicy = .anySupported,
    signingPolicy: SMB2SigningPolicy = .enabled,
    encryptionPolicy: SMB2EncryptionPolicy = .disabled,
    timeoutMilliseconds: Int64 = 30_000
  ) throws {
    guard timeoutMilliseconds > 0, timeoutMilliseconds <= Int64(Int32.max) * 1_000 else {
      throw SDKError(code: .invalidConfiguration, message: "SMB timeout is out of range")
    }
    if case .exact(.unknown) = versionPolicy {
      throw SDKError(code: .invalidConfiguration, message: "unknown SMB dialect cannot be required")
    }
    if encryptionPolicy == .required {
      switch versionPolicy {
      case .smb2Only, .exact(.smb202), .exact(.smb210):
        throw SDKError(
          code: .invalidConfiguration,
          message: "SMB encryption requires an SMB 3 dialect"
        )
      default:
        break
      }
    }
    self.endpoint = endpoint
    self.credential = credential
    self.versionPolicy = versionPolicy
    self.signingPolicy = signingPolicy
    self.encryptionPolicy = encryptionPolicy
    self.timeoutMilliseconds = timeoutMilliseconds
  }

  /// A representation that includes policy but no endpoint or credential values.
  public var description: String {
    "<SMB2ConnectionRequest version=\(versionPolicy) signing=\(signingPolicy) encryption=\(encryptionPolicy)>"
  }

  /// A representation that includes policy but no endpoint or credential values.
  public var debugDescription: String { description }
}

/// Negotiation facts safe to include in an acceptance report.
public struct SMB2ConnectionInfo: Equatable, Sendable {
  public let dialect: SMB2Dialect
  public let signingPolicy: SMB2SigningPolicy
  public let encryptionPolicy: SMB2EncryptionPolicy
  public let implementationVersion: String

  public init(
    dialect: SMB2Dialect,
    signingPolicy: SMB2SigningPolicy,
    encryptionPolicy: SMB2EncryptionPolicy,
    implementationVersion: String
  ) {
    self.dialect = dialect
    self.signingPolicy = signingPolicy
    self.encryptionPolicy = encryptionPolicy
    self.implementationVersion = implementationVersion
  }
}

/// The filesystem kind reported by an SMB directory entry or stat call.
public enum SMB2EntryKind: Equatable, Sendable {
  case file
  case directory
  case symbolicLink
  case unknown(UInt32)
}

/// A read-only SMB filesystem fact independent of libsmb2 C structures.
public struct SMB2Entry: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible
{
  public let path: SMB2Path
  public let kind: SMB2EntryKind
  public let size: Int64?
  public let modifiedAtMilliseconds: Int64?
  public let stableID: String?

  /// Creates a validated entry. File sizes must not be negative.
  public init(
    path: SMB2Path,
    kind: SMB2EntryKind,
    size: Int64? = nil,
    modifiedAtMilliseconds: Int64? = nil,
    stableID: String? = nil
  ) throws {
    guard size.map({ $0 >= 0 }) ?? true else {
      throw SDKError(code: .parseFailure, message: "SMB entry size must not be negative")
    }
    self.path = path
    self.kind = kind
    self.size = size
    self.modifiedAtMilliseconds = modifiedAtMilliseconds
    self.stableID = stableID
  }

  /// A representation that hides path and stable identifier values.
  public var description: String {
    "<SMB2Entry kind=\(kind) size=\(size.map(String.init) ?? "unknown")>"
  }

  /// A representation that hides path and stable identifier values.
  public var debugDescription: String { description }
}

/// A validated byte range for an SMB pread operation.
public struct SMB2ByteRange: Equatable, Sendable {
  public let offset: Int64
  public let length: Int

  public init(offset: Int64, length: Int) throws {
    guard offset >= 0, length > 0, Int64(length) <= Int64.max - offset else {
      throw SDKError(code: .invalidConfiguration, message: "SMB byte range is invalid")
    }
    self.offset = offset
    self.length = length
  }
}

/// A connected, uniquely owned SMB session that exposes only read operations.
public protocol SMB2Session: Sendable {
  var connectionInfo: SMB2ConnectionInfo { get async }
  func listDirectory(at path: SMB2Path) async throws -> [SMB2Entry]
  func stat(_ path: SMB2Path) async throws -> SMB2Entry
  func read(at path: SMB2Path, range: SMB2ByteRange) async throws -> Data
  func disconnect() async
}

/// Package-only fast path for transports that can retain and incrementally consume a directory.
/// Other SMB transports continue to use the full-directory compatibility API above.
package struct SMB2DirectoryPage: Sendable {
  package let items: [SMB2Entry]
  package let nextCursor: String?

  package init(items: [SMB2Entry], nextCursor: String?) {
    self.items = items
    self.nextCursor = nextCursor
  }
}

package protocol SMB2DirectoryPagingSession: SMB2Session {
  func listDirectoryPage(
    at path: SMB2Path,
    cursor: String?,
    limit: Int
  ) async throws -> SMB2DirectoryPage
}

/// Injectable transport boundary used by the SMB connector and server-free contract tests.
public protocol SMB2Transport: Sendable {
  func connect(_ request: SMB2ConnectionRequest) async throws -> any SMB2Session
}

package enum SMB2Operation: Equatable, Sendable {
  case connect
  case listDirectory
  case stat
  case read
}

package enum SMB2POSIXErrorMapper {
  package static func map(status: Int32, operation: SMB2Operation) -> SDKError {
    let magnitude = status < 0 ? -Int64(status) : Int64(status)
    guard magnitude <= Int64(Int32.max),
      let posixCode = POSIXErrorCode(rawValue: Int32(magnitude))
    else {
      return SDKError(code: .unknown, message: "SMB operation failed")
    }

    switch posixCode {
    case .ECANCELED:
      return SDKError(code: .cancelled, message: "SMB operation cancelled")
    case .EACCES, .EPERM:
      if operation == .connect {
        return SDKError(code: .unauthorized, message: "SMB authentication failed")
      }
      return SDKError(code: .forbidden, message: "SMB permission denied")
    case .ENOENT, .ENOTDIR:
      if operation == .connect {
        return SDKError(code: .remoteUnavailable, message: "SMB share is unavailable")
      }
      return SDKError(code: .metadataNotFound, message: "SMB entry was not found")
    case .ENETDOWN, .ENETUNREACH:
      return SDKError(code: .networkUnavailable, message: "network is unavailable")
    case .EAGAIN:
      return SDKError(code: .networkUnavailable, message: "network is temporarily unavailable")
    case .EBUSY:
      return SDKError(code: .conflict, message: "SMB session is busy")
    case .EHOSTUNREACH, .ECONNREFUSED, .ECONNRESET, .ECONNABORTED, .ENOTCONN, .ETIMEDOUT,
      .EPIPE:
      return SDKError(code: .remoteUnavailable, message: "SMB server is unavailable")
    case .EPROTO, .EBADMSG:
      return SDKError(code: .remoteUnavailable, message: "SMB protocol operation failed")
    case .EINVAL:
      return SDKError(code: .invalidConfiguration, message: "SMB request is invalid")
    case .EIO where operation == .connect:
      return SDKError(code: .remoteUnavailable, message: "SMB server is unavailable")
    default:
      return SDKError(code: .unknown, message: "SMB operation failed")
    }
  }
}

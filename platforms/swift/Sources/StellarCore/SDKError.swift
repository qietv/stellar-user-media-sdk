import Foundation

/// Cross-platform error categories defined by `specs/README.md`.
public enum SDKErrorCode: String, CaseIterable, Sendable {
  case cancelled
  case unauthorized
  case forbidden
  case networkUnavailable = "network_unavailable"
  case rateLimited = "rate_limited"
  case remoteUnavailable = "remote_unavailable"
  case credentialRequired = "credential_required"
  case invalidConfiguration = "invalid_configuration"
  case storageFailure = "storage_failure"
  case parseFailure = "parse_failure"
  case metadataNotFound = "metadata_not_found"
  case conflict
  case unknown
}

extension SDKErrorCode: Codable {
  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = SDKErrorCode(rawValue: value) ?? .unknown
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// A stable public error value that can cross SDK module boundaries.
public struct SDKError: Error, Codable, Equatable, Sendable {
  public let code: SDKErrorCode
  public let message: String
  public let retryAfterMilliseconds: Int64?
  public let traceID: String?

  public init(
    code: SDKErrorCode,
    message: String,
    retryAfterMilliseconds: Int64? = nil,
    traceID: String? = nil
  ) {
    self.code = code
    self.message = message
    self.retryAfterMilliseconds = retryAfterMilliseconds
    self.traceID = traceID
  }

  private enum CodingKeys: String, CodingKey {
    case code
    case message
    case retryAfterMilliseconds = "retry_after_ms"
    case traceID = "trace_id"
  }
}

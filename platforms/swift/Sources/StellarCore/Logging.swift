/// Severity shared by SDK diagnostic sinks.
public enum SDKLogLevel: String, Codable, CaseIterable, Sendable {
  case debug
  case info
  case notice
  case warning
  case error
}

/// A log metadata value together with its required privacy treatment.
public struct SDKLogMetadataValue: Equatable, Sendable {
  public let value: String
  public let privacy: SDKLogPrivacy

  public init(_ value: String, privacy: SDKLogPrivacy = .plain) {
    self.value = value
    self.privacy = privacy
  }
}

/// An SDK diagnostic event before privacy processing.
public struct SDKLogEvent: Equatable, Sendable {
  public let level: SDKLogLevel
  public let category: String
  public let message: String
  public let metadata: [String: SDKLogMetadataValue]

  public init(
    level: SDKLogLevel,
    category: String,
    message: String,
    metadata: [String: SDKLogMetadataValue] = [:]
  ) {
    self.level = level
    self.category = category
    self.message = message
    self.metadata = metadata
  }
}

/// A fully redacted record safe to hand to an application log sink.
public struct SDKLogRecord: Codable, Equatable, Sendable {
  public let timestampMilliseconds: Int64
  public let level: SDKLogLevel
  public let category: String
  public let message: String
  public let metadata: [String: String]

  public init(
    timestampMilliseconds: Int64,
    level: SDKLogLevel,
    category: String,
    message: String,
    metadata: [String: String]
  ) {
    self.timestampMilliseconds = timestampMilliseconds
    self.level = level
    self.category = category
    self.message = message
    self.metadata = metadata
  }

  private enum CodingKeys: String, CodingKey {
    case timestampMilliseconds = "timestamp_ms"
    case level
    case category
    case message
    case metadata
  }
}

/// Injectable logging boundary used by SDK services.
public protocol SDKLogging: Sendable {
  func log(_ event: SDKLogEvent)
}

/// A logger that discards all events.
public struct NoopSDKLogger: SDKLogging {
  public init() {}

  public func log(_: SDKLogEvent) {}
}

/// Converts events into redacted records before invoking an application-owned sink.
public struct RedactingSDKLogger: SDKLogging {
  private let clock: any SDKClock
  private let redactor: SensitiveDataRedactor
  private let sink: @Sendable (SDKLogRecord) -> Void

  public init(
    clock: any SDKClock = SystemSDKClock(),
    redactor: SensitiveDataRedactor = SensitiveDataRedactor(),
    sink: @escaping @Sendable (SDKLogRecord) -> Void
  ) {
    self.clock = clock
    self.redactor = redactor
    self.sink = sink
  }

  public func log(_ event: SDKLogEvent) {
    let metadata = event.metadata.mapValues { value in
      redactor.redact(value.value, as: value.privacy)
    }
    sink(
      SDKLogRecord(
        timestampMilliseconds: clock.nowMilliseconds(),
        level: event.level,
        category: redactor.redact(message: event.category),
        message: redactor.redact(message: event.message),
        metadata: metadata
      ))
  }
}

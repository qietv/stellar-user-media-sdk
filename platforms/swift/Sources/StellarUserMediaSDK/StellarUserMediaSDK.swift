import StellarCore
import StellarMediaLibrary
import StellarRemoteMedia

/// Compatibility aliases exposed by the umbrella SDK module.
public typealias SDKError = StellarCore.SDKError
/// Compatibility alias for the stable SDK error code.
public typealias SDKErrorCode = StellarCore.SDKErrorCode
/// Compatibility alias for Unix epoch milliseconds.
public typealias EpochMilliseconds = StellarCore.EpochMilliseconds
/// Compatibility alias that distinguishes a missing field from an explicit null.
public typealias FieldPresence<Value: Sendable> = StellarCore.FieldPresence<Value>
/// Compatibility alias for cursor-paginated wire results.
public typealias CursorPage<Element: Codable & Sendable> = StellarCore.CursorPage<Element>
/// Compatibility alias for the injectable SDK clock.
public typealias SDKClock = StellarCore.SDKClock
/// Compatibility alias for the live system clock.
public typealias SystemSDKClock = StellarCore.SystemSDKClock
/// Compatibility alias for injectable UUID generation.
public typealias SDKUUIDGenerating = StellarCore.SDKUUIDGenerating
/// Compatibility alias for the live UUID generator.
public typealias SystemSDKUUIDGenerator = StellarCore.SystemSDKUUIDGenerator
/// Compatibility alias for cooperative cancellation checks.
public typealias SDKCancellationChecking = StellarCore.SDKCancellationChecking
/// Compatibility alias for Swift task cancellation.
public typealias TaskCancellationChecker = StellarCore.TaskCancellationChecker
/// Compatibility alias for work without an external cancellation owner.
public typealias NeverCancelledChecker = StellarCore.NeverCancelledChecker
/// Compatibility alias for the core runtime dependency container.
public typealias SDKRuntimeDependencies = StellarCore.SDKRuntimeDependencies
/// Compatibility alias for structured log privacy treatment.
public typealias SDKLogPrivacy = StellarCore.SDKLogPrivacy
/// Compatibility alias for the shared sensitive-data redactor.
public typealias SensitiveDataRedactor = StellarCore.SensitiveDataRedactor
/// Compatibility alias for SDK log severity.
public typealias SDKLogLevel = StellarCore.SDKLogLevel
/// Compatibility alias for a privacy-annotated log metadata value.
public typealias SDKLogMetadataValue = StellarCore.SDKLogMetadataValue
/// Compatibility alias for an SDK diagnostic event.
public typealias SDKLogEvent = StellarCore.SDKLogEvent
/// Compatibility alias for a redacted log record.
public typealias SDKLogRecord = StellarCore.SDKLogRecord
/// Compatibility alias for the injectable logging boundary.
public typealias SDKLogging = StellarCore.SDKLogging
/// Compatibility alias for a logger that discards events.
public typealias NoopSDKLogger = StellarCore.NoopSDKLogger
/// Compatibility alias for the privacy-enforcing logger.
public typealias RedactingSDKLogger = StellarCore.RedactingSDKLogger
/// Compatibility alias for deterministic retry policy.
public typealias RetryPolicy = StellarCore.RetryPolicy
/// Compatibility alias for retry execution.
public typealias RetryExecutor = StellarCore.RetryExecutor
/// Compatibility alias for the encrypted credential category.
public typealias CredentialKind = StellarRemoteMedia.CredentialKind
/// Compatibility alias for the encrypted credential wire envelope.
public typealias EncryptedCredentialEnvelope = StellarRemoteMedia.EncryptedCredentialEnvelope
/// Compatibility alias for the parsed media category.
public typealias ParsedMediaKind = StellarMediaLibrary.ParsedMediaKind
/// Compatibility alias for a normalized filename parse result.
public typealias ParsedMediaFilename = StellarMediaLibrary.ParsedMediaFilename
/// Compatibility alias for the deterministic filename parser.
public typealias MediaFilenameParser = StellarMediaLibrary.MediaFilenameParser

/// The public namespace for SDK-wide information.
public enum StellarUserMediaSDK: Sendable {
  /// The semantic version of the first development package.
  public static let version = "0.1.0-dev"
}

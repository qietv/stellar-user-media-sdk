import StellarCore
import StellarMediaLibrary
import StellarRemoteMedia

/// Compatibility aliases exposed by the umbrella SDK module.
public typealias SDKError = StellarCore.SDKError
public typealias SDKErrorCode = StellarCore.SDKErrorCode
public typealias EpochMilliseconds = StellarCore.EpochMilliseconds
public typealias FieldPresence<Value: Sendable> = StellarCore.FieldPresence<Value>
public typealias CursorPage<Element: Codable & Sendable> = StellarCore.CursorPage<Element>
public typealias SDKClock = StellarCore.SDKClock
public typealias SystemSDKClock = StellarCore.SystemSDKClock
public typealias SDKUUIDGenerating = StellarCore.SDKUUIDGenerating
public typealias SystemSDKUUIDGenerator = StellarCore.SystemSDKUUIDGenerator
public typealias SDKCancellationChecking = StellarCore.SDKCancellationChecking
public typealias TaskCancellationChecker = StellarCore.TaskCancellationChecker
public typealias NeverCancelledChecker = StellarCore.NeverCancelledChecker
public typealias SDKRuntimeDependencies = StellarCore.SDKRuntimeDependencies
public typealias SDKLogPrivacy = StellarCore.SDKLogPrivacy
public typealias SensitiveDataRedactor = StellarCore.SensitiveDataRedactor
public typealias SDKLogLevel = StellarCore.SDKLogLevel
public typealias SDKLogMetadataValue = StellarCore.SDKLogMetadataValue
public typealias SDKLogEvent = StellarCore.SDKLogEvent
public typealias SDKLogRecord = StellarCore.SDKLogRecord
public typealias SDKLogging = StellarCore.SDKLogging
public typealias NoopSDKLogger = StellarCore.NoopSDKLogger
public typealias RedactingSDKLogger = StellarCore.RedactingSDKLogger
public typealias RetryPolicy = StellarCore.RetryPolicy
public typealias RetryExecutor = StellarCore.RetryExecutor
public typealias CredentialKind = StellarRemoteMedia.CredentialKind
public typealias EncryptedCredentialEnvelope = StellarRemoteMedia.EncryptedCredentialEnvelope
public typealias ParsedMediaKind = StellarMediaLibrary.ParsedMediaKind
public typealias ParsedMediaFilename = StellarMediaLibrary.ParsedMediaFilename
public typealias MediaFilenameParser = StellarMediaLibrary.MediaFilenameParser

/// The public namespace for SDK-wide information.
public enum StellarUserMediaSDK: Sendable {
  /// The semantic version of the first development package.
  public static let version = "0.1.0-dev"
}

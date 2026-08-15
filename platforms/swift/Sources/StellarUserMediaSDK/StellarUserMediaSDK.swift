import StellarCore
import StellarLocalMedia
import StellarMediaLibrary
import StellarRemoteMedia
import StellarWebDAV

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
/// Compatibility alias for source path case-sensitivity semantics.
public typealias RemotePathCaseSensitivity = StellarRemoteMedia.RemotePathCaseSensitivity
/// Compatibility alias for source Unicode normalization semantics.
public typealias RemoteUnicodeNormalization = StellarRemoteMedia.RemoteUnicodeNormalization
/// Compatibility alias for source path comparison semantics.
public typealias RemotePathSemantics = StellarRemoteMedia.RemotePathSemantics
/// Compatibility alias for a normalized source-relative path.
public typealias RemotePath = StellarRemoteMedia.RemotePath
/// Compatibility alias for a source-qualified remote locator.
public typealias RemoteLocator = StellarRemoteMedia.RemoteLocator
/// Compatibility alias for remote stable-ID lifetime.
public typealias RemoteStableIDScope = StellarRemoteMedia.RemoteStableIDScope
/// Compatibility alias for source enumeration capabilities.
public typealias MediaSourceCapabilities = StellarRemoteMedia.MediaSourceCapabilities
/// Compatibility alias for a source-independent entry kind.
public typealias RemoteEntryKind = StellarRemoteMedia.RemoteEntryKind
/// Compatibility alias for a source-independent read-only entry.
public typealias RemoteEntry = StellarRemoteMedia.RemoteEntry
/// Compatibility alias for a cursor-paginated directory request.
public typealias RemoteDirectoryPageRequest = StellarRemoteMedia.RemoteDirectoryPageRequest
/// Compatibility alias for a source-independent byte range.
public typealias RemoteByteRange = StellarRemoteMedia.RemoteByteRange
/// Compatibility alias for a connected read-only source.
public typealias MediaSourceSession = StellarRemoteMedia.MediaSourceSession
/// Compatibility alias for the shared connector boundary.
public typealias MediaSourceConnector = StellarRemoteMedia.MediaSourceConnector
/// Compatibility alias for local directory source configuration.
public typealias LocalMediaSourceConfiguration = StellarLocalMedia.LocalMediaSourceConfiguration
/// Compatibility alias for the local directory connector.
public typealias LocalMediaSourceConnector = StellarLocalMedia.LocalMediaSourceConnector
/// Compatibility alias for a connected local directory session.
public typealias LocalMediaSourceSession = StellarLocalMedia.LocalMediaSourceSession
/// Compatibility alias for ephemeral WebDAV credentials.
public typealias WebDAVCredential = StellarWebDAV.WebDAVCredential
/// Compatibility alias for WebDAV source configuration.
public typealias WebDAVMediaSourceConfiguration = StellarWebDAV.WebDAVMediaSourceConfiguration
/// Compatibility alias for a redacted WebDAV HTTP request.
public typealias WebDAVHTTPRequest = StellarWebDAV.WebDAVHTTPRequest
/// Compatibility alias for a WebDAV HTTP response.
public typealias WebDAVHTTPResponse = StellarWebDAV.WebDAVHTTPResponse
/// Compatibility alias for the injectable WebDAV HTTP boundary.
public typealias WebDAVTransport = StellarWebDAV.WebDAVTransport
/// Compatibility alias for the live URLSession WebDAV transport.
public typealias URLSessionWebDAVTransport = StellarWebDAV.URLSessionWebDAVTransport
/// Compatibility alias for the WebDAV media connector.
public typealias WebDAVMediaSourceConnector = StellarWebDAV.WebDAVMediaSourceConnector
/// Compatibility alias for a connected WebDAV media session.
public typealias WebDAVMediaSourceSession = StellarWebDAV.WebDAVMediaSourceSession
/// Compatibility alias for scanner run modes.
public typealias MediaScanMode = StellarMediaLibrary.MediaScanMode
/// Compatibility alias for scanner state-machine phases.
public typealias MediaScanPhase = StellarMediaLibrary.MediaScanPhase
/// Compatibility alias for a stable scanner request.
public typealias MediaScanRequest = StellarMediaLibrary.MediaScanRequest
/// Compatibility alias for a resumable scanner page cursor.
public typealias MediaScanPageCursor = StellarMediaLibrary.MediaScanPageCursor
/// Compatibility alias for scanner root preflight identity.
public typealias MediaScanRootIdentity = StellarMediaLibrary.MediaScanRootIdentity
/// Compatibility alias for a durable scanner checkpoint.
public typealias MediaScanCheckpoint = StellarMediaLibrary.MediaScanCheckpoint
/// Compatibility alias for the authoritative completion boundary.
public typealias MediaScanCompletion = StellarMediaLibrary.MediaScanCompletion
/// Compatibility alias for one atomic scanner persistence batch.
public typealias MediaScanBatch = StellarMediaLibrary.MediaScanBatch
/// Compatibility alias for scanner persistence.
public typealias MediaScanSink = StellarMediaLibrary.MediaScanSink
/// Compatibility alias for scanner progress event categories.
public typealias MediaScanEventKind = StellarMediaLibrary.MediaScanEventKind
/// Compatibility alias for a path-free scanner progress event.
public typealias MediaScanEvent = StellarMediaLibrary.MediaScanEvent
/// Compatibility alias for scanner progress observation.
public typealias MediaScanObserver = StellarMediaLibrary.MediaScanObserver
/// Compatibility alias for a no-op scanner observer.
public typealias NoopMediaScanObserver = StellarMediaLibrary.NoopMediaScanObserver
/// Compatibility alias for bounded scanner configuration.
public typealias MediaScannerConfiguration = StellarMediaLibrary.MediaScannerConfiguration
/// Compatibility alias for a completed scanner result.
public typealias MediaScanResult = StellarMediaLibrary.MediaScanResult
/// Compatibility alias for the source-independent scanner.
public typealias MediaScanner = StellarMediaLibrary.MediaScanner
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

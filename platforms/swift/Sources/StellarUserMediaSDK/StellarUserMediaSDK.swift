import StellarAuth
import StellarCore
import StellarLocalMedia
import StellarMediaLibrary
import StellarPosterWall
import StellarRemoteMedia
import StellarStorage
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
/// Compatibility alias for observable OAuth session states.
public typealias OAuthSessionState = StellarAuth.OAuthSessionState
/// Compatibility alias for the non-secret Stellar account session.
public typealias UserSession = StellarAuth.UserSession
/// Compatibility alias for non-secret OAuth session events.
public typealias OAuthSessionEvent = StellarAuth.OAuthSessionEvent
/// Compatibility alias for a trusted Stellar OAuth deployment profile.
public typealias StellarOAuthConfiguration = StellarAuth.StellarOAuthConfiguration
/// Compatibility alias for device-bound OAuth token accessibility.
public typealias OAuthTokenAccessibility = StellarAuth.OAuthTokenAccessibility
/// Compatibility alias for a system-browser authorization presentation request.
public typealias OAuthAuthorizationPresentationRequest =
  StellarAuth.OAuthAuthorizationPresentationRequest
/// Compatibility alias for the host-provided system-browser authorization boundary.
public typealias OAuthAuthorizationPresenting = StellarAuth.OAuthAuthorizationPresenting
/// Compatibility alias for a closure-backed system-browser authorization presenter.
public typealias ClosureOAuthAuthorizationPresenter = StellarAuth.ClosureOAuthAuthorizationPresenter
/// Compatibility alias for Apple system-browser OAuth presentation.
public typealias AppleWebAuthenticationSessionPresenter =
  StellarAuth.AppleWebAuthenticationSessionPresenter
/// Compatibility alias for the actor-isolated Stellar OAuth coordinator.
public typealias OAuthSessionManager = StellarAuth.OAuthSessionManager
/// Compatibility alias for the synchronized credential category.
public typealias CredentialKind = StellarRemoteMedia.CredentialKind
/// Compatibility alias for credential payload protection metadata.
public typealias CredentialProtectionMode = StellarRemoteMedia.CredentialProtectionMode
/// Compatibility alias for strict credential payload authentication types.
public typealias CredentialAuthenticationType = StellarRemoteMedia.CredentialAuthenticationType
/// Compatibility alias for a bounded synchronized HTTP cookie.
public typealias CredentialCookie = StellarRemoteMedia.CredentialCookie
/// Compatibility alias for a strict, redacted plaintext credential payload.
public typealias CredentialPayload = StellarRemoteMedia.CredentialPayload
/// Compatibility alias for the synchronized credential record.
public typealias CredentialRecord = StellarRemoteMedia.CredentialRecord
/// Compatibility alias for synchronized media-source categories.
public typealias MediaSourceKind = StellarRemoteMedia.MediaSourceKind
/// Compatibility alias for synchronized source connection routing.
public typealias MediaSourceConnectionMode = StellarRemoteMedia.MediaSourceConnectionMode
/// Compatibility alias for synchronized source credential resolution.
public typealias MediaSourceCredentialMode = StellarRemoteMedia.MediaSourceCredentialMode
/// Compatibility alias for synchronized source capabilities.
public typealias MediaSourceCapability = StellarRemoteMedia.MediaSourceCapability
/// Compatibility alias for a non-secret synchronized source endpoint.
public typealias MediaSourceEndpoint = StellarRemoteMedia.MediaSourceEndpoint
/// Compatibility alias for synchronized source scan scheduling.
public typealias MediaSourceScanPolicy = StellarRemoteMedia.MediaSourceScanPolicy
/// Compatibility alias for synchronized source metadata preferences.
public typealias MediaSourceMetadataPolicy = StellarRemoteMedia.MediaSourceMetadataPolicy
/// Compatibility alias for the synchronized media-source configuration.
public typealias MediaSourceConfig = StellarRemoteMedia.MediaSourceConfig
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
/// Compatibility alias for the GRDB-backed scanner sink.
public typealias SQLiteMediaScanSink = StellarMediaLibrary.SQLiteMediaScanSink
/// Compatibility alias for the parsed media category.
public typealias ParsedMediaKind = StellarMediaLibrary.ParsedMediaKind
/// Compatibility alias for a normalized filename parse result.
public typealias ParsedMediaFilename = StellarMediaLibrary.ParsedMediaFilename
/// Compatibility alias for a provider ID embedded in a filename.
public typealias FilenameProviderHint = StellarMediaLibrary.FilenameProviderHint
/// Compatibility alias for explainable filename matching evidence.
public typealias MediaFilenameEvidence = StellarMediaLibrary.MediaFilenameEvidence
/// Compatibility alias for a parsed filename and its matching evidence.
public typealias MediaFilenameAnalysis = StellarMediaLibrary.MediaFilenameAnalysis
/// Compatibility alias for the deterministic filename parser.
public typealias MediaFilenameParser = StellarMediaLibrary.MediaFilenameParser
/// Compatibility alias for a classified media sidecar kind.
public typealias MediaSidecarKind = StellarMediaLibrary.MediaSidecarKind
/// Compatibility alias for one normalized media sidecar association.
public typealias MediaSidecarDescriptor = StellarMediaLibrary.MediaSidecarDescriptor
/// Compatibility alias for deterministic media sidecar classification.
public typealias MediaSidecarClassifier = StellarMediaLibrary.MediaSidecarClassifier
/// Compatibility alias for an external identifier found in local metadata.
public typealias LocalMetadataExternalID = StellarMediaLibrary.LocalMetadataExternalID
/// Compatibility alias for a local metadata artwork category.
public typealias LocalMetadataArtworkKind = StellarMediaLibrary.LocalMetadataArtworkKind
/// Compatibility alias for a deferred local metadata artwork reference.
public typealias LocalMetadataArtwork = StellarMediaLibrary.LocalMetadataArtwork
/// Compatibility alias for normalized local metadata.
public typealias LocalMetadataDocument = StellarMediaLibrary.LocalMetadataDocument
/// Compatibility alias for the bounded NFO parser.
public typealias NFOParser = StellarMediaLibrary.NFOParser
/// Compatibility alias for the bounded local JSON metadata parser.
public typealias LocalMetadataJSONParser = StellarMediaLibrary.LocalMetadataJSONParser
/// Compatibility alias for one classified and parsed sidecar.
public typealias MediaSidecarIntake = StellarMediaLibrary.MediaSidecarIntake
/// Compatibility alias for one file's complete local metadata intake.
public typealias MediaMetadataIntakeBatch = StellarMediaLibrary.MediaMetadataIntakeBatch
/// Compatibility alias for atomic SQLite local-metadata persistence.
public typealias SQLiteMediaMetadataStore = StellarMediaLibrary.SQLiteMediaMetadataStore
/// Compatibility alias for a source-independent technical probe request.
public typealias MediaTechnicalProbeRequest = StellarMediaLibrary.MediaTechnicalProbeRequest
/// Compatibility alias for the compact technical media summary.
public typealias MediaTechnicalSummary = StellarMediaLibrary.MediaTechnicalSummary
/// Compatibility alias for a normalized media stream category.
public typealias MediaTechnicalStreamKind = StellarMediaLibrary.MediaTechnicalStreamKind
/// Compatibility alias for one normalized media stream.
public typealias MediaTechnicalStream = StellarMediaLibrary.MediaTechnicalStream
/// Compatibility alias for one complete technical probe result.
public typealias MediaTechnicalProbeResult = StellarMediaLibrary.MediaTechnicalProbeResult
/// Compatibility alias for the injectable technical probing boundary.
public typealias MediaTechnicalProbing = StellarMediaLibrary.MediaTechnicalProbing
/// Compatibility alias for a season/episode coordinate used during provider matching.
public typealias MediaEpisodeCoordinate = StellarMediaLibrary.MediaEpisodeCoordinate
/// Compatibility alias for a normalized metadata provider query.
public typealias MediaMatchQuery = StellarMediaLibrary.MediaMatchQuery
/// Compatibility alias for local-evidence metadata query generation.
public typealias MediaMatchQueryBuilder = StellarMediaLibrary.MediaMatchQueryBuilder
/// Compatibility alias for a provider metadata candidate.
public typealias MediaMetadataCandidate = StellarMediaLibrary.MediaMetadataCandidate
/// Compatibility alias for the injectable metadata provider boundary.
public typealias MediaMetadataProviding = StellarMediaLibrary.MediaMetadataProviding
/// Compatibility alias for a redacted TMDB application credential.
public typealias TMDBCredential = StellarMediaLibrary.TMDBCredential
/// Compatibility alias for bounded TMDB locale and search policy.
public typealias TMDBProviderConfiguration = StellarMediaLibrary.TMDBProviderConfiguration
/// Compatibility alias for a redacted TMDB transport request.
public typealias TMDBHTTPRequest = StellarMediaLibrary.TMDBHTTPRequest
/// Compatibility alias for a bounded TMDB transport response.
public typealias TMDBHTTPResponse = StellarMediaLibrary.TMDBHTTPResponse
/// Compatibility alias for the injectable TMDB transport boundary.
public typealias TMDBTransport = StellarMediaLibrary.TMDBTransport
/// Compatibility alias for the live URLSession TMDB transport.
public typealias URLSessionTMDBTransport = StellarMediaLibrary.URLSessionTMDBTransport
/// Compatibility alias for normalized TMDB artwork metadata.
public typealias TMDBArtworkImage = StellarMediaLibrary.TMDBArtworkImage
/// Compatibility alias for normalized TMDB media details.
public typealias TMDBMediaDetails = StellarMediaLibrary.TMDBMediaDetails
/// Compatibility alias for TMDB image host and size configuration.
public typealias TMDBImageConfiguration = StellarMediaLibrary.TMDBImageConfiguration
/// Compatibility alias for the concrete TMDB metadata adapter.
public typealias TMDBMetadataProvider = StellarMediaLibrary.TMDBMetadataProvider
/// Compatibility alias for a metadata match policy decision.
public typealias MediaMatchDecision = StellarMediaLibrary.MediaMatchDecision
/// Compatibility alias for a deterministic metadata scoring signal.
public typealias MediaMatchSignal = StellarMediaLibrary.MediaMatchSignal
/// Compatibility alias for a scored provider metadata candidate.
public typealias ScoredMediaMetadataCandidate = StellarMediaLibrary.ScoredMediaMetadataCandidate
/// Compatibility alias for metadata match scoring thresholds.
public typealias MediaMatchScoringPolicy = StellarMediaLibrary.MediaMatchScoringPolicy
/// Compatibility alias for the deterministic metadata candidate scorer.
public typealias MediaMetadataCandidateScorer = StellarMediaLibrary.MediaMetadataCandidateScorer
/// Compatibility alias for a file's role in a logical media entity.
public typealias MediaMatchBindingRole = StellarMediaLibrary.MediaMatchBindingRole
/// Compatibility alias for the evidence source behind a persisted match.
public typealias MediaMatchMethod = StellarMediaLibrary.MediaMatchMethod
/// Compatibility alias for a stable file-to-entity binding projection.
public typealias MediaFileMatchBinding = StellarMediaLibrary.MediaFileMatchBinding
/// Compatibility alias for a persisted metadata match state transition.
public typealias MediaMatchPersistenceState = StellarMediaLibrary.MediaMatchPersistenceState
/// Compatibility alias for a persisted metadata match result.
public typealias MediaMatchPersistenceResult = StellarMediaLibrary.MediaMatchPersistenceResult
/// Compatibility alias for SQLite-backed matching, review, and binding persistence.
public typealias SQLiteMediaMatcher = StellarMediaLibrary.SQLiteMediaMatcher
/// Compatibility alias for a top-level PosterWall media kind.
public typealias PosterWallMediaKind = StellarPosterWall.PosterWallMediaKind
/// Compatibility alias for a PosterWall section.
public typealias PosterWallSection = StellarPosterWall.PosterWallSection
/// Compatibility alias for deterministic PosterWall sorting.
public typealias PosterWallSort = StellarPosterWall.PosterWallSort
/// Compatibility alias for PosterWall availability filtering.
public typealias PosterWallAvailabilityFilter = StellarPosterWall.PosterWallAvailabilityFilter
/// Compatibility alias for PosterWall playback-state filtering.
public typealias PosterWallWatchFilter = StellarPosterWall.PosterWallWatchFilter
/// Compatibility alias for aggregated media availability.
public typealias PosterWallAvailability = StellarPosterWall.PosterWallAvailability
/// Compatibility alias for reusable PosterWall filters.
public typealias PosterWallFilter = StellarPosterWall.PosterWallFilter
/// Compatibility alias for a validated PosterWall query.
public typealias PosterWallQuery = StellarPosterWall.PosterWallQuery
/// Compatibility alias for selected PosterWall artwork.
public typealias PosterWallArtwork = StellarPosterWall.PosterWallArtwork
/// Compatibility alias for a PosterWall list item.
public typealias PosterWallItem = StellarPosterWall.PosterWallItem
/// Compatibility alias for a revision-bound PosterWall page.
public typealias PosterWallPage = StellarPosterWall.PosterWallPage
/// Compatibility alias for a normalized media stream.
public typealias PosterWallStream = StellarPosterWall.PosterWallStream
/// Compatibility alias for a playable media file projection.
public typealias PosterWallPlayableFile = StellarPosterWall.PosterWallPlayableFile
/// Compatibility alias for one episode in PosterWall details.
public typealias PosterWallEpisode = StellarPosterWall.PosterWallEpisode
/// Compatibility alias for one season in PosterWall details.
public typealias PosterWallSeason = StellarPosterWall.PosterWallSeason
/// Compatibility alias for a provider external identity.
public typealias PosterWallExternalID = StellarPosterWall.PosterWallExternalID
/// Compatibility alias for complete PosterWall media details.
public typealias PosterWallDetails = StellarPosterWall.PosterWallDetails
/// Compatibility alias for SQLite-backed PosterWall queries.
public typealias PosterWallStore = StellarPosterWall.PosterWallStore
/// Compatibility alias for one artwork cache variant request.
public typealias PosterWallArtworkVariantRequest =
  StellarPosterWall.PosterWallArtworkVariantRequest
/// Compatibility alias for one regenerable artwork cache record.
public typealias PosterWallArtworkCacheRecord = StellarPosterWall.PosterWallArtworkCacheRecord
/// Compatibility alias for a replaceable artwork cache index.
public typealias PosterWallArtworkCacheIndexing =
  StellarPosterWall.PosterWallArtworkCacheIndexing
/// Compatibility alias for the ephemeral artwork cache index.
public typealias InMemoryPosterWallArtworkCacheIndex =
  StellarPosterWall.InMemoryPosterWallArtworkCacheIndex
/// Compatibility alias for artwork prefetch policy integration.
public typealias PosterWallArtworkPrefetching = StellarPosterWall.PosterWallArtworkPrefetching
/// Compatibility alias for a prefetcher that performs no work.
public typealias NoopPosterWallArtworkPrefetcher =
  StellarPosterWall.NoopPosterWallArtworkPrefetcher
/// Compatibility alias for a versioned local database kind.
public typealias StorageDatabaseKind = StellarStorage.StorageDatabaseKind
/// Compatibility alias for an opened and migrated SQLite database.
public typealias StorageDatabase = StellarStorage.StorageDatabase
/// Compatibility alias for SQLite integrity and migration verification.
public typealias StorageVerificationReport = StellarStorage.StorageVerificationReport
/// Compatibility alias for the credential and account outbox repository.
public typealias AccountStore = StellarStorage.AccountStore
/// Compatibility alias for the disposable provider and matching cache repository.
public typealias MetadataCacheStore = StellarStorage.MetadataCacheStore
/// Compatibility alias for non-secret account outbox metadata.
public typealias AccountOutboxRecord = StellarStorage.AccountOutboxRecord
/// Compatibility alias for media-source kinds stored in library.sqlite.
public typealias LibrarySourceKind = StellarStorage.LibrarySourceKind
/// Compatibility alias for non-secret library source metadata.
public typealias LibrarySourceDefinition = StellarStorage.LibrarySourceDefinition
/// Compatibility alias for the scanner-oriented library repository.
public typealias LibraryStore = StellarStorage.LibraryStore
/// Compatibility alias for a deterministic library database projection.
public typealias LibrarySnapshot = StellarStorage.LibrarySnapshot
/// Compatibility alias for one normalized persisted file fact.
public typealias LibraryFileFact = StellarStorage.LibraryFileFact

/// The public namespace for SDK-wide information.
public enum StellarUserMediaSDK: Sendable {
  /// The semantic version of the first development package.
  public static let version = "0.1.0-dev"
}

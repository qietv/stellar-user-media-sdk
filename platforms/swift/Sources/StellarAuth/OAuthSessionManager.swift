import Foundation
import StellarCore

/// Actor-isolated OAuth coordinator for login, restoration, refresh, account switching, and logout.
public actor OAuthSessionManager {
  public private(set) var state: OAuthSessionState = .signedOut

  private struct AccessToken: Sendable {
    let value: String
    let expiresAtMilliseconds: Int64
  }

  private struct RefreshResult: Sendable {
    let credential: StoredOAuthCredential
    let accessToken: AccessToken
  }

  private struct RefreshFlight: Sendable {
    let id: UUID
    let generation: UInt64
    let task: Task<RefreshResult, Error>
  }

  private let configuration: StellarOAuthConfiguration
  private let authorizationPresenter: any OAuthAuthorizationPresenting
  private let protocolClient: GatewayOAuthProtocolClient
  private let credentialStore: any OAuthCredentialStoring
  private let random: any OAuthRandomGenerating
  private let clock: any SDKClock
  private let uuidGenerator: any SDKUUIDGenerating

  private var metadata: OAuthServerMetadata?
  private var activeCredential: StoredOAuthCredential?
  private var accessToken: AccessToken?
  private var refreshFlight: RefreshFlight?
  private var generation: UInt64 = 0
  private var accountsSigningOut: Set<String> = []
  private var eventContinuations: [UUID: AsyncStream<OAuthSessionEvent>.Continuation] = [:]

  public init(
    configuration: StellarOAuthConfiguration,
    authorizationPresenter: any OAuthAuthorizationPresenting,
    tokenAccessibility: OAuthTokenAccessibility = .whenUnlockedThisDeviceOnly,
    runtime: SDKRuntimeDependencies = .live
  ) {
    let transport = URLSessionOAuthHTTPTransport()
    self.configuration = configuration
    self.authorizationPresenter = authorizationPresenter
    protocolClient = GatewayOAuthProtocolClient(
      configuration: configuration,
      transport: transport,
      clock: runtime.clock
    )
    credentialStore = KeychainOAuthCredentialStore(
      configuration: configuration,
      accessibility: tokenAccessibility
    )
    random = SystemOAuthRandomGenerator()
    clock = runtime.clock
    uuidGenerator = runtime.uuidGenerator
  }

  init(
    configuration: StellarOAuthConfiguration,
    authorizationPresenter: any OAuthAuthorizationPresenting,
    transport: any OAuthHTTPTransport,
    credentialStore: any OAuthCredentialStoring,
    random: any OAuthRandomGenerating,
    clock: any SDKClock,
    uuidGenerator: any SDKUUIDGenerating
  ) {
    self.configuration = configuration
    self.authorizationPresenter = authorizationPresenter
    protocolClient = GatewayOAuthProtocolClient(
      configuration: configuration,
      transport: transport,
      clock: clock
    )
    self.credentialStore = credentialStore
    self.random = random
    self.clock = clock
    self.uuidGenerator = uuidGenerator
  }

  /// Returns a stream of non-secret session and account events.
  public func events() -> AsyncStream<OAuthSessionEvent> {
    let identifier = UUID()
    return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
      eventContinuations[identifier] = continuation
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeEventContinuation(identifier) }
      }
    }
  }

  /// Restores the active account from secure storage and obtains a fresh access token.
  @discardableResult
  public func restoreSession() async throws -> UserSession? {
    try requireIdleOperation()
    let credentials: [StoredOAuthCredential]
    let activeAccountUID: String?
    do {
      credentials = try await credentialStore.credentials()
      activeAccountUID = try await credentialStore.activeAccountUID()
    } catch {
      throw publicError(error)
    }
    guard !credentials.isEmpty else {
      activeCredential = nil
      accessToken = nil
      transition(to: .signedOut)
      return nil
    }
    let credential =
      activeAccountUID.flatMap { activeUID in
        credentials.first { $0.session.accountUID == activeUID }
      } ?? credentials.first!
    if activeAccountUID != credential.session.accountUID {
      try await credentialStore.setActiveAccountUID(credential.session.accountUID)
    }
    try await ensureMetadata()
    generation &+= 1
    activeCredential = credential
    accessToken = nil
    transition(to: .refreshing(credential.session))
    do {
      _ = try await refreshAccessToken()
      return activeCredential?.session
    } catch {
      throw publicError(error)
    }
  }

  /// Starts Authorization Code + PKCE in the injected system-browser presenter.
  @discardableResult
  public func signIn() async throws -> UserSession {
    try requireIdleOperation()
    let previousState = state
    let previousAccountUID = state.session?.accountUID
    generation &+= 1
    let operationGeneration = generation
    refreshFlight?.task.cancel()
    refreshFlight = nil
    transition(to: .authorizing)

    do {
      let metadata = try await ensureMetadata()
      try ensureCurrentGeneration(operationGeneration)
      let endpoint = try authorizationEndpoint(metadata)
      let attempt = try OAuthAuthorizationBuilder.makeAttempt(
        endpoint: endpoint,
        configuration: configuration,
        random: random
      )
      let callbackURL = try await authorizationPresenter.authorize(attempt.presentationRequest)
      try ensureCurrentGeneration(operationGeneration)
      let code = try OAuthAuthorizationBuilder.authorizationCode(
        from: callbackURL,
        redirectURI: configuration.redirectURI,
        expectedState: attempt.state
      )
      let bundle = try await protocolClient.exchangeAuthorizationCode(
        code,
        verifier: attempt.verifier,
        metadata: metadata
      )
      try ensureCurrentGeneration(operationGeneration)
      let remoteProfile: OAuthRemoteProfile
      do {
        remoteProfile = try await protocolClient.profile(accessToken: bundle.accessToken)
      } catch {
        try? await protocolClient.revoke(refreshToken: bundle.refreshToken, metadata: metadata)
        throw error
      }
      try ensureCurrentGeneration(operationGeneration)
      let session = try makeSession(profile: remoteProfile, token: bundle)
      let credential = try StoredOAuthCredential(
        configuration: configuration,
        session: session,
        refreshToken: bundle.refreshToken
      )
      let priorCredential = try await credentialStore.credentials().first {
        $0.session.accountUID == session.accountUID
      }
      try ensureCurrentGeneration(operationGeneration)
      do {
        try await credentialStore.save(credential)
        try await credentialStore.setActiveAccountUID(session.accountUID)
      } catch {
        try? await protocolClient.revoke(refreshToken: bundle.refreshToken, metadata: metadata)
        throw error
      }
      try ensureCurrentGeneration(operationGeneration)
      if let priorCredential, priorCredential.refreshToken != bundle.refreshToken {
        try? await protocolClient.revoke(
          refreshToken: priorCredential.refreshToken,
          metadata: metadata
        )
      }
      try ensureCurrentGeneration(operationGeneration)
      activeCredential = credential
      accessToken = AccessToken(
        value: bundle.accessToken,
        expiresAtMilliseconds: bundle.expiresAtMilliseconds
      )
      transition(to: .signedIn(session))
      if previousAccountUID != session.accountUID {
        emit(.activeAccountChanged, accountUID: session.accountUID)
      }
      emit(.profileChanged, accountUID: session.accountUID)
      return session
    } catch {
      if generation == operationGeneration {
        state = previousState
        emit(.sessionStateChanged, accountUID: previousState.session?.accountUID)
      }
      throw publicError(error)
    }
  }

  /// Returns an access token with at least the requested remaining lifetime.
  public func getAccessToken(minValidityMilliseconds: Int64 = 0) async throws -> String {
    guard (0...900_000).contains(minValidityMilliseconds) else {
      throw SDKError(
        code: .invalidConfiguration,
        message: "OAuth access token minimum validity is invalid"
      )
    }
    guard activeCredential != nil else {
      throw SDKError(code: .unauthorized, message: "No active OAuth account")
    }
    if case .needsReauthentication = state {
      throw SDKError(code: .unauthorized, message: "OAuth reauthentication is required")
    }
    if case .signingOut = state {
      throw SDKError(code: .unauthorized, message: "OAuth account is signing out")
    }
    let requiredValidity = max(minValidityMilliseconds, configuration.refreshLeewayMilliseconds)
    let now = clock.nowMilliseconds()
    if now >= 0, let accessToken,
      requiredValidity <= Int64.max - now,
      accessToken.expiresAtMilliseconds >= now + requiredValidity
    {
      return accessToken.value
    }
    do {
      let token = try await refreshAccessToken()
      let now = clock.nowMilliseconds()
      guard now >= 0, let accessToken,
        minValidityMilliseconds <= Int64.max - now,
        accessToken.expiresAtMilliseconds >= now + minValidityMilliseconds
      else {
        throw SDKError(
          code: .remoteUnavailable,
          message: "OAuth access token validity is shorter than requested"
        )
      }
      return token
    } catch {
      throw publicError(error)
    }
  }

  /// Lists non-secret sessions stored for this issuer and public client.
  public func listAccounts() async throws -> [UserSession] {
    do {
      return try await credentialStore.credentials().map(\.session)
    } catch {
      throw publicError(error)
    }
  }

  /// Activates a stored account and refreshes its device-local token.
  @discardableResult
  public func switchAccount(accountUID: String) async throws -> UserSession {
    guard UUID(uuidString: accountUID) != nil else {
      throw SDKError(code: .invalidConfiguration, message: "OAuth account UID is invalid")
    }
    try requireIdleOperation()
    let normalizedUID = accountUID.lowercased()
    guard !accountsSigningOut.contains(normalizedUID) else {
      throw SDKError(code: .conflict, message: "OAuth account is signing out")
    }
    let credentials = try await credentialStore.credentials()
    guard let credential = credentials.first(where: { $0.session.accountUID == normalizedUID })
    else {
      throw SDKError(code: .unauthorized, message: "OAuth account is unavailable")
    }
    try await ensureMetadata()
    generation &+= 1
    refreshFlight?.task.cancel()
    refreshFlight = nil
    accessToken = nil
    activeCredential = credential
    try await credentialStore.setActiveAccountUID(normalizedUID)
    emit(.activeAccountChanged, accountUID: normalizedUID)
    transition(to: .refreshing(credential.session))
    do {
      _ = try await refreshAccessToken()
      return activeCredential?.session ?? credential.session
    } catch {
      throw publicError(error)
    }
  }

  /// Refreshes the active account's public profile with the Gateway user API.
  @discardableResult
  public func refreshProfile() async throws -> UserSession {
    guard let credential = activeCredential else {
      throw SDKError(code: .unauthorized, message: "No active OAuth account")
    }
    let operationGeneration = generation
    let token = try await getAccessToken(minValidityMilliseconds: 60_000)
    guard let currentCredential = activeCredential,
      currentCredential.session.accountUID == credential.session.accountUID
    else {
      throw SDKError(code: .cancelled, message: "OAuth profile refresh was superseded")
    }
    let profile: OAuthRemoteProfile
    do {
      profile = try await protocolClient.profile(accessToken: token)
    } catch {
      if isReauthenticationFailure(error), generation == operationGeneration {
        markNeedsReauthentication(currentCredential.session)
      }
      throw publicError(error)
    }
    try ensureCurrentGeneration(operationGeneration)
    guard profile.subject == currentCredential.session.subject else {
      markNeedsReauthentication(currentCredential.session)
      throw SDKError(code: .unauthorized, message: "OAuth profile subject changed")
    }
    let updated = try UserSession(
      accountUID: currentCredential.session.accountUID,
      subject: profile.subject,
      issuer: currentCredential.session.issuer,
      displayName: profile.displayName,
      avatarURL: profile.avatarURL,
      scopes: currentCredential.session.scopes,
      accessExpiresAtMilliseconds: currentCredential.session.accessExpiresAtMilliseconds,
      profileRevision: currentCredential.session.profileRevision
    )
    let stored = try StoredOAuthCredential(
      configuration: configuration,
      session: updated,
      refreshToken: currentCredential.refreshToken
    )
    try await credentialStore.save(stored)
    try ensureCurrentGeneration(operationGeneration)
    activeCredential = stored
    transition(to: .signedIn(updated))
    emit(.profileChanged, accountUID: updated.accountUID)
    return updated
  }

  /// Stops new token access, optionally revokes the remote grant, and always performs local logout.
  public func signOut(accountUID: String, revokeRemote: Bool = true) async throws {
    guard UUID(uuidString: accountUID) != nil else {
      throw SDKError(code: .invalidConfiguration, message: "OAuth account UID is invalid")
    }
    let normalizedUID = accountUID.lowercased()
    guard accountsSigningOut.insert(normalizedUID).inserted else {
      throw SDKError(code: .conflict, message: "OAuth account is already signing out")
    }
    defer { accountsSigningOut.remove(normalizedUID) }
    let wasActive = activeCredential?.session.accountUID == normalizedUID
    let activeAtStart = wasActive ? activeCredential : nil
    let pendingRefresh = wasActive ? refreshFlight : nil
    if wasActive {
      generation &+= 1
      pendingRefresh?.task.cancel()
      refreshFlight = nil
      accessToken = nil
      if let activeAtStart { transition(to: .signingOut(activeAtStart.session)) }
    }
    if let pendingRefresh { _ = await pendingRefresh.task.result }

    let credentials = try await credentialStore.credentials()
    guard
      let credential = credentials.first(where: { $0.session.accountUID == normalizedUID })
        ?? activeAtStart
    else { return }

    if revokeRemote, let metadata = try? await ensureMetadata() {
      try? await protocolClient.revoke(refreshToken: credential.refreshToken, metadata: metadata)
    }
    do {
      try await credentialStore.remove(accountUID: normalizedUID)
    } catch {
      if wasActive {
        activeCredential = credential
        transition(to: .needsReauthentication(credential.session))
      }
      throw publicError(error)
    }
    if wasActive {
      activeCredential = nil
      accessToken = nil
      transition(to: .signedOut)
      emit(.activeAccountChanged, accountUID: nil)
    }
    emit(.signedOut, accountUID: normalizedUID)
  }

  private func refreshAccessToken() async throws -> String {
    guard let credential = activeCredential else {
      throw SDKError(code: .unauthorized, message: "No active OAuth account")
    }
    let metadata = try await ensureMetadata()
    let flight: RefreshFlight
    if let existing = refreshFlight {
      flight = existing
    } else {
      let identifier = uuidGenerator.makeUUID()
      let currentGeneration = generation
      transition(to: .refreshing(credential.session))
      let task = Task { [protocolClient, credentialStore, configuration] in
        let token = try await protocolClient.refresh(
          refreshToken: credential.refreshToken,
          scopes: credential.session.scopes,
          metadata: metadata
        )
        let session = try UserSession(
          accountUID: credential.session.accountUID,
          subject: credential.session.subject,
          issuer: credential.session.issuer,
          displayName: credential.session.displayName,
          avatarURL: credential.session.avatarURL,
          scopes: token.scopes,
          accessExpiresAtMilliseconds: token.expiresAtMilliseconds,
          profileRevision: credential.session.profileRevision
        )
        let stored = try StoredOAuthCredential(
          configuration: configuration,
          session: session,
          refreshToken: token.refreshToken
        )
        try Task.checkCancellation()
        try await credentialStore.save(stored)
        return RefreshResult(
          credential: stored,
          accessToken: AccessToken(
            value: token.accessToken,
            expiresAtMilliseconds: token.expiresAtMilliseconds
          )
        )
      }
      flight = RefreshFlight(id: identifier, generation: currentGeneration, task: task)
      refreshFlight = flight
    }

    do {
      let result = try await flight.task.value
      guard generation == flight.generation else {
        throw SDKError(code: .cancelled, message: "OAuth refresh was superseded")
      }
      if refreshFlight?.id == flight.id {
        refreshFlight = nil
        activeCredential = result.credential
        accessToken = result.accessToken
        transition(to: .signedIn(result.credential.session))
      }
      guard let accessToken else {
        throw SDKError(code: .cancelled, message: "OAuth refresh was superseded")
      }
      return accessToken.value
    } catch {
      if refreshFlight?.id == flight.id { refreshFlight = nil }
      if generation == flight.generation, requiresReauthenticationAfterRefresh(error) {
        markNeedsReauthentication(credential.session)
      } else if generation == flight.generation {
        transition(to: .signedIn(credential.session))
      }
      throw error
    }
  }

  @discardableResult
  private func ensureMetadata() async throws -> OAuthServerMetadata {
    if let metadata { return metadata }
    do {
      let discovered = try await protocolClient.discover()
      metadata = discovered
      return discovered
    } catch {
      throw publicError(error)
    }
  }

  private func authorizationEndpoint(_ metadata: OAuthServerMetadata) throws -> URL {
    guard metadata.authorizationEndpoint == configuration.issuer.absoluteString + "oauth/authorize",
      let endpoint = URL(string: metadata.authorizationEndpoint)
    else {
      throw SDKError(
        code: .invalidConfiguration, message: "OAuth authorization endpoint is invalid")
    }
    return endpoint
  }

  private func makeSession(
    profile: OAuthRemoteProfile,
    token: OAuthTokenBundle
  ) throws -> UserSession {
    try UserSession(
      accountUID: profile.subject,
      subject: profile.subject,
      issuer: configuration.issuer.absoluteString,
      displayName: profile.displayName,
      avatarURL: profile.avatarURL,
      scopes: token.scopes,
      accessExpiresAtMilliseconds: token.expiresAtMilliseconds
    )
  }

  private func requireIdleOperation() throws {
    switch state {
    case .authorizing, .refreshing, .signingOut:
      throw SDKError(code: .conflict, message: "OAuth session operation is already in progress")
    case .signedOut, .signedIn, .needsReauthentication:
      break
    }
  }

  private func ensureCurrentGeneration(_ expected: UInt64) throws {
    guard generation == expected else {
      throw SDKError(code: .cancelled, message: "OAuth operation was superseded")
    }
  }

  private func transition(to newState: OAuthSessionState) {
    state = newState
    emit(.sessionStateChanged, accountUID: newState.session?.accountUID)
  }

  private func markNeedsReauthentication(_ session: UserSession) {
    accessToken = nil
    transition(to: .needsReauthentication(session))
    emit(.reauthenticationRequired, accountUID: session.accountUID)
  }

  private func emit(_ kind: OAuthSessionEvent.Kind, accountUID: String?) {
    guard
      let event = try? OAuthSessionEvent(
        kind: kind,
        accountUID: accountUID,
        occurredAtMilliseconds: clock.nowMilliseconds(),
        traceID: uuidGenerator.makeUUID().uuidString
      )
    else { return }
    for continuation in eventContinuations.values { continuation.yield(event) }
  }

  private func removeEventContinuation(_ identifier: UUID) {
    eventContinuations.removeValue(forKey: identifier)
  }

  private func isReauthenticationFailure(_ error: Error) -> Bool {
    guard let failure = error as? OAuthProtocolFailure,
      case .server(let code, _) = failure
    else { return false }
    return code == "invalid_grant" || code == "invalid_token"
      || code == "account_reauthentication_required"
  }

  private func requiresReauthenticationAfterRefresh(_ error: Error) -> Bool {
    if isReauthenticationFailure(error) { return true }
    return (error as? SDKError)?.code == .storageFailure
  }

  private func publicError(_ error: Error) -> SDKError {
    if let error = error as? SDKError { return error }
    if error is CancellationError {
      return SDKError(code: .cancelled, message: "OAuth operation was cancelled")
    }
    if error is URLError {
      return SDKError(
        code: .networkUnavailable,
        message: "OAuth network request failed",
        retryAfterMilliseconds: nil,
        traceID: nil
      )
    }
    if let error = error as? OAuthProtocolFailure {
      switch error {
      case .invalidResponse:
        return SDKError(code: .parseFailure, message: "OAuth server response is invalid")
      case .server(let code, let retryAfter):
        switch code {
        case "invalid_grant", "invalid_token", "account_reauthentication_required":
          return SDKError(code: .unauthorized, message: "OAuth reauthentication is required")
        case "invalid_scope", "insufficient_scope", "client_not_allowed":
          return SDKError(code: .forbidden, message: "OAuth scope is not allowed")
        case "temporarily_unavailable", "server_error":
          return SDKError(
            code: .remoteUnavailable,
            message: "OAuth service is temporarily unavailable",
            retryAfterMilliseconds: retryAfter
          )
        case "invalid_client":
          return SDKError(code: .unauthorized, message: "OAuth client is not authorized")
        default:
          return SDKError(code: .unauthorized, message: "OAuth request was rejected")
        }
      }
    }
    return SDKError(code: .unknown, message: "OAuth operation failed")
  }
}

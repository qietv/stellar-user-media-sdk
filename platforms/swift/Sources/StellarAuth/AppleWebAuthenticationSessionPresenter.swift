import Foundation
import StellarCore

#if canImport(AuthenticationServices) && !os(tvOS) && !os(watchOS)
  import AuthenticationServices
#endif

/// Presents OAuth with `ASWebAuthenticationSession` for registered custom-scheme or HTTPS callbacks.
public struct AppleWebAuthenticationSessionPresenter: OAuthAuthorizationPresenting {
  private let presentationAnchorProvider: @MainActor @Sendable () -> AnyObject
  private let prefersEphemeralSession: Bool

  /// Creates a presenter. The closure must return the host app's `ASPresentationAnchor`.
  public init(
    prefersEphemeralSession: Bool = false,
    presentationAnchorProvider: @escaping @MainActor @Sendable () -> AnyObject
  ) {
    self.prefersEphemeralSession = prefersEphemeralSession
    self.presentationAnchorProvider = presentationAnchorProvider
  }

  @MainActor
  public func authorize(_ request: OAuthAuthorizationPresentationRequest) async throws -> URL {
    #if canImport(AuthenticationServices) && !os(tvOS) && !os(watchOS)
      let runner = try AppleWebAuthenticationSessionRunner(
        prefersEphemeralSession: prefersEphemeralSession,
        presentationAnchorProvider: presentationAnchorProvider
      )
      return try await runner.authorize(request)
    #else
      throw SDKError(
        code: .invalidConfiguration,
        message: "ASWebAuthenticationSession is unavailable on this platform"
      )
    #endif
  }
}

#if canImport(AuthenticationServices) && !os(tvOS) && !os(watchOS)
  @MainActor
  private final class AppleWebAuthenticationSessionRunner: NSObject,
    ASWebAuthenticationPresentationContextProviding
  {
    private let prefersEphemeralSession: Bool
    private let presentationAnchor: ASPresentationAnchor
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?

    init(
      prefersEphemeralSession: Bool,
      presentationAnchorProvider: @MainActor @Sendable () -> AnyObject
    ) throws {
      guard let presentationAnchor = presentationAnchorProvider() as? ASPresentationAnchor else {
        throw SDKError(
          code: .invalidConfiguration,
          message: "OAuth presentation anchor is invalid"
        )
      }
      self.prefersEphemeralSession = prefersEphemeralSession
      self.presentationAnchor = presentationAnchor
      super.init()
    }

    func authorize(_ request: OAuthAuthorizationPresentationRequest) async throws -> URL {
      try Task.checkCancellation()
      guard session == nil, continuation == nil else {
        throw SDKError(code: .conflict, message: "OAuth browser authorization is already active")
      }
      guard
        let redirect = URLComponents(
          url: request.redirectURI,
          resolvingAgainstBaseURL: false
        ), let scheme = redirect.scheme
      else {
        throw SDKError(code: .invalidConfiguration, message: "OAuth callback URI is invalid")
      }
      guard scheme != "http" else {
        throw SDKError(
          code: .invalidConfiguration,
          message: "ASWebAuthenticationSession does not support HTTP loopback callbacks"
        )
      }

      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          self.continuation = continuation
          if Task.isCancelled {
            finish(
              url: nil,
              error: SDKError(code: .cancelled, message: "OAuth authorization was cancelled")
            )
            return
          }
          let completion: ASWebAuthenticationSession.CompletionHandler = { [weak self] url, error in
            Task { @MainActor in self?.finish(url: url, error: error) }
          }
          let session: ASWebAuthenticationSession
          if #available(iOS 17.4, macOS 14.4, *) {
            let callback: ASWebAuthenticationSession.Callback
            if scheme == "https", let host = redirect.host {
              callback = .https(host: host, path: redirect.path)
            } else if scheme != "https" {
              callback = .customScheme(scheme)
            } else {
              finish(
                url: nil,
                error: SDKError(
                  code: .invalidConfiguration,
                  message: "OAuth HTTPS callback URI is invalid"
                )
              )
              return
            }
            session = ASWebAuthenticationSession(
              url: request.authorizationURL,
              callback: callback,
              completionHandler: completion
            )
          } else if scheme != "https" {
            session = ASWebAuthenticationSession(
              url: request.authorizationURL,
              callbackURLScheme: scheme,
              completionHandler: completion
            )
          } else {
            finish(
              url: nil,
              error: SDKError(
                code: .invalidConfiguration,
                message: "HTTPS OAuth callbacks require a newer Apple system version"
              )
            )
            return
          }
          self.session = session
          session.presentationContextProvider = self
          session.prefersEphemeralWebBrowserSession = prefersEphemeralSession
          guard session.start() else {
            finish(
              url: nil,
              error: SDKError(
                code: .unknown, message: "OAuth browser authorization could not start")
            )
            return
          }
        }
      } onCancel: {
        Task { @MainActor [weak self] in
          self?.session?.cancel()
          self?.finish(
            url: nil,
            error: SDKError(code: .cancelled, message: "OAuth authorization was cancelled")
          )
        }
      }
    }

    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
      presentationAnchor
    }

    private func finish(url: URL?, error: Error?) {
      guard let continuation else { return }
      self.continuation = nil
      session = nil
      if let url {
        continuation.resume(returning: url)
        return
      }
      if let authenticationError = error as? ASWebAuthenticationSessionError,
        authenticationError.code == .canceledLogin
      {
        let failureReason = (authenticationError as NSError).localizedFailureReason
        if let failureReason,
          failureReason.localizedCaseInsensitiveContains("associated")
            || failureReason.localizedCaseInsensitiveContains("webcredentials")
        {
          continuation.resume(
            throwing: SDKError(
              code: .invalidConfiguration,
              message: "OAuth HTTPS callback domain is not associated with the app: \(failureReason)"
            )
          )
          return
        }
        continuation.resume(
          throwing: SDKError(code: .cancelled, message: "OAuth authorization was cancelled")
        )
        return
      }
      if let error = error as? SDKError {
        continuation.resume(throwing: error)
        return
      }
      continuation.resume(
        throwing: SDKError(code: .unknown, message: "OAuth browser authorization failed")
      )
    }
  }
#endif

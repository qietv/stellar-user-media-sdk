import Combine
import StellarUserMediaSDK
import UIKit

@MainActor
final class OAuthDemoModel: ObservableObject {
  @Published private(set) var state: OAuthSessionState = .signedOut
  @Published private(set) var accounts: [UserSession] = []
  @Published private(set) var isBusy = false
  @Published private(set) var notice = "Ready"
  @Published private(set) var noticeIsError = false

  private let manager: OAuthSessionManager?
  private var didAttemptRestore = false

  init() {
    do {
      let configuration = try StellarOAuthConfiguration(
        issuer: URL(string: "https://dev-gateway.2dland.cn/")!,
        clientID: "stellarplayer-ios-demo",
        redirectURI: URL(
          string: "https://dev-auth-stellarplayer.2dland.cn/oauth/callback"
        )!,
        scopes: ["profile.read"],
        profileEndpoint: URL(
          string: "https://dev-user-stellarplayer.2dland.cn/api/v1/me"
        )!
      )
      let presenter = AppleWebAuthenticationSessionPresenter(
        presentationAnchorProvider: currentOAuthPresentationAnchor
      )
      manager = OAuthSessionManager(
        configuration: configuration,
        authorizationPresenter: presenter
      )
    } catch {
      manager = nil
      notice = Self.message(for: error)
      noticeIsError = true
    }
  }

  var session: UserSession? {
    state.session
  }

  var stateLabel: String {
    state.rawValue
  }

  var canSignIn: Bool {
    switch state {
    case .signedOut, .needsReauthentication:
      true
    case .authorizing, .signedIn, .refreshing, .signingOut:
      false
    }
  }

  func restoreOnce() async {
    guard !didAttemptRestore else { return }
    didAttemptRestore = true
    guard let manager = beginOperation("Restoring the device-local session…") else { return }
    do {
      let restored = try await manager.restoreSession()
      await reload(from: manager)
      show(restored == nil ? "No stored account" : "Session restored")
    } catch {
      await reload(from: manager)
      show(error: error)
    }
    isBusy = false
  }

  func signIn() async {
    guard let manager = beginOperation("Opening the system sign-in session…") else { return }
    do {
      _ = try await manager.signIn()
      await reload(from: manager)
      show("Signed in and stored the rotating refresh token in Keychain")
    } catch {
      await reload(from: manager)
      show(error: error)
    }
    isBusy = false
  }

  func refreshProfile() async {
    guard let manager = beginOperation("Refreshing the public profile…") else { return }
    do {
      _ = try await manager.refreshProfile()
      await reload(from: manager)
      show("Profile refreshed")
    } catch {
      await reload(from: manager)
      show(error: error)
    }
    isBusy = false
  }

  func validateAccessToken() async {
    guard let manager = beginOperation("Checking access-token availability…") else { return }
    do {
      _ = try await manager.getAccessToken(minValidityMilliseconds: 60_000)
      await reload(from: manager)
      show("A valid access token is available; its value was not displayed")
    } catch {
      await reload(from: manager)
      show(error: error)
    }
    isBusy = false
  }

  func switchAccount(to accountUID: String) async {
    guard let manager = beginOperation("Switching account…") else { return }
    do {
      _ = try await manager.switchAccount(accountUID: accountUID)
      await reload(from: manager)
      show("Active account changed")
    } catch {
      await reload(from: manager)
      show(error: error)
    }
    isBusy = false
  }

  func signOut() async {
    guard let accountUID = state.session?.accountUID else {
      show("There is no active account", isError: true)
      return
    }
    guard let manager = beginOperation("Revoking the grant and clearing local credentials…")
    else { return }
    do {
      try await manager.signOut(accountUID: accountUID)
      await reload(from: manager)
      show("Signed out locally; remote revocation was attempted")
    } catch {
      await reload(from: manager)
      show(error: error)
    }
    isBusy = false
  }

  private func beginOperation(_ message: String) -> OAuthSessionManager? {
    guard !isBusy else { return nil }
    guard let manager else {
      show("OAuth manager could not be configured", isError: true)
      return nil
    }
    isBusy = true
    show(message)
    return manager
  }

  private func reload(from manager: OAuthSessionManager) async {
    state = await manager.state
    if let storedAccounts = try? await manager.listAccounts() {
      accounts = storedAccounts
    }
  }

  private func show(_ message: String, isError: Bool = false) {
    notice = message
    noticeIsError = isError
  }

  private func show(error: Error) {
    show(Self.message(for: error), isError: true)
  }

  nonisolated private static func message(for error: Error) -> String {
    if let error = error as? SDKError {
      return "\(error.code.rawValue): \(error.message)"
    }
    if error is CancellationError {
      return "cancelled: The operation was cancelled"
    }
    return "unknown: The operation failed"
  }
}

@MainActor
private func currentOAuthPresentationAnchor() -> AnyObject {
  let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
  for scene in scenes where scene.activationState == .foregroundActive {
    if let keyWindow = scene.windows.first(where: \.isKeyWindow) {
      return keyWindow
    }
    if let window = scene.windows.first {
      return window
    }
  }
  return UIWindow()
}

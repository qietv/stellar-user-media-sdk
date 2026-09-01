import StellarUserMediaSDK
import SwiftUI
import UIKit

private enum DemoTab: Hashable {
  case account
  case scan
  case library
}

struct ContentView: View {
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var oauthModel = OAuthDemoModel()
  @StateObject private var mediaLibraryModel = MediaLibraryModel()
  @State private var selectedTab = DemoTab.account

  var body: some View {
    TabView(selection: $selectedTab) {
      OAuthPage(model: oauthModel)
        .tag(DemoTab.account)
        .tabItem {
          Label("Account", systemImage: "person.crop.circle")
        }

      SMBScanView(model: mediaLibraryModel)
        .tag(DemoTab.scan)
        .tabItem {
          Label("Scan", systemImage: "externaldrive.connected.to.line.below")
        }

      PosterWallView(model: mediaLibraryModel)
        .tag(DemoTab.library)
        .tabItem {
          Label("Library", systemImage: "rectangle.grid.2x2")
        }
    }
    .task {
      await oauthModel.restoreOnce()
      await mediaLibraryModel.prepareIfNeeded()
    }
    .onChange(of: selectedTab, initial: true) { _, newTab in
      updateIdleTimer(for: newTab, scenePhase: scenePhase)
    }
    .onChange(of: scenePhase) { _, newPhase in
      updateIdleTimer(for: selectedTab, scenePhase: newPhase)
    }
    .onDisappear {
      UIApplication.shared.isIdleTimerDisabled = false
    }
  }

  private func updateIdleTimer(for tab: DemoTab, scenePhase: ScenePhase) {
    UIApplication.shared.isIdleTimerDisabled = tab == .scan && scenePhase == .active
  }
}

private struct OAuthPage: View {
  @ObservedObject var model: OAuthDemoModel

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 16) {
          sessionCard
          actionCard
          accountCard
          diagnosticCard
        }
        .padding()
      }
      .navigationTitle("Stellar OAuth")
    }
  }

  private var sessionCard: some View {
    GroupBox("Active session") {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("State")
          Spacer()
          Text(model.stateLabel)
            .font(.system(.caption, design: .monospaced, weight: .semibold))
            .foregroundStyle(stateColor)
        }

        if let session = model.session {
          HStack(spacing: 12) {
            avatar(for: session)
            VStack(alignment: .leading, spacing: 3) {
              Text(session.displayName ?? "Unnamed account")
                .font(.headline)
              Text(session.subject)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
          }
          Divider()
          detail("Account UID", session.accountUID)
          detail("Scopes", session.scopes.joined(separator: " "))
          detail("Access expiry", expiryDescription(session.accessExpiresAtMilliseconds))
        } else {
          Text("No active Stellar account")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var actionCard: some View {
    GroupBox("OAuth actions") {
      VStack(spacing: 10) {
        if model.canSignIn {
          Button("Sign in with Stellar") {
            Task { await model.signIn() }
          }
          .buttonStyle(.borderedProminent)
        }

        if model.session != nil {
          Button("Refresh public profile") {
            Task { await model.refreshProfile() }
          }
          .buttonStyle(.bordered)

          Button("Validate access token") {
            Task { await model.validateAccessToken() }
          }
          .buttonStyle(.bordered)

          Button("Sign out and revoke", role: .destructive) {
            Task { await model.signOut() }
          }
          .buttonStyle(.bordered)
        }

        if model.isBusy {
          ProgressView()
            .padding(.top, 4)
        }
      }
      .disabled(model.isBusy)
      .frame(maxWidth: .infinity)
    }
  }

  private var accountCard: some View {
    GroupBox("Stored accounts") {
      VStack(alignment: .leading, spacing: 10) {
        if model.accounts.isEmpty {
          Text("No device-local accounts")
            .foregroundStyle(.secondary)
        } else {
          ForEach(model.accounts, id: \.accountUID) { account in
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName ?? "Unnamed account")
                Text(account.accountUID)
                  .font(.caption2.monospaced())
                  .foregroundStyle(.secondary)
              }
              Spacer()
              if account.accountUID == model.session?.accountUID {
                Image(systemName: "checkmark.circle.fill")
                  .foregroundStyle(.green)
                  .accessibilityLabel("Active account")
              } else {
                Button("Use") {
                  Task { await model.switchAccount(to: account.accountUID) }
                }
                .disabled(model.isBusy)
              }
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var diagnosticCard: some View {
    GroupBox("Diagnostic status") {
      Text(model.notice)
        .font(.callout)
        .foregroundStyle(model.noticeIsError ? Color.red : Color.secondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var stateColor: Color {
    switch model.state {
    case .signedIn:
      .green
    case .authorizing, .refreshing, .signingOut:
      .orange
    case .needsReauthentication:
      .red
    case .signedOut:
      .secondary
    }
  }

  @ViewBuilder
  private func avatar(for session: UserSession) -> some View {
    if let value = session.avatarURL, let url = URL(string: value) {
      AsyncImage(url: url) { image in
        image.resizable().scaledToFill()
      } placeholder: {
        ProgressView()
      }
      .frame(width: 48, height: 48)
      .clipShape(Circle())
    } else {
      Image(systemName: "person.crop.circle.fill")
        .resizable()
        .foregroundStyle(.secondary)
        .frame(width: 48, height: 48)
    }
  }

  private func detail(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.caption.monospaced())
        .textSelection(.enabled)
    }
  }

  private func expiryDescription(_ milliseconds: Int64) -> String {
    Date(timeIntervalSince1970: Double(milliseconds) / 1_000).formatted(
      date: .abbreviated,
      time: .standard
    )
  }
}

#Preview {
  ContentView()
}

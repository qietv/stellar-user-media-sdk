import OSLog
import SwiftUI

@main
struct StellarOAuthDemoApp: App {
  init() {
    demoLaunchLogger.notice("phase=app-init")
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
    }
  }
}

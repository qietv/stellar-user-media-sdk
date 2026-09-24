import OSLog
import SwiftUI

let demoLaunchLogger = Logger(
  subsystem: Bundle.main.bundleIdentifier ?? "StellarOAuthDemo",
  category: "Launch"
)

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

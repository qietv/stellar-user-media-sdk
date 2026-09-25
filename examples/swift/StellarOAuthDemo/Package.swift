// swift-tools-version: 6.3
import PackageDescription

// Tests compile the app's actual metadata client and DTOs without launching OAuth or scanning SMB.
let package = Package(
  name: "StellarOAuthDemoMetadata",
  platforms: [.macOS(.v14)],
  dependencies: [.package(path: "../../../platforms/swift")],
  targets: [
    .target(
      name: "DemoMetadata",
      dependencies: [
        .product(name: "StellarUserMediaSDK", package: "swift"),
        .product(name: "StellarSMB2", package: "swift"),
        .product(name: "StellarDiscMedia", package: "swift"),
      ],
      path: "StellarOAuthDemo",
      exclude: [
        "ContentView.swift", "MediaDetailsModel.swift",
        "MediaDetailsView.swift", "PeopleDetailsView.swift", "SeriesBrowserView.swift",
        "OAuthDemoModel.swift", "PosterWallView.swift", "SMBScanView.swift",
        "SMBPasswordField.swift", "StellarOAuthDemoApp.swift",
        "StellarOAuthDemo.entitlements", "StellarOAuthDemo.debug.entitlements",
      ],
      sources: ["MediaInfoModels.swift", "TestMediaInfoClient.swift", "MediaLibraryModel.swift"]
    ),
    .testTarget(name: "DemoMetadataTests", dependencies: ["DemoMetadata"], path: "Tests"),
  ],
  swiftLanguageModes: [.v6]
)

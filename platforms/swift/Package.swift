// swift-tools-version: 6.3

import PackageDescription

let package = Package(
  name: "StellarUserMediaSDK",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
    .tvOS(.v17),
  ],
  products: [
    .library(
      name: "StellarUserMediaSDK",
      targets: ["StellarUserMediaSDK"]
    ),
    .executable(
      name: "stellar-media",
      targets: ["StellarMediaCLI"]
    ),
  ],
  targets: [
    .target(
      name: "StellarCore"
    ),
    .target(
      name: "StellarRemoteMedia",
      dependencies: ["StellarCore"]
    ),
    .target(
      name: "StellarMediaLibrary",
      dependencies: ["StellarCore", "StellarRemoteMedia"]
    ),
    .target(
      name: "StellarUserMediaSDK",
      dependencies: ["StellarCore", "StellarRemoteMedia", "StellarMediaLibrary"]
    ),
    .executableTarget(
      name: "StellarMediaCLI",
      dependencies: ["StellarUserMediaSDK"]
    ),
    .testTarget(
      name: "StellarUserMediaSDKTests",
      dependencies: [
        "StellarCore",
        "StellarRemoteMedia",
        "StellarMediaLibrary",
        "StellarUserMediaSDK",
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)

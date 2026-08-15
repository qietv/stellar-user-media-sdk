// swift-tools-version: 6.3

import PackageDescription

var packageTargets: [Target] = [
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
    name: "StellarSMB2Core",
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
      "StellarSMB2Core",
      "StellarUserMediaSDK",
    ]
  ),
]

#if os(Linux)
  packageTargets.append(
    .systemLibrary(
      name: "CStellarLibsmb2Private",
      path: "Sources/CStellarLibsmb2Private",
      pkgConfig: "stellar-libsmb2-private"
    ))
#endif

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
  targets: packageTargets,
  swiftLanguageModes: [.v6]
)

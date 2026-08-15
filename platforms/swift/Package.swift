// swift-tools-version: 6.3

import PackageDescription

var cliDependencies: [Target.Dependency] = ["StellarUserMediaSDK"]
var testDependencies: [Target.Dependency] = [
  "StellarCore",
  "StellarRemoteMedia",
  "StellarMediaLibrary",
  "StellarSMB2Core",
  "StellarUserMediaSDK",
]

#if os(Linux)
  cliDependencies.append("StellarSMB2Core")
  cliDependencies.append("StellarSMB2Linux")
  testDependencies.append("StellarSMB2Linux")
#endif

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
    dependencies: cliDependencies
  ),
  .testTarget(
    name: "StellarUserMediaSDKTests",
    dependencies: testDependencies
  ),
]

#if os(Linux)
  packageTargets.append(contentsOf: [
    .systemLibrary(
      name: "CStellarLibsmb2Private",
      path: "Sources/CStellarLibsmb2Private",
      pkgConfig: "stellar-libsmb2-private"
    ),
    .target(
      name: "CStellarSMB2Wrapper",
      dependencies: ["CStellarLibsmb2Private"],
      publicHeadersPath: "include",
      linkerSettings: [
        .unsafeFlags([
          "-Xlinker", "--exclude-libs=libstellar_libsmb2_private.a",
        ])
      ]
    ),
    .target(
      name: "StellarSMB2Linux",
      dependencies: ["StellarCore", "StellarSMB2Core", "CStellarSMB2Wrapper"]
    ),
  ])
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

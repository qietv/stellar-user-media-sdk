// swift-tools-version: 6.3

import PackageDescription

var cliDependencies: [Target.Dependency] = ["StellarUserMediaSDK"]
var testDependencies: [Target.Dependency] = [
  "StellarCore",
  "StellarAuth",
  "StellarRemoteMedia",
  "StellarLocalMedia",
  "StellarWebDAV",
  "StellarStorage",
  "StellarMediaLibrary",
  "StellarPosterWall",
  "StellarSMB2Core",
  "StellarUserMediaSDK",
  .product(name: "GRDB", package: "GRDB.swift"),
]
var packageDependencies: [Package.Dependency] = [
  .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")
]

#if os(macOS)
  cliDependencies.append("StellarSMB2Core")
  cliDependencies.append("StellarSMB2Apple")
  testDependencies.append("StellarSMB2Apple")
  testDependencies.append("StellarMediaImaging")
  packageDependencies.append(
    .package(url: "https://github.com/TracyPlayer/AMSMB2.git", exact: "4.0.3")
  )
  packageDependencies.append(
    .package(
      url: "https://github.com/TracyPlayer/FFmpegKit.git",
      revision: "233c6bb6657a244ef57178e5d54979d1fd3cd45d"
    )
  )
#endif

var packageTargets: [Target] = [
  .target(
    name: "StellarCore"
  ),
  .target(
    name: "StellarAuth",
    dependencies: ["StellarCore"]
  ),
  .target(
    name: "StellarRemoteMedia",
    dependencies: ["StellarCore"]
  ),
  .target(
    name: "StellarStorage",
    dependencies: [
      "StellarCore",
      "StellarRemoteMedia",
      .product(name: "GRDB", package: "GRDB.swift"),
    ]
  ),
  .target(
    name: "StellarMediaLibrary",
    dependencies: ["StellarCore", "StellarRemoteMedia", "StellarStorage"]
  ),
  .target(
    name: "StellarPosterWall",
    dependencies: [
      "StellarCore",
      "StellarStorage",
      .product(name: "GRDB", package: "GRDB.swift"),
    ]
  ),
  .target(
    name: "StellarLocalMedia",
    dependencies: ["StellarCore", "StellarRemoteMedia"]
  ),
  .target(
    name: "StellarWebDAV",
    dependencies: ["StellarCore", "StellarRemoteMedia"]
  ),
  .target(
    name: "StellarSMB2Core",
    dependencies: ["StellarCore", "StellarRemoteMedia"]
  ),
  .target(
    name: "StellarUserMediaSDK",
    dependencies: [
      "StellarCore", "StellarAuth", "StellarRemoteMedia", "StellarLocalMedia",
      "StellarMediaLibrary",
      "StellarPosterWall", "StellarStorage", "StellarWebDAV",
    ]
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

#if os(macOS)
  packageTargets.append(contentsOf: [
    .target(
      name: "StellarSMB2Apple",
      dependencies: [
        "StellarCore",
        "StellarSMB2Core",
        .product(name: "AMSMB2", package: "AMSMB2"),
      ]
    ),
    .target(
      name: "CStellarFFmpegScreenshot",
      dependencies: [
        .product(name: "Libavcodec", package: "FFmpegKit"),
        .product(name: "Libavformat", package: "FFmpegKit"),
        .product(name: "Libavutil", package: "FFmpegKit"),
        .product(name: "Libswresample", package: "FFmpegKit"),
        .product(name: "Libswscale", package: "FFmpegKit"),
        .product(name: "libzvbi", package: "FFmpegKit"),
      ],
      publicHeadersPath: "include"
    ),
    .target(
      name: "StellarMediaImaging",
      dependencies: [
        "CStellarFFmpegScreenshot",
        "StellarCore",
        "StellarRemoteMedia",
      ],
      linkerSettings: [
        .linkedFramework("CoreGraphics"),
        .linkedFramework("ImageIO"),
      ]
    ),
  ])
#endif

var packageProducts: [Product] = [
  .library(
    name: "StellarUserMediaSDK",
    targets: ["StellarUserMediaSDK"]
  ),
  .executable(
    name: "stellar-media",
    targets: ["StellarMediaCLI"]
  ),
]

#if os(macOS)
  packageProducts.append(
    .library(
      name: "StellarSMB2",
      targets: ["StellarSMB2Core", "StellarSMB2Apple"]
    ))
  packageProducts.append(
    .library(
      name: "StellarMediaImaging",
      targets: ["StellarMediaImaging"]
    ))
#endif

let package = Package(
  name: "StellarUserMediaSDK",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
    .tvOS(.v17),
  ],
  products: packageProducts,
  dependencies: packageDependencies,
  targets: packageTargets,
  swiftLanguageModes: [.v6]
)

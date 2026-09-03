// swift-tools-version: 6.3

import PackageDescription

#if !os(macOS)
  fatalError(
    "StellarUserMediaSDK supports Apple platforms only; evaluate this package with SwiftPM on macOS."
  )
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
    .library(
      name: "StellarSMB2",
      targets: ["StellarSMB2Core", "StellarSMB2Apple"]
    ),
    .library(
      name: "StellarMediaImaging",
      targets: ["StellarMediaImaging"]
    ),
    .library(
      name: "StellarDiscMedia",
      targets: ["StellarDiscMedia"]
    ),
    .executable(
      name: "stellar-media",
      targets: ["StellarMediaCLI"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    .package(url: "https://github.com/TracyPlayer/AMSMB2.git", exact: "4.0.3"),
    .package(
      url: "https://github.com/TracyPlayer/FFmpegKit.git",
      revision: "233c6bb6657a244ef57178e5d54979d1fd3cd45d"
    ),
    .package(
      url: "https://github.com/TracyPlayer/BDMVIOContext.git",
      revision: "639c793ff0cac9a9e3601db49e5790b5ba18f321"
    ),
    // BDMVIOContext's `from: 5.0.0` floor lacks its current FilesManager API. Keep a direct,
    // reproducible pin to the verified latest KSPlayer `lgpl` commit instead.
    .package(
      url: "https://github.com/TracyPlayer/KSPlayer.git",
      revision: "da62452393eac406176605e6cceac8aeae265e9d"
    ),
  ],
  targets: [
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
        "StellarMediaLibrary",
        "StellarRemoteMedia",
      ],
      linkerSettings: [
        .linkedFramework("CoreGraphics"),
        .linkedFramework("ImageIO"),
      ]
    ),
    .target(
      name: "StellarDiscMedia",
      dependencies: [
        "StellarCore",
        "StellarMediaLibrary",
        "StellarRemoteMedia",
        .product(name: "BDMVIOContext", package: "BDMVIOContext"),
        .product(name: "KSPlayer", package: "KSPlayer"),
      ]
    ),
    .target(
      name: "StellarUserMediaSDK",
      dependencies: [
        "StellarCore", "StellarAuth", "StellarRemoteMedia", "StellarLocalMedia",
        "StellarMediaLibrary", "StellarMediaImaging",
        "StellarPosterWall", "StellarStorage", "StellarWebDAV",
      ]
    ),
    .executableTarget(
      name: "StellarMediaCLI",
      dependencies: ["StellarUserMediaSDK", "StellarSMB2Core", "StellarSMB2Apple"]
    ),
    .testTarget(
      name: "StellarUserMediaSDKTests",
      dependencies: [
        "StellarCore",
        "StellarAuth",
        "StellarRemoteMedia",
        "StellarLocalMedia",
        "StellarWebDAV",
        "StellarStorage",
        "StellarMediaLibrary",
        "StellarPosterWall",
        "StellarSMB2Core",
        "StellarSMB2Apple",
        "StellarMediaImaging",
        "StellarDiscMedia",
        "StellarUserMediaSDK",
        .product(name: "GRDB", package: "GRDB.swift"),
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)

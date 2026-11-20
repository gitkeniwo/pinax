// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Pinax",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "CatalogCore", targets: ["CatalogCore"]),
    .library(name: "PinaxUI", targets: ["PinaxUI"]),
    .executable(name: "pinax", targets: ["pinax"]),
  ],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
  ],
  targets: [
    .target(
      name: "CatalogCore",
      dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .target(
      name: "PinaxUI",
      dependencies: ["CatalogCore"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
      name: "pinax",
      dependencies: [
        "CatalogCore",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "CatalogCoreTests",
      dependencies: [
        "CatalogCore",
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      path: "Tests",
      exclude: ["PinaxUITests"],
      sources: ["CatalogCoreTests"],
      resources: [.copy("Fixtures")],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "PinaxUITests",
      dependencies: [
        "PinaxUI",
        "CatalogCore",
        "pinax",
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      path: "Tests",
      exclude: ["CatalogCoreTests", "Fixtures"],
      sources: ["PinaxUITests"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)

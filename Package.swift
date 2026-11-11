// swift-tools-version: 6.4
import PackageDescription

let swiftSettings: [SwiftSetting] = [
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .enableUpcomingFeature("InferIsolatedConformances"),
  .enableUpcomingFeature("ImmutableWeakCaptures"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("InternalImportsByDefault"),
  .strictMemorySafety()
]

let package = Package(
  name: "AviationMCP",
  platforms: [.macOS(.v27)],
  products: [.executable(name: "aviation-mcp", targets: ["Run"])],
  traits: [.trait(name: "Sentry", description: "Report defects through sentry-native on Linux.")],
  dependencies: [
    .package(
      url: "https://github.com/RISCfuture/SwiftNASR.git", from: "5.0.1"),
    .package(
      url: "https://github.com/RISCfuture/SwiftCIFP.git",
      from: "3.0.0"),
    .package(
      url: "https://github.com/RISCfuture/SwiftDOF.git",
      from: "3.0.0"),
    .package(
      url: "https://github.com/RISCfuture/SwiftACD.git",
      from: "0.4.0"),
    .package(
      url: "https://github.com/RISCfuture/SwiftMETAR.git",
      from: "5.0.0"),
    .package(
      url: "https://github.com/RISCfuture/SwiftGeographic.git",
      from: "1.1.0"),
    .package(url: "https://github.com/SF50-TOLD/SF50-Performance.git", exact: "2.0.1"),
    .package(url: "https://github.com/RISCfuture/MeasurementKit.git", from: "1.2.1"),

    .package(url: "https://github.com/vapor/vapor.git", from: "4.122.3"),
    .package(url: "https://github.com/RISCfuture/StreamingCSV.git", from: "3.0.0"),
    .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.20"),
    .package(url: "https://github.com/vapor/fluent.git", from: "4.13.0"),
    .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.14.0"),
    .package(url: "https://github.com/vapor/postgres-kit.git", from: "2.17.0"),
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1")
  ],
  targets: [
    .target(
      name: "AviationMCP",
      dependencies: [
        .product(name: "SwiftNASR", package: "SwiftNASR"),
        .product(name: "StreamingCSV", package: "StreamingCSV"),
        .product(name: "ZIPFoundation", package: "ZIPFoundation"),
        .product(name: "SwiftCIFP", package: "SwiftCIFP"),
        .product(name: "SwiftDOF", package: "SwiftDOF"),
        .product(name: "SwiftACD", package: "SwiftACD"),
        .product(name: "SwiftMETAR", package: "SwiftMETAR"),
        .product(name: "SwiftGeographic", package: "SwiftGeographic"),
        .product(name: "AircraftPerformance", package: "SF50-Performance"),
        .product(name: "MeasurementKit", package: "MeasurementKit"),
        .product(name: "Vapor", package: "vapor"),
        .product(name: "Fluent", package: "fluent"),
        .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
        .product(name: "PostgresKit", package: "postgres-kit"),
        .product(name: "MCP", package: "swift-sdk"),
        .target(name: "CSentry", condition: .when(platforms: [.linux], traits: ["Sentry"]))
      ],
      swiftSettings: swiftSettings
    ),
    .systemLibrary(name: "CSentry", path: "Sources/CSentry"),
    .executableTarget(
      name: "Run",
      dependencies: ["AviationMCP", .product(name: "Vapor", package: "vapor")],
      swiftSettings: swiftSettings
    ),
    .testTarget(
      name: "AviationMCPTests",
      dependencies: [
        "AviationMCP",
        .product(name: "MeasurementKit", package: "MeasurementKit"),
        .product(name: "AircraftPerformance", package: "SF50-Performance"),
        .product(name: "VaporTesting", package: "vapor")
      ],
      resources: [.copy("Fixtures")],
      swiftSettings: swiftSettings
    )
  ],
  swiftLanguageModes: [.v6]
)

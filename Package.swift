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
  dependencies: [
    .package(
      url: "https://github.com/RISCfuture/SwiftNASR.git",
      revision: "a4d56cc686e148460a200eeff5751c2beed36847"),
    .package(
      url: "https://github.com/RISCfuture/SwiftCIFP.git",
      revision: "d57301f98db1b850b9c57d823c7f7dcf996fc730"),
    .package(
      url: "https://github.com/RISCfuture/SwiftDOF.git",
      revision: "5afe24c34e7ee72c9f31ae8ac23e754bc6ba1217"),
    .package(
      url: "https://github.com/RISCfuture/SwiftACD.git",
      revision: "2d01856fb7b78b11fe614e01b5c4c4483add09f6"),
    .package(
      url: "https://github.com/RISCfuture/SwiftMETAR.git",
      revision: "649e70912e0c1cc21c275545bd26af126bd79326"),
    .package(
      url: "https://github.com/RISCfuture/SwiftGeographic.git",
      revision: "5b166c0730dc3dd7ba85242ab2696556202d73a9"),

    .package(url: "https://github.com/vapor/vapor.git", exact: "4.122.3"),
    .package(url: "https://github.com/RISCfuture/StreamingCSV.git", exact: "3.0.0"),
    .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
    .package(url: "https://github.com/vapor/fluent.git", exact: "4.13.0"),
    .package(url: "https://github.com/vapor/fluent-postgres-driver.git", exact: "2.14.0"),
    .package(url: "https://github.com/vapor/postgres-kit.git", exact: "2.17.0"),
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")
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
        .product(name: "Vapor", package: "vapor"),
        .product(name: "Fluent", package: "fluent"),
        .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
        .product(name: "PostgresKit", package: "postgres-kit"),
        .product(name: "MCP", package: "swift-sdk")
      ],
      swiftSettings: swiftSettings
    ),
    .executableTarget(
      name: "Run",
      dependencies: ["AviationMCP", .product(name: "Vapor", package: "vapor")],
      swiftSettings: swiftSettings
    ),
    .testTarget(
      name: "AviationMCPTests",
      dependencies: ["AviationMCP", .product(name: "VaporTesting", package: "vapor")],
      resources: [.copy("Fixtures")],
      swiftSettings: swiftSettings
    )
  ],
  swiftLanguageModes: [.v6]
)

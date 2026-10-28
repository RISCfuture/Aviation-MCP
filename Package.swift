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
      revision: "2391caf97a98bce449c105db7ac75250f7ef5476"),
    .package(
      url: "https://github.com/RISCfuture/SwiftCIFP.git",
      revision: "e80a87c3b8edba9cd60ad00bf69b1aa4e164af46"),
    .package(
      url: "https://github.com/RISCfuture/SwiftDOF.git",
      revision: "5630d134e371347c5302f0d0b17440103dbacbf8"),
    .package(
      url: "https://github.com/RISCfuture/SwiftACD.git",
      revision: "9c70df543447d3c886211aa3669fead87ce41258"),
    .package(
      url: "https://github.com/RISCfuture/SwiftMETAR.git",
      revision: "c50ef10be12bc1a425c02861b44dcb23bf31bfc1"),
    .package(
      url: "https://github.com/RISCfuture/SwiftGeographic.git",
      revision: "2efa7ed75bea27a4a3696abe17b8596d3c023ab6"),

    .package(url: "https://github.com/vapor/vapor.git", exact: "4.122.3"),
    .package(url: "https://github.com/RISCfuture/StreamingCSV.git", exact: "2.1.2"),
    .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
    .package(url: "https://github.com/vapor/fluent.git", exact: "4.13.0"),
    .package(url: "https://github.com/vapor/fluent-postgres-driver.git", exact: "2.14.0"),
    .package(
      url: "https://github.com/modelcontextprotocol/swift-sdk.git",
      revision: "68300d7130f95a031284177c89e1e32fe32e7d82"
    )
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
      swiftSettings: swiftSettings
    )
  ],
  swiftLanguageModes: [.v6]
)

import Fluent
import FluentPostgresDriver
import Foundation
import MCP
import SQLKit
import Testing
import VaporTesting

@testable import AviationMCP

extension AviationRecord {
  static func fixture(_ version: SourceVersion) -> Self {
    Self(
      versionID: version.id, kind: "fixture", id: "fixture", identifier: "FIXTURE", name: "Fixture")
  }
}

extension `Transactional publication` {
  static func publishDepartureAirport(_ store: AviationStore, position: Value) async throws {
    let nasr = Self.version(.nasr)
    let cifp = Self.version(.cifp)
    var airport = AviationRecord(
      versionID: nasr.id, kind: "airport", id: "OAK",
      identifier: "KOAK", name: "Oakland")
    airport.data["runways"] = .array([
      .object([
        "ends": .array([
          .object(["identifier": "29", "departure_end": position])
        ])
      ])
    ])
    try await store.publish([nasr, cifp], records: [airport, .fixture(cifp)])
  }

  func withDatabase(_ operation: @Sendable (AviationStore) async throws -> Void) async throws {
    let url = try #require(ProcessInfo.processInfo.environment["TEST_DATABASE_URL"])
    try await withApp { app in
      app.databases.use(try .postgres(url: url), as: .psql)
      let sql = try app.db.sqlDatabase()
      try await sql.raw("DROP SCHEMA public CASCADE").run()
      try await sql.raw("CREATE SCHEMA public").run()
      try await AviationSchema().prepare(on: app.db)
      try await operation(AviationStore(database: app.db))
    }
  }

  static func version(_ source: SourceName) -> SourceVersion {
    SourceVersion(
      id: UUID(), source: source, cycle: "fixture",
      effectiveFrom: Date(timeIntervalSince1970: 0),
      effectiveUntil: source == .aircraft ? nil : Date(timeIntervalSince1970: 4_000_000_000),
      checksum: String(repeating: "a", count: 64), parserRevision: "fixture", validated: true)
  }

  static func airportWithMixedRunways(_ version: SourceVersion) -> AviationRecord {
    var airport = AviationRecord(
      versionID: version.id, kind: "airport", id: "OAK", identifier: "KOAK", name: "Oakland")
    airport.data = [
      "public_use": true, "facility_type": "AIRPORT", "maximum_runway_length_ft": 10000,
      "runways": .array([
        .object(["length_ft": 10000, "paved": false]),
        .object(["length_ft": 1000, "paved": true])
      ])
    ]
    return airport
  }
}

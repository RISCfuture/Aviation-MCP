import Fluent
import FluentPostgresDriver
import Foundation
import MCP
import SQLKit
import Testing
import VaporTesting

@testable import AviationMCP

actor ConnectionAttempts {
  private(set) var count = 0

  func advance() -> Int {
    count += 1
    return count
  }
}

extension AviationRecord {
  static func fixture(_ version: SourceVersion) -> Self {
    Self(
      versionID: version.id, kind: "fixture", id: "fixture", identifier: "FIXTURE", name: "Fixture")
  }
}

extension `Transactional publication` {
  static func publishObstacles(_ store: AviationStore) async throws -> Value {
    let version = Self.version(.dof)
    let position: Value = .object([
      "type": "Point", "coordinates": .array([.double(-122.2), .double(37.7)])
    ])
    var low = AviationRecord(
      versionID: version.id, kind: "obstacle", id: "low", identifier: "LOW", name: "Low")
    low.elevationMSLFeet = 100
    low.heightAGLFeet = 90
    low.geometry = position
    var high = AviationRecord(
      versionID: version.id, kind: "obstacle", id: "high", identifier: "HIGH", name: "High")
    high.elevationMSLFeet = 200
    high.heightAGLFeet = 20
    high.geometry = position
    try await store.publish([version], records: [low, high])
    return position
  }

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

extension `Transactional publication` {
  static func prepareNOTAMs(on sql: any SQLDatabase) async throws {
    try await sql.raw(
      """
      CREATE TABLE notams(notam_id text, icao_location text, effective_start timestamptz,
        effective_end timestamptz, schedule text, notam_text text, scope text,
        updated_at timestamptz DEFAULT now(), q_line jsonb)
      """
    ).run()
    try await sql.raw(
      """
      CREATE TABLE ingestion_state(key text, value text, updated_at timestamptz DEFAULT now())
      """
    ).run()
    try await sql.raw(
      """
      INSERT INTO notams VALUES
        ('A','KSFO','2026-10-28','2026-10-30','DAILY 0800-1000','RWY 28L CLOSED','A',now(),NULL),
        ('B','KSFO','2026-10-28',NULL,NULL,'APRON CONSTRUCTION',NULL,now(),NULL),
        ('C','KSFO','2026-10-30',NULL,NULL,'FUTURE WORK','A',now(),NULL)
      """
    ).run()
    let timestamp = ISO8601DateFormatter()
    timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    try await sql.raw(
      "INSERT INTO ingestion_state(key,value) VALUES ('last_poll_time',\(bind: timestamp.string(from: .now)))"
    ).run()
  }
}

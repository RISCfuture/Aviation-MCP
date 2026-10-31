import Fluent
import Foundation
import MCP
import SQLKit
import Testing

@testable import AviationMCP

extension `Transactional publication` {
  @Test
  func `matches airports by FAA or ICAO identifier across datasets`() async throws {
    try await withDatabase { store in
      try await Self.publishSanFranciscoRecords(store)
      let queries = PeriodicQueries(store: store)
      func identifiers(_ kinds: [String], _ source: SourceName, _ values: [String: Value])
        async throws -> [String]
      {
        try await queries.search(kinds: kinds, sources: [source], arguments: ToolArguments(values))
          .results.compactMap { $0.objectValue?["identifier"]?.stringValue }
      }
      let routes = ["preferred_route", "coded_departure_route"]
      #expect(try await identifiers(["ils"], .nasr, ["airport": "KSFO"]) == ["ISFO"])
      #expect(try await identifiers(["procedure"], .cifp, ["airport": "SFO"]) == ["GOSHI3"])
      #expect(try await identifiers(routes, .nasr, ["airport": "SFO"]) == ["LAXSFO", "SFOLAX"])
      #expect(try await identifiers(routes, .nasr, ["origin": "SFO"]) == ["SFOLAX"])
      #expect(try await identifiers(routes, .nasr, ["destination": "KSFO"]) == ["LAXSFO"])
      let unknown = try await queries.search(
        kinds: ["ils"], sources: [.nasr], arguments: ToolArguments(["airport": "ZZZZ"]))
      #expect(unknown.results.isEmpty)
      #expect(unknown.warnings.contains { $0.contains("No airport ZZZZ") })
    }
  }

  @Test
  func `orders coordinate searches nearest first and searches names by substring`() async throws {
    try await withDatabase { store in
      try await Self.publishSanFranciscoRecords(store)
      let queries = PeriodicQueries(store: store)
      let nearest = try await queries.search(
        kinds: ["airport"], sources: [.nasr],
        arguments: ToolArguments(["latitude": 37.6, "longitude": -122.4, "limit": 1]))
      let airport = try #require(nearest.results.first?.objectValue)
      #expect(airport["identifier"] == "KSFO")
      #expect((1...2).contains(try #require(airport["distance_nm"]?.doubleValue)))
      let named = try await queries.search(
        kinds: ["airport"], sources: [.nasr], arguments: ToolArguments(["query": "fRaN"]))
      #expect(named.results.compactMap { $0.objectValue?["identifier"] } == ["KSFO"])
      await #expect(throws: MCPError.self) {
        try await queries.search(
          kinds: ["airport"], sources: [.nasr], arguments: ToolArguments(["query": "sf"]))
      }
    }
  }

  @Test
  func `finds airspace containing a position or crossed by a route at an altitude`() async throws {
    try await withDatabase { store in
      try await Self.publishRiversideAirspace(store)
      let queries = PeriodicQueries(store: store)
      func containing(_ values: [String: Value]) async throws -> [String] {
        try await queries.search(
          kinds: ["airspace"], sources: [.nasr, .cifp], arguments: ToolArguments(values)
        ).results.compactMap(\.objectValue).filter { $0["intersects"] == true }
          .compactMap { $0["id"]?.stringValue }.sorted()
      }
      let center = GeoPoint(latitude: 33.881_94, longitude: -117.259_01)
      let east = Geodesy.destination(from: center, courseDeg: 100, distanceNM: 7.5)
      let classC = "controlled/K2/KRIV/C/"
      #expect(
        try await containing(Self.position(center, altitude: 3000)) == [
          classC + "A/RIVERSIDE MARCH FIELD", "controlled/K2/KRIV/D/A/RIVERSIDE MARCH FIELD"
        ])
      #expect(try await containing(Self.position(center, altitude: 6000)).isEmpty)
      #expect(try await containing(Self.position(east, altitude: 3000)).isEmpty)
      #expect(
        try await containing(Self.position(east, altitude: 4500)) == [
          classC + "B/RIVERSIDE MARCH FIELD"
        ])
      let crossing = try await containing([
        "route": .array([.array([-117.6, 33.88]), .array([-116.9, 33.88])]), "altitude_ft": 4500
      ])
      #expect(crossing.contains(classC + "A/RIVERSIDE MARCH FIELD"))
      #expect(!crossing.contains("controlled/K2/KRIV/D/A/RIVERSIDE MARCH FIELD"))
      let byAirport = try await queries.search(
        kinds: ["airspace"], sources: [.nasr, .cifp], arguments: ToolArguments(["airport": "RIV"]))
      #expect(byAirport.results.count == 5)
    }
  }
}

extension `Transactional publication` {

  @Test
  func `includes overlapping NOTAMs and preserves uncertain schedules and context`() async throws {
    try await withDatabase { store in
      let sql = try store.database.sqlDatabase()
      try await Self.prepareNOTAMs(on: sql)
      try await Self.publishOaklandCenter(store)
      let queries = NOTAMQueries(database: store.database)
      func search(_ values: [String: Value]) async throws -> ToolResult {
        let arguments = ToolArguments(values)
        return try await queries.search(
          arguments, area: NOTAMArea.resolve(arguments, store: store))
      }
      let window: [String: Value] = [
        "location": "SFO", "start": "2026-10-29T15:00:00Z", "end": "2026-10-29T19:00:00Z"
      ]
      let area = try await search(
        window.merging(["procedure": "apron  construction"]) { _, new in new })
      #expect(area.results.compactMap { $0.objectValue?["id"] } == ["B", "A", "D"])
      #expect(area.results.first?.objectValue?["context_match"] == "text_match")
      #expect(area.results.last?.objectValue?["area_match"] == "overlying_artcc")
      let runway = try await search(window.merging(["runway": "8L"]) { _, new in new })
      #expect(runway.results.allSatisfy { $0.objectValue?["context_match"] == "uncertain" })
      let result = try await search(
        window.merging(["scope": "A", "runway": "28L"]) { _, new in new })
      #expect(result.results.count == 2)
      #expect(result.completeness == "partial")
      #expect(result.results.first?.objectValue?["schedule"] == "DAILY 0800-1000")
      #expect(result.results.first?.objectValue?["context_match"] == "text_match")
      #expect(result.results.last?.objectValue?["context_match"] == "uncertain")
      #expect(result.results.last?.objectValue?["scope_match"] == "uncertain")
      #expect(result.results.last?.objectValue?["scope_explanation"]?.stringValue?.isEmpty == false)
      #expect(result.liveSources.first?.provider == "notams")
      #expect(!result.warnings.contains { $0.contains("freshness") })
      var page: [String: Value] = [
        "location": "KSFO", "start": "2026-10-29T15:00:00.000Z", "end": "2026-10-29T19:00:00Z",
        "limit": 1
      ]
      let first = try await search(page)
      page["cursor"] = .string(try #require(first.nextCursor))
      try await sql.raw(
        "UPDATE notams SET updated_at = now() + INTERVAL '1 hour' WHERE notam_id IN ('C', 'E')"
      ).run()
      let second = try await search(page)
      #expect(second.results.first?.objectValue?["id"] == "B")
      try await sql.raw(
        "UPDATE notams SET updated_at = now() + INTERVAL '2 hours' WHERE notam_id = 'B'"
      ).run()
      let continuation = page
      await #expect(throws: StorageError.self) {
        try await search(continuation)
      }
    }
  }

}

extension `Transactional publication` {
  static func position(_ point: GeoPoint, altitude: Double) -> [String: Value] {
    [
      "latitude": .double(point.latitude), "longitude": .double(point.longitude),
      "altitude_ft": .double(altitude), "radius_nm": 1
    ]
  }

  static func airport(
    _ version: SourceVersion, icao: String, lid: String, name: String, at point: GeoPoint
  ) -> AviationRecord {
    var airport = AviationRecord(
      versionID: version.id, kind: "airport", id: lid, identifier: icao, name: name, airport: icao)
    airport.geometry = Normalization.point(latitude: point.latitude, longitude: point.longitude)
    airport.data = ["faa_lid": .string(lid), "icao_identifier": .string(icao)]
    return airport
  }

  static func publishSanFranciscoRecords(_ store: AviationStore) async throws {
    let nasr = version(.nasr)
    let cifp = version(.cifp)
    var ils = AviationRecord(
      versionID: nasr.id, kind: "ils", id: "ISFO", identifier: "ISFO", name: "SFO ILS",
      airport: "SFO")
    ils.geometry = Normalization.point(latitude: 37.6, longitude: -122.4)
    var preferred = AviationRecord(
      versionID: nasr.id, kind: "preferred_route", id: "LAXSFO", identifier: "LAXSFO",
      name: "LAX to SFO", airport: "LAX")
    preferred.data = ["origin": "LAX", "destination": "SFO"]
    var coded = AviationRecord(
      versionID: nasr.id, kind: "coded_departure_route", id: "SFOLAX", identifier: "SFOLAX",
      name: "KSFO PORTE3 KLAX", airport: "KSFO")
    coded.data = ["origin": "KSFO", "destination": "KLAX"]
    let procedure = AviationRecord(
      versionID: cifp.id, kind: "procedure", id: "KSFO/departure/GOSHI3", identifier: "GOSHI3",
      name: "KSFO GOSHI3", airport: "KSFO")
    try await store.publish(
      [nasr, cifp],
      records: [
        airport(
          nasr, icao: "KSFO", lid: "SFO", name: "San Francisco Intl",
          at: GeoPoint(latitude: 37.619, longitude: -122.375)),
        airport(
          nasr, icao: "KOAK", lid: "OAK", name: "Metropolitan Oakland Intl",
          at: GeoPoint(latitude: 37.721, longitude: -122.221)),
        ils, preferred, coded, procedure
      ])
  }

  /// Publishes KSFO beneath an Oakland Center polygon, for overlying-ARTCC NOTAM searches.
  static func publishOaklandCenter(_ store: AviationStore) async throws {
    let nasr = version(.nasr)
    let cifp = version(.cifp)
    var center = AviationRecord(
      versionID: nasr.id, kind: "artcc_airspace", id: "ZOA/LOW", identifier: "ZOA",
      name: "OAKLAND CENTER LOW")
    center.geometry = AirspacePolygon.geometry(rings: [
      [
        GeoPoint(latitude: 36, longitude: -124), GeoPoint(latitude: 39, longitude: -124),
        GeoPoint(latitude: 39, longitude: -121), GeoPoint(latitude: 36, longitude: -121)
      ]
    ])
    var facility = AviationRecord(
      versionID: nasr.id, kind: "artcc", id: "ZOA", identifier: "ZOA", name: "OAKLAND")
    facility.data = ["icao_identifier": "KZOA"]
    try await store.publish(
      [nasr, cifp],
      records: [
        airport(
          nasr, icao: "KSFO", lid: "SFO", name: "San Francisco Intl",
          at: GeoPoint(latitude: 37.619, longitude: -122.375)),
        center, facility, .fixture(cifp)
      ])
  }

  /// Publishes the Riverside March Field airspace from the KHAF CIFP fixture under current
  /// fixture versions.
  static func publishRiversideAirspace(_ store: AviationStore) async throws {
    let fixture = try #require(
      Bundle.module.url(forResource: "KHAF", withExtension: "cifp", subdirectory: "Fixtures"))
    let parsed = try await CIFPImporter.parse(Data(contentsOf: fixture))
    let nasr = version(.nasr)
    let cifp = version(.cifp)
    let airspace = parsed.records.filter { $0.kind == "airspace" }.map { record in
      AviationRecord(
        versionID: cifp.id, kind: record.kind, id: record.id, identifier: record.identifier,
        name: record.name, airport: record.airport, geometry: record.geometry, data: record.data)
    }
    try await store.publish(
      [nasr, cifp],
      records: airspace + [
        airport(
          nasr, icao: "KRIV", lid: "RIV", name: "March ARB",
          at: GeoPoint(latitude: 33.880, longitude: -117.259))
      ])
  }
}

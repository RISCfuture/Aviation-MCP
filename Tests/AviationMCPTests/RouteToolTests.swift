import Foundation
import MCP
import Testing

@testable import AviationMCP

extension `Transactional publication` {
  @Test
  func `resolves an airway route to the points get_airway returns, with measured legs`()
    async throws
  {
    try await withDatabase { store in
      let catalog = Self.routeCatalog(store)
      try await Self.publishRoute(store)
      let response = try await catalog.call(
        .init(name: "resolve_route", arguments: ["route_string": "SNS V25 PRB"]))
      let content = try #require(response.structuredContent?.objectValue)
      #expect(response.isError != true)
      #expect(content["completeness"] == "complete")
      #expect(content["sources"]?.arrayValue?.map { $0.objectValue?["source"] } == ["nasr"])
      let route = try #require(Self.results(response).first?.objectValue)
      let legs = (route["legs"]?.arrayValue ?? []).compactMap { $0.objectValue }
      #expect(legs.map { $0["to"] } == ["MID", "PRB"])
      #expect(legs.map { $0["via"] } == ["V25", "V25"])
      #expect(legs.first?["published_distance_nm"] == 30)
      #expect(legs.first?["path_index"] == 0)
      #expect(legs.last?["start_point_index"] == 1)
      // SNS to MID is about 36.7 NM along a course a little east of southeast.
      let distance = try #require(legs.first?["distance_nm"]?.number)
      #expect((36...37.5).contains(distance))
      let course = try #require(legs.first?["initial_course_true_deg"]?.number)
      #expect((135...145).contains(course))
      let total = try #require(route["total_distance_nm"]?.number)
      #expect(abs(total - legs.compactMap { $0["distance_nm"]?.number }.reduce(0, +)) < 0.02)
      #expect(route["distance_complete"] == true)
      let path = try #require(route["paths"]?.arrayValue?.first?.arrayValue)
      #expect(path == [[-121.6, 36.66], [-121.1, 36.2], [-120.63, 35.67]])

      let airway = try await catalog.call(
        .init(
          name: "get_airway",
          arguments: ["identifier": "V25", "entry_fix": "PRB", "exit_fix": "SNS"]))
      let segments = try #require(
        Self.results(airway).first?.objectValue?["segments"]?.arrayValue)
      let reversed = try await catalog.call(
        .init(name: "resolve_route", arguments: ["route_string": "PRB V25 SNS"]))
      let reversedPath = try #require(
        Self.results(reversed).first?.objectValue?["paths"]?.arrayValue?.first?.arrayValue)
      #expect(
        reversedPath == segments.map { $0.objectValue?["position"]?.objectValue?["coordinates"] })

      let airspace = try await catalog.call(
        .init(name: "query_airspace", arguments: ["route": .array(path), "radius_nm": 1]))
      #expect(airspace.isError != true)
      #expect(Self.results(airspace).first?.objectValue?["identifier"] == "TESTAREA")
    }
  }

  @Test
  func `returns candidates, accepts a selection and reads CIFP only for a procedure`()
    async throws
  {
    try await withDatabase { store in
      let catalog = Self.routeCatalog(store)
      try await Self.publishRoute(store)
      let ambiguous = try await catalog.call(
        .init(name: "resolve_route", arguments: ["route_string": "KOAK DUPE PRB"]))
      let content = try #require(ambiguous.structuredContent?.objectValue)
      #expect(ambiguous.isError != true)
      #expect(content["completeness"] == "partial")
      let elements = try #require(
        Self.results(ambiguous).first?.objectValue?["elements"]?.arrayValue)
      #expect(elements[0].objectValue?["kind"] == "airport")
      let candidates = try #require(elements[1].objectValue?["candidates"]?.arrayValue)
      #expect(candidates.count == 2)
      #expect(Self.results(ambiguous).first?.objectValue?["distance_complete"] == false)

      let selected = try await catalog.call(
        .init(
          name: "resolve_route",
          arguments: [
            "route_string": "OAK DUPE PRB", "include_geometry": true,
            "selections": [["index": 1, "record_id": "DUPE/near"]]
          ]))
      let resolved = try #require(Self.results(selected).first?.objectValue)
      #expect(selected.structuredContent?.objectValue?["completeness"] == "complete")
      #expect(resolved["paths"]?.arrayValue?.first?.arrayValue?.count == 3)
      #expect(resolved["geometry"]?.objectValue?["type"] != nil)

      let rejected = try await catalog.call(
        .init(
          name: "resolve_route",
          arguments: [
            "route_string": "OAK DUPE PRB", "selections": [["index": 1, "record_id": "SNS"]]
          ]))
      #expect(
        rejected.structuredContent?.objectValue?["error"]?.objectValue?["code"]
          == "invalid_argument")
      let unsupported = try await catalog.call(
        .init(name: "resolve_route", arguments: ["route_string": "SNS V25 PRB", "limit": 5]))
      #expect(unsupported.isError == true)

      let departure = try await catalog.call(
        .init(
          name: "resolve_route",
          arguments: ["route_string": "KOAK TEST1.SNS V25 PRB", "departure_runway": "28R"]))
      let sources = departure.structuredContent?.objectValue?["sources"]?.arrayValue
      #expect(
        Set(sources?.compactMap { $0.objectValue?["source"]?.stringValue } ?? []) == [
          "nasr", "cifp"
        ])
      let flown = try #require(Self.results(departure).first?.objectValue)
      #expect(departure.structuredContent?.objectValue?["completeness"] == "complete")
      #expect(
        flown["legs"]?.arrayValue?.map { $0.objectValue?["to"] } == [
          "RW28R", "JOIN", "SNS", "MID", "PRB"
        ])
      #expect(
        flown["elements"]?.arrayValue?.map { $0.objectValue?["kind"] } == [
          "airport", "departure", "procedure_fix", "airway", "airway_point"
        ])
    }
  }

  static func routeCatalog(_ store: AviationStore) -> ToolCatalog {
    ToolCatalog(
      store: store, groups: [.navigation, .airspace],
      weather: WeatherService(awc: nil, openMeteo: nil), notams: nil)
  }

  /// Publishes KOAK, the V25 airway from SNS through MID to PRB, a duplicated fix, a departure
  /// from KOAK ending at SNS, and an airspace polygon around MID.
  static func publishRoute(_ store: AviationStore) async throws {
    let nasr = Self.version(.nasr)
    let cifp = Self.version(.cifp)
    func point(
      _ kind: String, _ id: String, _ identifier: String, _ latitude: Double, _ longitude: Double
    ) -> AviationRecord {
      var record = AviationRecord(
        versionID: nasr.id, kind: kind, id: id, identifier: identifier, name: identifier)
      record.geometry = Normalization.point(latitude: latitude, longitude: longitude)
      return record
    }
    var airport = point("airport", "OAK", "KOAK", 37.72, -122.22)
    airport.data["faa_lid"] = "OAK"
    var airway = AviationRecord(
      versionID: nasr.id, kind: "airway", id: "V25", identifier: "V25", name: "V25")
    airway.data["segments"] = .array(
      [("SNS", 36.66, -121.6, 30), ("MID", 36.2, -121.1, 25), ("PRB", 35.67, -120.63, 0)]
        .enumerated().map { sequence, fix in
          .object([
            "identifier": .string(fix.0), "sequence": .int(sequence * 10),
            "position": Normalization.point(latitude: fix.1, longitude: fix.2),
            "distance_to_next_nm": .int(fix.3)
          ])
        })
    var airspace = AviationRecord(
      versionID: nasr.id, kind: "airspace", id: "TESTAREA", identifier: "TESTAREA",
      name: "Test area")
    airspace.geometry = .object([
      "type": "Polygon",
      "coordinates": [
        [[-121.2, 36.1], [-121.0, 36.1], [-121.0, 36.3], [-121.2, 36.3], [-121.2, 36.1]]
      ]
    ])
    let parts: [(transition: String?, fixes: [(String, Double, Double)])] = [
      ("RW28R", [("RW28R", 37.71, -122.23)]),
      (nil, [("RW28R", 37.71, -122.23), ("JOIN", 37.3, -122)]),
      ("SNS", [("JOIN", 37.3, -122), ("SNS", 36.66, -121.6)])
    ]
    let procedures = parts.map { transition, fixes in
      var record = AviationRecord(
        versionID: cifp.id, kind: "procedure", id: "KOAK/TEST1/\(transition ?? "")",
        identifier: "TEST1", name: "KOAK TEST1", airport: "KOAK")
      record.data = [
        "airport": "KOAK", "procedure_type": "departure",
        "legs": .array(
          fixes.enumerated().map { sequence, fix in
            .object([
              "sequence": .int(sequence), "fix": .string(fix.0),
              "path_terminator": sequence == 0 ? "IF" : "TF",
              "position": Normalization.point(latitude: fix.1, longitude: fix.2)
            ])
          })
      ]
      record.data["transition"] = transition.map(Value.string)
      return record
    }
    try await store.publish(
      [nasr, cifp],
      records: [
        airport, airway, airspace, point("navaid", "SNS", "SNS", 36.66, -121.6),
        point("navaid", "PRB", "PRB", 35.67, -120.63),
        point("fix", "DUPE/near", "DUPE", 36.5, -121.5),
        point("fix", "DUPE/far", "DUPE", 45, -100)
      ] + procedures)
  }
}

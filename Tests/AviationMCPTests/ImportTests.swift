import Foundation
import MCP
import SwiftACD
import SwiftCIFP
import SwiftNASR
import Testing

@testable import AviationMCP

@Suite
struct `Normalized source imports` {
  @Test
  func `discovers current and next cycles without treating DOF currency as release`() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-10-28T12:00:00Z"))
    let nasr = try SourceDiscovery.navigation("nasr", at: now)
    let cifp = try SourceDiscovery.navigation("cifp", at: now)
    #expect(nasr.map(\.effectiveFrom) == cifp.map(\.effectiveFrom))
    #expect(nasr.map(\.cycle) == ["2026-10-01", "2026-10-29"])
    #expect(nasr[1].url.hasSuffix("29_Oct_2026_CSV.zip"))
    let html = """
      <table><tr><th>Release Date</th></tr>
      <tr><td><a href="https://aeronav.faa.gov/Obst_Data/DOF_260927.zip">DOF</a></td>
      <td>August 03, 2026</td><td>September 27, 2026</td><td>September 29, 2026</td></tr>
      <tr><td>DOF (Next)</td><td>September 28, 2026</td><td>November 22, 2026</td>
      <td>November 24, 2026</td></tr></table>
      """
    let dof = try SourceDiscovery.obstacles(html, at: now)
    #expect(dof.count == 1)
    #expect(dof[0].effectiveFrom == "2026-09-29T00:00:00Z")
    #expect(dof[0].effectiveUntil == "2026-11-24T00:00:00Z")
    #expect(throws: SourceDiscoveryError.self) {
      try SourceDiscovery.obstacles("<table><tr><td>unrecognized layout</td></tr></table>", at: now)
    }
    let aircraft = try SourceDiscovery.aircraft(lastModified: "Fri, 03 Jan 2025 16:14:25 GMT")
    #expect(aircraft.effectiveUntil == nil)
    try RemoteIngestion.validate([aircraft])
    var version = SourceVersion(
      id: UUID(), source: .aircraft, cycle: aircraft.cycle, effectiveFrom: now, effectiveUntil: nil,
      checksum: "fixture", parserRevision: AircraftImporter.revision, validated: true)
    version.validation = ["download": try .encoded(aircraft)]
    #expect(RemoteIngestion.isPublished(aircraft, in: [version]))
    var changed = aircraft
    changed.etag = "updated"
    #expect(!RemoteIngestion.isPublished(changed, in: [version]))
    #expect(throws: StorageError.self) { try RemoteIngestion.validate([nasr[0]]) }
  }

  @Test
  func `normalizes NASR coordinates and preserves unrepresentable optional fields`() async throws {
    let csv = "\"EFF_DATE\",\"ARPT_ID\"\n\"2026/10/01\",\"OAK\"\n"
    let cycle = try await NASRCycle.parse(
      AsyncThrowingStream { continuation in
        continuation.yield(Data(csv.utf8))
        continuation.finish()
      })
    #expect(cycle.id == "2026-10-01")
    await #expect(throws: StorageError.self) {
      try await NASRCycle.parse(
        AsyncThrowingStream { continuation in
          continuation.yield(Data((csv + "\"2026/10/29\",\"SFO\"\n").utf8))
          continuation.finish()
        })
    }
    let point = NASRNormalization.point(.init(latitudeArcsec: 133200, longitudeArcsec: -440100))
    #expect(point.objectValue?["coordinates"] == .array([.double(-122.25), .double(37)]))
    #expect(NASRNormalization.altitude(.init(800, datum: .AGL)).objectValue?["datum"] == "AGL")
    var diagnostics = NASRDiagnostics()
    diagnostics.record(
      .fieldError(
        recordType: .airports, recordID: "test", field: "runway[H1].materials",
        value: "OR", underlying: StorageError.invalidImport("Unknown material")))
    var airport = AviationRecord(
      versionID: UUID(), kind: "airport", id: "test", identifier: "OR83", name: "Heliport")
    airport.data["runways"] = .array([.object(["identifier": "H1", "paved": true])])
    let result = diagnostics.applying(to: [airport])
    #expect(result[0].data["runways"]?.arrayValue?.first?.objectValue?["paved"] == .null)
    #expect(result[0].data["source_warnings"]?.arrayValue?.count == 1)
    diagnostics.record(
      .recordError(
        recordType: .airports, recordID: "other",
        underlying: StorageError.invalidImport("Missing coordinate")))
    #expect(diagnostics.applying(to: [airport]).count == 1)
    diagnostics.record(
      .recordError(
        recordType: .airways, recordID: nil,
        underlying: StorageError.invalidImport("Rejected airway segment")))
    var airway = AviationRecord(
      versionID: UUID(), kind: "airway", id: "V23/federal", identifier: "V23", name: "V23")
    airway.geometry = .object([
      "type": "LineString", "coordinates": .array([.array([-122, 37]), .array([-123, 38])])
    ])
    let partialAirway = diagnostics.applying(to: [airway])[0]
    #expect(partialAirway.geometry == nil)
    #expect(partialAirway.data["source_warnings"]?.arrayValue?.count == 1)
  }

  @Test
  func `preserves procedure constraints and breaks geometry at unresolved legs`() throws {
    let encoded = """
      {"sequenceNumber":10,"fixId":"IAF","pathTerminator":"IF","isTurnDirectionValid":false}
      """
    var fields = try JSONDecoder().decode([String: Value].self, from: Data(encoded.utf8))
    fields["altitudeConstraint"] = try .encoded(AltitudeConstraint.atOrAbove(.feet(3000, .msl)))
    fields["speedConstraint"] = try .encoded(SpeedConstraint.atOrBelow(knots: 210))
    fields["course"] = .object(["degrees": 123, "reference": "T"])
    fields["length"] = try .encoded(
      ProcedureLeg.Length.time(.init(value: 90, unit: .seconds)))
    fields["waypointDescription"] = .object([
      "fixType": try .encoded(WaypointDescriptionCode.FixType.essential),
      "approachRole": try .encoded(WaypointDescriptionCode.ApproachRole.initialApproachFix)
    ])
    let leg = try JSONDecoder().decode(ProcedureLeg.self, from: JSONEncoder().encode(fields))
    let value = CIFPRestrictions.leg(leg, coordinate: nil)
    #expect(value.objectValue?["altitude_constraint"]?.objectValue?["code"] == "+")
    #expect(
      value.objectValue?["altitude_constraint"]?.objectValue?["altitude"]?.objectValue?["datum"]
        == "MSL")
    #expect(value.objectValue?["speed_constraint"]?.objectValue?["knots"] == 210)
    #expect(
      CIFPRestrictions.altitude(.flightLevel(180)).objectValue?["datum"] == "standard_pressure")
    #expect(value.objectValue?["course"] == .object(["degrees": .double(123), "reference": "true"]))
    #expect(value.objectValue?["length"] == .object(["value": 1.5, "unit": "min"]))
    #expect(value.objectValue?["is_initial_approach_fix"] == true)
    #expect(value.objectValue?["waypoint_description"] == "E  A")
    let glideSlope = CIFPRestrictions.constraint(
      .atOrAboveWithGlideSlope(.feet(2000, .msl), glideSlope: .feet(2200, .msl)))
    #expect(glideSlope.objectValue?["altitude"]?.objectValue?["value"] == 2000)
    #expect(glideSlope.objectValue?["glide_slope_altitude"]?.objectValue?["value"] == 2200)
    #expect(glideSlope.objectValue?["upper"] == nil)
    var path = ProcedurePath()
    path.append(
      sequence: 10, terminator: "IF",
      coordinate: try JSONDecoder().decode(
        Coordinate.self, from: Data(#"{"latitudeDeg":37,"longitudeDeg":-122}"#.utf8)))
    path.append(
      sequence: 20, terminator: "TF",
      coordinate: try JSONDecoder().decode(
        Coordinate.self, from: Data(#"{"latitudeDeg":38,"longitudeDeg":-122}"#.utf8)))
    path.append(sequence: 30, terminator: "VM", coordinate: nil)
    path.append(
      sequence: 40, terminator: "TF",
      coordinate: try JSONDecoder().decode(
        Coordinate.self, from: Data(#"{"latitudeDeg":39,"longitudeDeg":-122}"#.utf8)))
    #expect(path.segments.count == 1)
    #expect(path.gaps.count == 2)
    #expect(path.geometry?.objectValue?["type"] == "MultiLineString")
  }

  @Test
  func `keeps obstacle datums separate and retains valid records from partial distributions`()
    throws
  {
    let source = """
      CURRENCY DATE = 09/27/26
      header
      header
      ---
      01-001459 O US AL DAUPHIN ISLAND   30 11 20.00N 088 07 15.00W RIG                1 00240 00241 \
      R 5 D M 1992ASO02229OE C 2014138
      """
    let start = try #require(ISO8601DateFormatter().date(from: "2026-09-29T00:00:00Z"))
    let end = try #require(ISO8601DateFormatter().date(from: "2026-11-24T00:00:00Z"))
    let batch = try DOFImporter.parse(Data(source.utf8), effectiveFrom: start, effectiveUntil: end)
    #expect(batch.versions.first?.effectiveFrom == start)
    #expect(batch.versions.first?.effectiveUntil == end)
    #expect(batch.records.first?.data["currency_date"] == "2026-09-27")
    let obstacle = try #require(batch.records.first)
    #expect(obstacle.elevationMSLFeet == 241)
    #expect(obstacle.heightAGLFeet == 240)
    #expect(obstacle.geometry?.objectValue?["type"] == "Point")
    #expect(batch.versions.first?.checksum.count == 64)
    let partial = try DOFImporter.parse(
      Data((source + "\nmalformed obstacle record").utf8), effectiveFrom: start,
      effectiveUntil: end)
    #expect(partial.records.count == 1)
    #expect(partial.versions.first?.validated == true)
    #expect(partial.versions.first?.validation?["parse_errors"]?.objectValue?["count"] == 1)
  }

  @Test
  func `withholds procedure geometry across rejected legs`() async throws {
    let fixture = try #require(
      Bundle.module.url(forResource: "KHAF", withExtension: "cifp", subdirectory: "Fixtures"))
    let source = try String(contentsOf: fixture, encoding: .utf8)
    let complete = try await CIFPImporter.parse(Data(source.utf8))
    #expect(complete.versions.first?.validated == true)
    let airspaces = complete.records.filter { $0.kind == "airspace" && $0.identifier == "KRIV" }
    #expect(Set(airspaces.compactMap { $0.data["class"]?.stringValue }) == ["C", "D"])
    #expect(Set(airspaces.map(\.id)).count == airspaces.count)
    let completeProcedure = try #require(complete.records.first { $0.kind == "procedure" })
    #expect(completeProcedure.geometry != nil)
    let corrupted = source.split(separator: "\n").map { line in
      guard line.contains("021MAVKC") else { return String(line) }
      var bytes = Array(line.utf8)
      bytes[118] = UInt8(ascii: "!")
      return String(bytes: bytes, encoding: .ascii) ?? ""
    }.joined(separator: "\r\n")
    let partial = try await CIFPImporter.parse(Data(corrupted.utf8))
    let procedure = try #require(partial.records.first { $0.kind == "procedure" })
    #expect(partial.versions.first?.parseErrorCount == 1)
    #expect(procedure.geometry == nil)
    #expect(procedure.data["source_warnings"]?.arrayValue?.count == 1)
    #expect(procedure.data["legs"]?.arrayValue?.isEmpty == false)
    #expect(procedure.data["geometry_scope"] == "unavailable_due_to_parse_errors")
  }

  @Test
  func `orders military centerlines and leaves missing positions disconnected`() throws {
    let route = try JSONDecoder().decode(
      MilitaryTrainingRoute.self,
      from: Data(
        #"""
        {"routeType":"IR","routeIdentifier":"1","ARTCCIdentifiers":[],"FSSIdentifiers":[],
         "operatingProcedures":[],"routeWidthDescriptions":["Width varies"],
         "terrainFollowingOperations":[],"agencies":[],"routePoints":[
          {"pointId":"B","sequenceNumber":20,"position":{"latitudeArcsec":136800,"longitudeArcsec":-439200}},
          {"pointId":"A","sequenceNumber":10,"position":{"latitudeArcsec":133200,"longitudeArcsec":-439200}},
          {"pointId":"C","sequenceNumber":30},
          {"pointId":"D","sequenceNumber":40,"position":{"latitudeArcsec":144000,"longitudeArcsec":-439200}}
         ]}
        """#.utf8))
    let record = try NASRAirspace.military(route, versionID: UUID())
    #expect(record.geometry?.objectValue?["coordinates"]?.arrayValue?.count == 1)
    #expect(record.data["geometry_gap_sequences"] == .array([20, 30]))
    #expect(record.data["geometry_scope"] == "centerline_only")
    #expect(record.data["width_descriptions"] == .array(["Width varies"]))
  }

  @Test
  func `preserves published aircraft categories for distinct variants`() throws {
    let variants = [AircraftApproachCategory.c, .d].map { category in
      Variant(
        id: category.rawValue, manufacturer: "Boeing", model: "737-800",
        approachSpeedKt: nil, dimensions: nil, weights: nil, categories: .init(approach: category))
    }
    let profile = AircraftProfile(
      identity: .init(ICAOTypeDesignator: "B738", manufacturer: "Boeing", model: "737-800"),
      categories: .init(approach: .c), dimensions: nil, weights: nil, recognition: nil,
      performance: nil,
      variants: variants, sources: .ACD)
    let record = try AircraftImporter.record(profile, versionID: UUID())
    #expect(record.identifier == "B738")
    let normalized = try #require(record.data["variants"]?.arrayValue)
    #expect(normalized.map { $0.objectValue?["approach_category"]?.stringValue } == ["C", "D"])
    #expect(record.data["category_requires_variant_selection"] == true)
    #expect(record.data["identity"] == nil)
  }
}

extension `Normalized source imports` {
  @Test
  func `stores each kind in spatial clusters with unpositioned records last`() {
    func record(_ kind: String, _ id: String, _ geometry: Value?) -> AviationRecord {
      var record = AviationRecord(
        versionID: UUID(), kind: kind, id: id, identifier: id, name: id)
      record.geometry = geometry
      return record
    }
    let ordered = SpatialOrder.sorted([
      record("obstacle", "unpositioned", nil),
      record("obstacle", "new-york", Normalization.point(latitude: 40.7, longitude: -74)),
      record("obstacle", "oakland", Normalization.point(latitude: 37.7, longitude: -122.2)),
      record("airport", "boston", .object(["type": "Point", "coordinates": [-71, 42]])),
      record(
        "obstacle", "san-carlos",
        .object([
          "type": "Polygon",
          "coordinates": [[[-122.25, 37.5], [-122.2, 37.5], [-122.2, 37.6], [-122.25, 37.5]]]
        ]))
    ]).map(\.id)
    #expect(ordered.first == "boston")
    #expect(Set(ordered[1...2]) == ["oakland", "san-carlos"])
    #expect(ordered[3...] == ["new-york", "unpositioned"])
  }

  @Test
  func `groups airport frequencies by facility and ignores other serviced facilities`()
    async throws
  {
    let csv = """
      "FACILITY","FACILITY_TYPE","TOWER_HRS","SERVICED_FACILITY","SERVICED_SITE_TYPE",\
      "TOWER_OR_COMM_CALL","PRIMARY_APPROACH_RADIO_CALL","FREQ","SECTORIZATION","FREQ_USE","REMARK"
      "NCT","TRACON","","SQL","AIRPORT","SAN CARLOS","NORCAL","135.65","","APCH/S",""
      "NCT","TRACON","","SQL","AIRPORT","SAN CARLOS","NORCAL","135.65","NW","DEP/P",""
      "SQL","ATCT","0700-2100","SQL","AIRPORT","SAN CARLOS","NORCAL","119.0","","LCL/P",""
      "SQL","ATCT","","SQL","AIRPORT","","","119.0","","CTAF","ACTVT MIRL - CTAF."
      "ZOA","RCAG","","ZOA","RCAG","","","122.1R","","SAN CARLOS RCO",""
      "SQL","NAVAID","","SQL","VORTAC","","","113.9","","VOR",""

      """
    let frequencies = try await NASRFrequencies.parse(
      AsyncThrowingStream { continuation in
        continuation.yield(Data(csv.utf8))
        continuation.finish()
      })
    let fields = frequencies.fields(forAirport: "SQL")
    #expect(fields["tower_hours"] == "0700-2100")
    #expect(fields["tower_call"] == "SAN CARLOS")
    #expect(fields["approach_call"] == "NORCAL")
    #expect(
      fields["frequencies"]
        == [
          ["facility": "NCT", "frequency_khz": 135650, "uses": ["APCH/S", "DEP/P (NW)"]],
          [
            "facility": "SQL", "frequency_khz": 119000, "uses": ["LCL/P", "CTAF"],
            "remarks": ["ACTVT MIRL - CTAF."]
          ]
        ])
    #expect(frequencies.fields(forAirport: "ZOA").isEmpty)
  }
}

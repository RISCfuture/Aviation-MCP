import Foundation
import MCP
import SwiftACD
import SwiftNASR
import Testing

@testable import AviationMCP

extension `Normalized source imports` {
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
    #expect(normalized.allSatisfy { $0.objectValue?["manufacturer"] == nil })
    #expect(record.data["contributing_sources"] == ["FAA ACD"])
    #expect(record.data["category_requires_variant_selection"] == true)
    #expect(record.data["identity"] == nil)
  }

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
          [
            "facility": "NCT", "frequency": ["value": 135.65, "unit": "MHz"],
            "uses": ["APCH/S", "DEP/P (NW)"]
          ],
          [
            "facility": "SQL", "frequency": ["value": 119.0, "unit": "MHz"],
            "uses": ["LCL/P", "CTAF"],
            "remarks": ["ACTVT MIRL - CTAF."]
          ]
        ])
    #expect(frequencies.fields(forAirport: "ZOA").isEmpty)
  }

  @Test
  func `withholds releases that lose record families or published records`() throws {
    var published = SourceVersion(
      id: UUID(), source: .nasr, cycle: "2026-10-29", effectiveFrom: .now, effectiveUntil: nil,
      checksum: "fixture", parserRevision: "fixture", validated: true)
    published.validation = ["record_counts": ["airport": 1000, "fix": 500, "fss": 10]]
    let gate = ReleaseCompleteness(snapshot: SourceSnapshot(versions: [.nasr: published]))
    let staged = { (counts: [String: Int], families: [String]) in
      var version = published
      version.validation = [
        ReleaseCompleteness.failedFamiliesKey: .array(families.map(Value.string))
      ]
      let records = counts.flatMap { kind, count in
        (0..<count).map {
          AviationRecord(
            versionID: version.id, kind: kind, id: "\($0)", identifier: "\($0)", name: kind)
        }
      }
      return StagedImport(versions: [version], records: records)
    }
    try gate.verify(staged(["airport": 950, "fix": 500, "fss": 5], []))
    for incomplete in [
      staged(["airport": 1000, "fix": 400, "fss": 10], []),
      staged(["airport": 1000, "fix": 500], []),
      staged(["airport": 1000, "fix": 500, "fss": 10], ["fix"])
    ] {
      #expect(throws: IncompleteReleaseError.self) { try gate.verify(incomplete) }
    }
  }

  @Test
  func `builds one center polygon per altitude structure and closes each shape`() throws {
    func segment(_ sequence: Int, _ structure: String, _ degrees: (Int, Int), closes: Bool = false)
      -> [String: Any]
    {
      [
        "recordIdentifier": "ZOA\(structure)\(sequence)", "ARTCCIdentifier": "ZOA",
        "altitudeStructure": structure, "pointDesignator": "\(sequence)",
        "centerName": "OAKLAND", "altitudeStructureName": structure == "L" ? "LOW" : "HIGH",
        "position": ["latitudeArcsec": degrees.0 * 3600, "longitudeArcsec": degrees.1 * 3600],
        "boundaryDescription": closes ? "TO POINT OF BEGINNING" : "TO", "sequenceNumber": sequence
      ]
    }
    let records = [
      segment(30, "L", (38, -121), closes: true), segment(10, "L", (37, -122)),
      segment(20, "L", (38, -122)), segment(40, "L", (39, -122)), segment(50, "L", (40, -122)),
      segment(60, "L", (40, -121), closes: true), segment(10, "H", (37, -122)),
      segment(20, "H", (38, -122)), segment(30, "H", (38, -121), closes: true)
    ]
    let segments = try JSONDecoder().decode(
      [ARTCCBoundarySegment].self, from: JSONSerialization.data(withJSONObject: records))
    let centers = NASRAirspace.centerAirspaces(segments, versionID: UUID())
    #expect(centers.map(\.id) == ["ZOA/HIGH", "ZOA/LOW"])
    #expect(centers[0].geometry?.objectValue?["type"] == "Polygon")
    #expect(centers[0].data["lower_limit"]?.objectValue?["value"] == 180)
    let low = try #require(centers[1].geometry?.objectValue)
    #expect(low["type"] == "MultiPolygon")
    #expect(
      low["coordinates"]?.arrayValue?.map { $0.arrayValue?.first?.arrayValue?.count } == [4, 4])
    #expect(centers[1].data["upper_limit"] == centers[0].data["lower_limit"])
  }

  @Test
  func `reports only parse errors that may have dropped records of the requested kind`() {
    var diagnostics = NASRDiagnostics()
    diagnostics.record(
      .fieldError(
        recordType: .airports, recordID: "kept", field: "agreements", value: "X",
        underlying: StorageError.invalidImport("Unknown agreement")))
    diagnostics.record(
      .recordError(
        recordType: .airports, recordID: "dropped",
        underlying: StorageError.invalidImport("Missing coordinate")))
    var version = SourceVersion(
      id: UUID(), source: .nasr, cycle: "2026-10-29", effectiveFrom: .now, effectiveUntil: nil,
      checksum: "", parserRevision: "", validated: true)
    version.validation = diagnostics.errors.validation
    #expect(version.omissionWarnings(for: ["navaid"]).isEmpty)
    let airportWarnings = version.omissionWarnings(for: ["airport"])
    #expect(airportWarnings.count == 1)
    #expect(airportWarnings.first?.contains(": 1 airport source record(s) could not") == true)
  }
}

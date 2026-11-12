import Foundation
import MCP
import Testing

@testable import AviationMCP

/// What `resolve_route` returns for one line of `RouteResolutionTests.txt`, against the FAA
/// records in `RouteResolutionRecords.jsonl`.
private struct RouteExpectation {
  let completeness: String
  /// The indices of the elements left unresolved.
  var unresolved: [Int] = []
  /// The number of points in each contiguous path.
  let paths: [Int]
  let totalNM: Double
}

/// Expectations for the 2026-10-29 cycle the fixture was exported from. After adding a route
/// to the file, run `scripts/export-route-fixture.sh` and add its expectation here.
private let routeExpectations: [String: RouteExpectation] = [
  // Fixes and a navaid between two airports.
  "KORD DENNT DARCY DREGS DONVE BWG KHSV":
    .init(completeness: "complete", paths: [7], totalNM: 450.91),
  // A departure and an arrival with their transitions, and Q176 entered twice. No runway is
  // given and RNLDI4 has three runway transitions, so the path starts at its common route.
  // BRDJE5 ends on a course flown until ATC ends it (an FM leg), so nothing joins it to KDFW.
  "KIAD RNLDI4.OTTTO Q176 STEVY Q176 BICKS PXV FSM KOMMA RRNET.BRDJE5 KDFW":
    .init(completeness: "partial", paths: [1, 22, 1], totalNM: 1037.34),
  // An arrival whose runway transition ends on a heading, which splits off the airport.
  "KHSV SQS.DODJE6 KRBD":
    .init(completeness: "partial", paths: [9, 1], totalNM: 531.27),
  // Runways written beside the departure and the arrival. The departure's runway transition
  // starts on a heading, which splits off the airport.
  "KBNA 20C.DANLS5.TPEEE LITTR BROBB WINDU.SEWZY6.18R KAUS":
    .init(completeness: "partial", paths: [1, 15], totalNM: 693.04),
  // Neither airway contains the points written either side of it: MSL is a DME collocated
  // with HAGIE but is not a T398 point, and T486 ends at BURBN, short of TXO. The tool does
  // not substitute a nearby point, so both airways stay unresolved.
  "KHSV MSL T398 HAGIE NESTS T486 TXO KCVS":
    .init(completeness: "partial", unresolved: [2, 5], paths: [2, 2, 2], totalNM: 126.39)
]

extension `Transactional publication` {
  @Test
  func `resolves every route in RouteResolutionTests.txt against published FAA records`()
    async throws
  {
    let routes = try Self.routeLines()
    #expect(!routes.isEmpty)
    try await withDatabase { store in
      try await Self.publishRouteRecords(store)
      let catalog = Self.routeCatalog(store)
      for route in routes {
        let response = try await catalog.call(
          .init(name: "resolve_route", arguments: ["route_string": .string(route)]))
        let content = try #require(response.structuredContent?.objectValue, "\(route)")
        #expect(response.isError != true, "\(route)")
        let result = try #require(Self.results(response).first?.objectValue, "\(route)")
        let elements = (result["elements"]?.arrayValue ?? []).compactMap { $0.objectValue }
        let legs = (result["legs"]?.arrayValue ?? []).compactMap { $0.objectValue }
        let paths = (result["paths"]?.arrayValue ?? []).map { $0.arrayValue ?? [] }
        let total = try #require(result["total_distance_nm"]?.number, "\(route)")

        // What holds for any route.
        #expect(elements.count == route.split { $0 == " " || $0 == "." }.count, "\(route)")
        #expect(legs.count == paths.map { max($0.count - 1, 0) }.reduce(0, +), "\(route)")
        #expect(legs.allSatisfy { ($0["distance_nm"]?.number ?? 0) > 0 }, "\(route)")
        let summed = legs.compactMap { $0["distance_nm"]?.number }.reduce(0, +)
        #expect(abs(total - summed) < 0.01 * Double(max(legs.count, 1)), "\(route)")
        let unresolved = elements.filter { $0["kind"] == "unresolved" }
        #expect(
          result["distance_complete"]
            == .bool(
              unresolved.isEmpty && result["geometry_gaps"] == .array([]) && paths.count == 1),
          "\(route)")

        let expected = try #require(
          routeExpectations[route],
          "\(route) has no expectation; add one to routeExpectations.")
        #expect(content["completeness"] == .string(expected.completeness), "\(route)")
        #expect(unresolved.compactMap { $0["index"]?.intValue } == expected.unresolved, "\(route)")
        #expect(paths.map(\.count) == expected.paths, "\(route)")
        #expect(abs(total - expected.totalNM) < 0.02, "\(route): \(total) NM")
      }
    }
  }

  private static var routeData: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("AviationMCPTestData")
  }

  /// The routes under test, one per nonempty line.
  static func routeLines() throws -> [String] {
    try String(
      contentsOf: routeData.appendingPathComponent("RouteResolutionTests.txt"), encoding: .utf8
    )
    .split(whereSeparator: \.isNewline)
    .map { $0.split(separator: " ").joined(separator: " ") }
    .filter { !$0.isEmpty }
  }

  /// Publishes the NASR and CIFP records exported by `scripts/export-route-fixture.sh`.
  static func publishRouteRecords(_ store: AviationStore) async throws {
    struct Exported: Decodable {
      let source: SourceName
      let kind: String
      let id: String
      let identifier: String
      let name: String
      let airport: String?
      let data: [String: Value]
      let geometry: Value?
    }
    let versions: [SourceName: SourceVersion] = [
      .nasr: Self.version(.nasr), .cifp: Self.version(.cifp)
    ]
    let lines = try String(
      contentsOf: routeData.appendingPathComponent("RouteResolutionRecords.jsonl"),
      encoding: .utf8
    ).split(whereSeparator: \.isNewline)
    let records = try lines.map { line in
      let exported = try JSONDecoder().decode(Exported.self, from: Data(line.utf8))
      let version = try #require(versions[exported.source])
      var record = AviationRecord(
        versionID: version.id, kind: exported.kind, id: exported.id,
        identifier: exported.identifier, name: exported.name, airport: exported.airport)
      record.data = exported.data
      record.geometry = exported.geometry
      return record
    }
    try await store.publish(Array(versions.values), records: records)
  }
}

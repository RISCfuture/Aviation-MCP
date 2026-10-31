import Foundation
import MCP
import Testing

@testable import AviationMCP

@Suite
struct `Navigation expansion` {
  @Test
  func `bounds nested geometry while retaining leg restrictions and sequence`() throws {
    let point = Normalization.point(latitude: 37, longitude: -122)
    let legs: [Value] = (0..<2_000).map { sequence in
      .object(["sequence": .int(sequence), "position": point, "minimum_altitude_ft": 5_000])
    }
    let response = try ToolResult(results: [.object(["legs": .array(legs)])]).response()
    let content = try #require(response.structuredContent?.objectValue)
    let record = try #require(content["results"]?.arrayValue?.first?.objectValue)
    let bounded = try #require(record["legs"]?.arrayValue)
    #expect(bounded.count == legs.count)
    #expect(bounded.last?.objectValue?["minimum_altitude_ft"] == 5_000)
    #expect(bounded.last?.objectValue?["sequence"] == 1_999)
    #expect(
      bounded.first?.objectValue?["position"]?.objectValue?["coordinates"] == .array([-122, 37]))
    #expect(bounded.last?.objectValue?["position"] == nil)
    #expect(record["geometry_omitted"] == true)
    #expect(content["completeness"] == "partial")
  }

  @Test
  func `preserves airway segment ownership when traversing in reverse`() throws {
    let airway: Value = .object([
      "segments": .array([
        .object(["identifier": "SNS", "sequence": 10, "distance_to_next_nm": 30]),
        .object(["identifier": "MID", "sequence": 20, "distance_to_next_nm": 25, "airway_gap": true]
        ),
        .object(["identifier": "PRB", "sequence": 30])
      ])
    ])
    let result = try AirwayExpansion.apply(
      ToolResult(results: [airway, .object(["segments": .array([.object(["identifier": "ITO"])])])]
      ),
      arguments: ToolArguments(["entry_fix": "PRB", "exit_fix": "SNS"]))
    #expect(result.results.count == 1)
    let expanded = try #require(result.results.first?.objectValue)
    #expect(expanded["reversed"] == true)
    #expect(
      expanded["segments"]?.arrayValue?.map { $0.objectValue?["identifier"] } == [
        "PRB", "MID", "SNS"
      ])
    #expect(expanded["segments"]?.arrayValue?.last?.objectValue?["distance_to_next_nm"] == 30)
    #expect(result.completeness == "partial")
  }

  @Test
  func `resolves airway geometry without bridging ambiguous navigation points`() throws {
    let version = UUID()
    var first = AviationRecord(
      versionID: version, kind: "fix", id: "A/K2", identifier: "A", name: "A")
    first.geometry = Normalization.point(latitude: 37, longitude: -122)
    first.data["icao_region"] = "K2"
    var second = AviationRecord(
      versionID: version, kind: "fix", id: "B/K2", identifier: "B", name: "B")
    second.geometry = Normalization.point(latitude: 38, longitude: -122)
    second.data["icao_region"] = "K2"
    var ambiguous = second
    ambiguous.geometry = Normalization.point(latitude: 39, longitude: -122)
    var airway = AviationRecord(
      versionID: version, kind: "airway", id: "V1", identifier: "V1", name: "V1")
    airway.data["segments"] = .array(
      ["A", "B", "A"].enumerated().map { index, name in
        .object([
          "identifier": .string(name), "sequence": .int(index), "icao_region": "K2",
          "point_type": "WAY-PT"
        ])
      })
    let resolved = AirwayGeometry(navigation: [first, second]).resolve(airway)
    #expect(resolved.geometry?.objectValue?["coordinates"]?.arrayValue?.count == 2)
    #expect(resolved.data["geometry_gap_sequences"] == .array([]))
    var partial = resolved.data
    partial["geometry_scope"] = "unavailable_due_to_parse_errors"
    partial["segments"] = .array(
      Array(try #require(resolved.data["segments"]?.arrayValue).prefix(2)))
    let expanded = try AirwayExpansion.apply(
      ToolResult(results: [.object(partial)]),
      arguments: ToolArguments(["entry_fix": "B", "exit_fix": "A"]))
    #expect(expanded.results.first?.objectValue?["geometry"] == nil)
    let unresolved = AirwayGeometry(navigation: [first, second, ambiguous]).resolve(airway)
    #expect(unresolved.geometry == nil)
    #expect(unresolved.data["geometry_gap_sequences"]?.arrayValue?.count == 2)
    #expect(
      unresolved.data["segments"]?.arrayValue?[1].objectValue?["position_candidates"]?.arrayValue?
        .count == 2)
  }

  @Test
  func `orders departure transitions and preserves both sides of a transition boundary`() throws {
    let common = Self.procedure(id: "common", transition: nil, fixes: ["RW04L", "JOIN"])
    let transition = Self.procedure(id: "exit", transition: "EXIT", fixes: ["JOIN", "EXIT"])
    let result = try ProcedureExpansion.apply(
      ToolResult(results: [transition, common]),
      transition: "EXIT")
    let expanded = try #require(result.results.first?.objectValue)
    #expect(
      expanded["legs"]?.arrayValue?.map { $0.objectValue?["fix"] } == [
        "RW04L", "JOIN", "JOIN", "EXIT"
      ])
    #expect(expanded["transition_boundaries"]?.arrayValue?.first?.objectValue?["index"] == 2)
    let truncated = try ProcedureExpansion.apply(
      ToolResult(results: [common], nextCursor: "another-page"), transition: "EXIT")
    #expect(truncated.results.first?.objectValue?["transition_boundaries"] == nil)
    #expect(truncated.completeness == "partial")
    #expect(truncated.nextCursor == nil)
    #expect(RunwayName.matches("RW04B", requested: "4L"))
    #expect(RunwayName.matches("ALL", requested: "04R"))
    #expect(!RunwayName.matches("RW04L", requested: "04R"))
  }

  @Test
  func `lists available transitions and names them when a requested one is missing`() throws {
    let common = Self.procedure(id: "final", transition: nil, fixes: ["WINNI", "RW04R"])
    let transition = Self.procedure(id: "goshi", transition: "GOSHI", fixes: ["GOSHI", "WINNI"])
    let result = try ProcedureExpansion.apply(
      ToolResult(results: [common, transition]), transition: nil)
    let procedure = try #require(result.results.first?.objectValue)
    #expect(procedure["legs"]?.arrayValue?.map { $0.objectValue?["fix"] } == ["WINNI", "RW04R"])
    #expect(
      procedure["available_transitions"]
        == .array([.object(["name": "GOSHI", "initial_fix": "GOSHI"])]))
    let error = try #require(throws: ToolInputError.self) {
      try ProcedureExpansion.apply(ToolResult(results: [common, transition]), transition: "GOSHY")
    }
    #expect(error.reason.hasSuffix("Available transitions: GOSHI."))
  }

  private static func procedure(id: String, transition: String?, fixes: [String]) -> Value {
    var fields: [String: Value] = [
      "id": .string(id), "identifier": "TEST1", "airport": "KTEST", "procedure_type": "departure",
      "legs": .array(fixes.map { .object(["fix": .string($0)]) }), "missed_approach_legs": []
    ]
    fields["transition"] = transition.map(Value.string)
    return .object(fields)
  }
}

import AircraftPerformance
import Foundation
import MCP
import MeasurementKit
import Testing

@testable import AviationMCP

extension `Transactional publication` {
  @Test
  func `calculates a takeoff from NASR and METAR inputs, refusing what the AFM does not cover`()
    async throws
  {
    try await withPerformanceCatalog { catalog in
      let result = try await catalog.call(
        .init(
          name: "takeoff_performance",
          arguments: Self.performanceArguments([
            "obstacle_height_ft": 200, "obstacle_distance_ft": 3_000
          ])
        ))
      let takeoff = try #require(Self.results(result).first?.objectValue)
      let inputs = try #require(takeoff["inputs"]?.objectValue)
      #expect(inputs["elevation_ft"]?.objectValue?["origin"] == "nasr")
      #expect(inputs["temperature_c"]?.objectValue?["origin"] == "metar")
      #expect(inputs["altimeter_inhg"]?.objectValue?["origin"] == "open_meteo")
      let expected = try PackageFigures.takeoff()
      for (field, value) in expected.figures {
        #expect(Self.figure(takeoff[field]) == value, "\(field)")
      }
      #expect(Self.multipliers(takeoff["takeoff_run_breakdown"]) == expected.runMultipliers)
      #expect(takeoff["obstacle"]?.objectValue?["requirement"] == "gradient")
      #expect(takeoff["disclaimers"]?.arrayValue?.count == 1)
      let content = try #require(result.structuredContent?.objectValue)
      #expect(content["sources"]?.arrayValue?.first?.objectValue?["source"] == "nasr")
      #expect(content["liveSources"]?.arrayValue?.isEmpty == false)

      let overridden = try await catalog.call(
        .init(
          name: "takeoff_performance",
          arguments: Self.performanceArguments(["temperature_c": 30, "slope_percent": -1])))
      let overriddenInputs = try #require(
        Self.results(overridden).first?.objectValue?["inputs"]?.objectValue)
      #expect(overriddenInputs["temperature_c"]?.objectValue?["origin"] == "override")
      #expect(overriddenInputs["slope_percent"]?.objectValue?["value"]?.number == -1)

      let airportFree = try await catalog.call(
        .init(
          name: "takeoff_performance",
          arguments: [
            "aircraft": Self.sf50G2Plus, "weight_lb": 5_800, "elevation_ft": 6,
            "runway_heading_true_deg": 295, "available_takeoff_run_ft": 9_000,
            "temperature_c": 20, "wind_direction_true_deg": 300, "wind_speed_kt": 5
          ]))
      let airportFreeInputs = try #require(
        Self.results(airportFree).first?.objectValue?["inputs"]?.objectValue)
      #expect(airportFreeInputs["altimeter_inhg"]?.objectValue?["origin"] == "assumed")
      #expect(airportFreeInputs["airport"] == nil)

      let heavy = try await catalog.call(
        .init(
          name: "takeoff_performance",
          arguments: Self.performanceArguments(["weight_lb": 6_500])))
      #expect(Self.errorCode(heavy) == "invalid_argument")
    }
  }

  @Test
  func `answers each deprecated sf50 alias with the tool's figures in the alias's own shape`()
    async throws
  {
    try await withPerformanceCatalog { catalog in
      let calls: [(tool: String, extra: [String: MCP.Value])] = [
        ("takeoff_performance", [:]), ("landing_performance", ["weight_lb": 5_000]),
        ("climb_profile", ["top_altitude_ft": 5_000]), ("takeoff_limits", ["solve_for": "weight"])
      ]
      for (tool, extra) in calls {
        let alias = "sf50_\(tool)"
        var arguments = Self.performanceArguments(extra)
        if tool == "takeoff_limits" { arguments["weight_lb"] = nil }
        var aliasArguments = arguments
        aliasArguments["aircraft"] = nil
        aliasArguments["aircraft_generation"] = "g2_plus"
        let current = try #require(
          Self.results(try await catalog.call(.init(name: tool, arguments: arguments))).first?
            .objectValue)
        let aliased = try #require(
          Self.results(try await catalog.call(.init(name: alias, arguments: aliasArguments)))
            .first?.objectValue)
        let echo = try #require(aliased["aircraft"]?.objectValue)
        #expect(echo["generation"] == "g2_plus" && echo["type"] == nil, "\(alias)")
        #expect(echo["capabilities"] == nil && echo["documents"] == nil, "\(alias)")
        #expect(
          aliased.filter { $0.key != "aircraft" }
            == current.filter { !["aircraft", "unavailable_outputs"].contains($0.key) },
          "\(alias)")
      }
    }
  }

  @Test
  func `refuses a takeoff when the weather lacks a temperature or a wind`() async throws {
    try await withPerformanceCatalog(
      weather: WeatherService(
        awc: { _ in throw WeatherFailure(provider: "awc", reason: "No report.") }, openMeteo: nil)
    ) { catalog in
      let unavailable = try await catalog.call(
        .init(name: "takeoff_performance", arguments: Self.performanceArguments()))
      #expect(Self.errorCode(unavailable) == "weather_unavailable")
    }
    try await withPerformanceCatalog(
      weather: WeatherService(
        awc: { _ in
          PerformanceFixtures.sample(
            provider: "awc", product: "TAF",
            values: ["wind_direction_true_deg": 280, "wind_speed_kt": 10])
        }, openMeteo: nil)
    ) { catalog in
      let noTemperature = try await catalog.call(
        .init(name: "takeoff_performance", arguments: Self.performanceArguments()))
      #expect(Self.errorCode(noTemperature) == "weather_unavailable")
      let overridden = try await catalog.call(
        .init(
          name: "takeoff_performance",
          arguments: Self.performanceArguments(["temperature_c": 25])))
      #expect(Self.errorCode(overridden) == nil)
    }
  }

  @Test
  func `calculates a contaminated landing with the supplemental-data disclaimer`() async throws {
    try await withPerformanceCatalog { catalog in
      let result = try await catalog.call(
        .init(
          name: "landing_performance",
          arguments: Self.performanceArguments([
            "weight_lb": 5_000, "contamination": "water_or_slush",
            "contamination_depth_in": 0.25
          ])))
      let landing = try #require(Self.results(result).first?.objectValue)
      #expect(landing["aircraft"]?.objectValue?["flaps"] == "100")
      #expect(landing["vref_kt"]?.objectValue?["status"] == "value")
      #expect(
        landing["inputs"]?.objectValue?["contamination"]?.objectValue?["type"] == "water_or_slush")
      #expect(landing["disclaimers"]?.arrayValue?.count == 2)
      let dry = try #require(
        Self.results(
          try await catalog.call(
            .init(
              name: "landing_performance",
              arguments: Self.performanceArguments(["weight_lb": 5_000])))
        ).first?.objectValue)
      for (field, value) in try PackageFigures.landing(weightLb: 5_000) {
        #expect(Self.figure(dry[field]) == value, "\(field)")
      }
      #expect(
        dry["runway_margins"]?.objectValue?["landing_distance"]?.objectValue?["available_ft"]
          == 9_000)
      let missingDepth = try await catalog.call(
        .init(
          name: "landing_performance",
          arguments: Self.performanceArguments([
            "weight_lb": 5_000, "contamination": "water_or_slush"
          ])))
      #expect(Self.errorCode(missingDepth) == "invalid_argument")
      let strayCode = try await catalog.call(
        .init(
          name: "landing_performance",
          arguments: Self.performanceArguments([
            "weight_lb": 5_000, "contamination": "wet", "rwycc": 2
          ])))
      #expect(Self.errorCode(strayCode) == "invalid_argument")
    }
  }

  @Test
  func `reads the climb in the forecast winds aloft with a gradient for query_terrain`()
    async throws
  {
    try await withPerformanceCatalog { catalog in
      let result = try await catalog.call(
        .init(
          name: "climb_profile",
          arguments: [
            "airport": "KOAK", "runway": "28R", "aircraft": Self.sf50G2Plus, "weight_lb": 5_800,
            "top_altitude_ft": 5_000, "course_true_deg": 295,
            "time": .string(PerformanceFixtures.time.ISO8601Format())
          ]))
      let climb = try #require(Self.results(result).first?.objectValue)
      #expect(
        climb["inputs"]?.objectValue?["winds_aloft"]?.objectValue?["origin"] == "open_meteo")
      #expect(climb["levels"]?.arrayValue?.first?.objectValue?["altitude_ft"]?.number == 6)
      let profile = try PackageFigures.forecastClimb()
      for level in climb["levels"]?.arrayValue?.compactMap(\.objectValue) ?? [] {
        let altitude = try #require(level["altitude_ft"]?.number)
        let gradient = level["schedules"]?.objectValue?["takeoff"]?.objectValue?[
          "gradient_ft_per_nm"]
        let expected = try #require(profile.gradient(at: altitude, profile: .takeoff))
        #expect(Self.figure(gradient) == expected.rounded(), "takeoff gradient at \(altitude) ft")
      }
      let takeoff = try #require(climb["schedules"]?.objectValue?["takeoff"]?.objectValue)
      #expect(takeoff["minimum_gradient_ft_per_nm"]?.objectValue?["status"] == "value")
      #expect(takeoff["minimum_ground_gradient_ft_per_nm"]?.objectValue?["status"] == "value")
      let terrain = try #require(climb["query_terrain"]?.objectValue)
      #expect(terrain["basis"] == "ground")
      #expect(terrain["starting_point"] == "departure_end")
      #expect(climb["aircraft"]?.objectValue?["safety_factor"] == nil)
      let hot = try await catalog.call(
        .init(
          name: "climb_profile",
          arguments: [
            "airport": "KOAK", "runway": "28R", "aircraft": Self.sf50G2Plus, "weight_lb": 5_800,
            "top_altitude_ft": 5_000, "course_true_deg": 295,
            "temperature_c": 35, "time": .string(PerformanceFixtures.time.ISO8601Format())
          ]))
      let hotInputs = try #require(Self.results(hot).first?.objectValue?["inputs"]?.objectValue)
      #expect(hotInputs["winds_aloft"]?.objectValue?["origin"] == "open_meteo")
      #expect(hotInputs["temperature_c"]?.objectValue?["origin"] == "override")
      let below = try await catalog.call(
        .init(
          name: "climb_profile",
          arguments: [
            "airport": "KOAK", "aircraft": Self.sf50G2Plus, "weight_lb": 5_800, "top_altitude_ft": 0
          ]))
      #expect(Self.errorCode(below) == "invalid_argument")
    }
  }

  @Test
  func `finds the maximum takeoff weight for every runway end`() async throws {
    try await withPerformanceCatalog { catalog in
      let result = try await catalog.call(
        .init(
          name: "takeoff_limits",
          arguments: [
            "airport": "KOAK", "aircraft": Self.sf50G1, "solve_for": "weight",
            "time": .string(PerformanceFixtures.time.ISO8601Format())
          ]))
      let ends = Self.results(result).compactMap(\.objectValue)
      #expect(
        ends.compactMap { $0["inputs"]?.objectValue?["runway"]?.stringValue } == ["28R", "10L"])
      for end in ends {
        let expected = try PackageFigures.maxTakeoffWeight(runway: try Self.runway(echoedBy: end))
        #expect(end["max_takeoff_weight_lb"]?.number == expected.limit)
        #expect(end["binding_constraint"]?.stringValue == expected.constraint.rawValue)
      }
      let published = try PackageFigures.maxTakeoffWeight(runway: PackageFigures.runway28R())
      #expect(ends.first?["max_takeoff_weight_lb"]?.number == published.limit)
      let oneEnd = try await catalog.call(
        .init(
          name: "takeoff_limits",
          arguments: [
            "airport": "KOAK", "aircraft": Self.sf50G1, "solve_for": "weight",
            "available_takeoff_run_ft": 5_000,
            "time": .string(PerformanceFixtures.time.ISO8601Format())
          ]))
      #expect(Self.errorCode(oneEnd) == "invalid_argument")
      let temperature = try await catalog.call(
        .init(
          name: "takeoff_limits",
          arguments: [
            "airport": "KOAK", "runway": "28R", "aircraft": Self.sf50G1,
            "solve_for": "temperature", "weight_lb": 5_500, "available_takeoff_run_ft": 3_000,
            "time": .string(PerformanceFixtures.time.ISO8601Format())
          ]))
      let limit = try #require(Self.results(temperature).first?.objectValue)
      let expected = try PackageFigures.maxTakeoffTemperature(
        weightLb: 5_500, availableTakeoffRunFt: 3_000)
      #expect(expected.constraint == .fieldLength)
      #expect(limit["max_temperature_c"]?.number == expected.limit)
      #expect(limit["binding_constraint"]?.stringValue == expected.constraint.rawValue)
      #expect(limit["inputs"]?.objectValue?["temperature_c"] == nil)
    }
  }

  private static let sf50G2Plus: MCP.Value = ["type": "sf50", "generation": "g2_plus"]
  private static let sf50G1: MCP.Value = ["type": "sf50", "generation": "g1"]

  private func withPerformanceCatalog(
    weather: WeatherService = PerformanceFixtures.weather(),
    _ operation: @Sendable (ToolCatalog) async throws -> Void
  ) async throws {
    try await withDatabase { store in
      let nasr = Self.version(.nasr)
      try await store.publish([nasr], records: [Self.airportWithRunwayEnds(nasr)])
      try await operation(
        ToolCatalog(store: store, groups: [.performance], weather: weather, notams: nil))
    }
  }

  private static func performanceArguments(_ extra: [String: MCP.Value] = [:]) -> [String: MCP
    .Value]
  {
    [
      "airport": "KOAK", "runway": "28R", "aircraft": Self.sf50G2Plus, "weight_lb": 5_800,
      "time": .string(PerformanceFixtures.time.ISO8601Format())
    ].merging(extra) { $1 }
  }

  /// A runway end built from the inputs a result echoes, for ends whose values are derived.
  private static func runway(echoedBy result: [String: MCP.Value]) throws -> RunwayInput {
    let inputs = try #require(result["inputs"]?.objectValue)
    func number(_ key: String) throws -> Double {
      try #require(inputs[key]?.objectValue?["value"]?.number, "\(key)")
    }
    let takeoffDistance = try number("available_takeoff_distance_ft")
    return RunwayInput(
      id: try #require(inputs["runway"]?.stringValue),
      elevation: .init(value: try number("elevation_ft"), unit: .feet),
      trueHeading: .init(value: try number("runway_heading_true_deg"), unit: .degrees),
      gradient: Float(try number("slope_percent") / 100),
      length: .init(value: takeoffDistance, unit: .feet),
      takeoffRun: .init(value: try number("available_takeoff_run_ft"), unit: .feet),
      takeoffDistance: .init(value: takeoffDistance, unit: .feet),
      landingDistance: try? .init(value: number("available_landing_distance_ft"), unit: .feet),
      notam: nil, airportVariation: .init(value: 0, unit: .degrees))
  }

  /// A result figure's value, whatever its status.
  private static func figure(_ figure: MCP.Value?) -> Double? {
    figure?.objectValue?["value"]?.number
  }

  private static func multipliers(_ breakdown: MCP.Value?) -> [Double] {
    breakdown?.objectValue?["adjustments"]?.arrayValue?.compactMap {
      $0.objectValue?["multiplier"]?.number
    } ?? []
  }

  private static func errorCode(_ result: CallTool.Result) -> MCP.Value? {
    result.structuredContent?.objectValue?["error"]?.objectValue?["code"]
  }
}

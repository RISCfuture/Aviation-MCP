import Foundation
import MCP
import MeasurementKit
import SF50Performance
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
          name: "sf50_takeoff_performance",
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
          name: "sf50_takeoff_performance",
          arguments: Self.performanceArguments(["temperature_c": 30, "slope_percent": -1])))
      let overriddenInputs = try #require(
        Self.results(overridden).first?.objectValue?["inputs"]?.objectValue)
      #expect(overriddenInputs["temperature_c"]?.objectValue?["origin"] == "override")
      #expect(overriddenInputs["slope_percent"]?.objectValue?["value"]?.number == -1)

      let airportFree = try await catalog.call(
        .init(
          name: "sf50_takeoff_performance",
          arguments: [
            "aircraft_generation": "g2_plus", "weight_lb": 5_800, "elevation_ft": 6,
            "runway_heading_true_deg": 295, "available_takeoff_run_ft": 9_000,
            "temperature_c": 20, "wind_direction_true_deg": 300, "wind_speed_kt": 5
          ]))
      let airportFreeInputs = try #require(
        Self.results(airportFree).first?.objectValue?["inputs"]?.objectValue)
      #expect(airportFreeInputs["altimeter_inhg"]?.objectValue?["origin"] == "assumed")
      #expect(airportFreeInputs["airport"] == nil)

      let heavy = try await catalog.call(
        .init(
          name: "sf50_takeoff_performance",
          arguments: Self.performanceArguments(["weight_lb": 6_500])))
      #expect(Self.errorCode(heavy) == "invalid_argument")
    }
  }

  @Test
  func `refuses a takeoff when the weather lacks a temperature or a wind`() async throws {
    try await withPerformanceCatalog(
      weather: WeatherService(
        awc: { _ in throw WeatherFailure(provider: "awc", reason: "No report.") }, openMeteo: nil)
    ) { catalog in
      let unavailable = try await catalog.call(
        .init(name: "sf50_takeoff_performance", arguments: Self.performanceArguments()))
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
        .init(name: "sf50_takeoff_performance", arguments: Self.performanceArguments()))
      #expect(Self.errorCode(noTemperature) == "weather_unavailable")
      let overridden = try await catalog.call(
        .init(
          name: "sf50_takeoff_performance",
          arguments: Self.performanceArguments(["temperature_c": 25])))
      #expect(Self.errorCode(overridden) == nil)
    }
  }

  @Test
  func `calculates a contaminated landing with the supplemental-data disclaimer`() async throws {
    try await withPerformanceCatalog { catalog in
      let result = try await catalog.call(
        .init(
          name: "sf50_landing_performance",
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
              name: "sf50_landing_performance",
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
          name: "sf50_landing_performance",
          arguments: Self.performanceArguments([
            "weight_lb": 5_000, "contamination": "water_or_slush"
          ])))
      #expect(Self.errorCode(missingDepth) == "invalid_argument")
      let strayCode = try await catalog.call(
        .init(
          name: "sf50_landing_performance",
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
          name: "sf50_climb_profile",
          arguments: [
            "airport": "KOAK", "runway": "28R", "aircraft_generation": "g2_plus",
            "weight_lb": 5_800, "top_altitude_ft": 5_000, "course_true_deg": 295,
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
          name: "sf50_climb_profile",
          arguments: [
            "airport": "KOAK", "runway": "28R", "aircraft_generation": "g2_plus",
            "weight_lb": 5_800, "top_altitude_ft": 5_000, "course_true_deg": 295,
            "temperature_c": 35, "time": .string(PerformanceFixtures.time.ISO8601Format())
          ]))
      let hotInputs = try #require(Self.results(hot).first?.objectValue?["inputs"]?.objectValue)
      #expect(hotInputs["winds_aloft"]?.objectValue?["origin"] == "open_meteo")
      #expect(hotInputs["temperature_c"]?.objectValue?["origin"] == "override")
      let below = try await catalog.call(
        .init(
          name: "sf50_climb_profile",
          arguments: [
            "airport": "KOAK", "aircraft_generation": "g2_plus", "weight_lb": 5_800,
            "top_altitude_ft": 0
          ]))
      #expect(Self.errorCode(below) == "invalid_argument")
    }
  }

  @Test
  func `finds the maximum takeoff weight for every runway end`() async throws {
    try await withPerformanceCatalog { catalog in
      let result = try await catalog.call(
        .init(
          name: "sf50_takeoff_limits",
          arguments: [
            "airport": "KOAK", "aircraft_generation": "g1", "solve_for": "weight",
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
          name: "sf50_takeoff_limits",
          arguments: [
            "airport": "KOAK", "aircraft_generation": "g1", "solve_for": "weight",
            "available_takeoff_run_ft": 5_000,
            "time": .string(PerformanceFixtures.time.ISO8601Format())
          ]))
      #expect(Self.errorCode(oneEnd) == "invalid_argument")
      let temperature = try await catalog.call(
        .init(
          name: "sf50_takeoff_limits",
          arguments: [
            "airport": "KOAK", "runway": "28R", "aircraft_generation": "g1",
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
      "airport": "KOAK", "runway": "28R", "aircraft_generation": "g2_plus", "weight_lb": 5_800,
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

/// The package's figures, rounded and keyed as results give them, for the fixtures' runway and
/// weather built from their raw values, so a tool reading any of them wrongly disagrees.
private enum PackageFigures {
  /// The fixture METAR's wind and temperature with the model's altimeter setting.
  private static let reportedConditions = Conditions(
    windDirection: .init(value: 280, unit: .degrees), windSpeed: .init(value: 10, unit: .knots),
    temperature: .init(value: 15, unit: .celsius),
    seaLevelPressure: .init(value: 30.12, unit: .inchesOfMercury))

  /// Runway 28R as the fixture airport publishes it. A shortened takeoff run also shortens the
  /// takeoff distance, as the tools treat an `available_takeoff_run_ft` override.
  static func runway28R(availableTakeoffRunFt: Double? = nil) -> RunwayInput {
    let takeoffRunFt = availableTakeoffRunFt ?? 10_000
    let takeoffDistanceFt = availableTakeoffRunFt ?? 10_500
    return RunwayInput(
      id: "28R", elevation: .init(value: 6, unit: .feet),
      trueHeading: .init(value: 295, unit: .degrees), gradient: 0.001,
      length: .init(value: max(takeoffDistanceFt, 9_000), unit: .feet),
      takeoffRun: .init(value: takeoffRunFt, unit: .feet),
      takeoffDistance: .init(value: takeoffDistanceFt, unit: .feet),
      landingDistance: .init(value: 9_000, unit: .feet), notam: nil,
      airportVariation: .init(value: 0, unit: .degrees))
  }

  /// A G2+ takeoff at 5,800 lb from 28R, and the ground run's correction multipliers.
  static func takeoff() throws -> (figures: [String: Double], runMultipliers: [Double]) {
    let report = try PerformanceCalculator(settings: .init(aircraftType: .g2Plus)).takeoff(
      conditions: reportedConditions, weight: .init(value: 5_800, unit: .pounds),
      runway: runway28R())
    let results = report.results
    return (
      [
        "takeoff_run_ft": try whole(results.takeoffRun.nominal, in: .feet),
        "takeoff_distance_ft": try whole(results.takeoffDistance.nominal, in: .feet),
        "takeoff_climb_gradient_ft_per_nm": try whole(
          results.takeoffClimbGradient.nominal, in: .feetPerNauticalMile)
      ],
      report.groundRunBreakdown.adjustments.map { ($0.multiplier * 1000).rounded() / 1000 }
    )
  }

  /// A dry G2+ flaps 100 landing on 28R.
  static func landing(weightLb: Double) throws -> [String: Double] {
    let results = try PerformanceCalculator(settings: .init(aircraftType: .g2Plus)).landing(
      conditions: reportedConditions,
      configuration: .init(weight: .init(value: weightLb, unit: .pounds), flapSetting: .flaps100),
      runway: runway28R()
    ).results
    return [
      "landing_run_ft": try whole(results.landingRun.nominal, in: .feet),
      "landing_distance_ft": try whole(results.landingDistance.nominal, in: .feet),
      "vref_kt": try whole(results.Vref.nominal, in: .knots)
    ]
  }

  /// A G2+ climb profile at 5,800 lb from the field, at the METAR's temperature and the lowest
  /// level's wind, through the fixture forecast's two pressure levels.
  static func forecastClimb() throws -> ClimbProfile {
    func feet(meters: Double) -> Double { meters / 0.304_8 }
    return try ClimbProfileGenerator.generate(
      windsAloft: [
        .init(altitudeFt: 6, temperatureC: 15, windDirectionDeg: 290, windSpeedKts: 20),
        .init(
          altitudeFt: feet(meters: 780), temperatureC: 12, windDirectionDeg: 290,
          windSpeedKts: 20),
        .init(
          altitudeFt: feet(meters: 3_100), temperatureC: -2, windDirectionDeg: 270,
          windSpeedKts: 30)
      ],
      weightLb: 5_800, aircraftType: .g2Plus, seaLevelPressureInHg: 30.12,
      useRegressionModel: false)
  }

  /// The G1 maximum takeoff weight from 5,000 lb up, and what binds it.
  static func maxTakeoffWeight(runway: RunwayInput) throws -> (
    limit: Double, constraint: BindingConstraint
  ) {
    let search = try PerformanceCalculator(settings: .init(aircraftType: .g1)).maxTakeoffWeight(
      conditions: reportedConditions, runway: runway,
      minimumWeight: .init(value: 5_000, unit: .pounds))
    return (try whole(search.limit, in: .pounds), search.bindingConstraint)
  }

  /// The G1 maximum takeoff temperature from 28R at a weight, and what binds it.
  static func maxTakeoffTemperature(weightLb: Double, availableTakeoffRunFt: Double) throws -> (
    limit: Double, constraint: BindingConstraint
  ) {
    let search = try PerformanceCalculator(settings: .init(aircraftType: .g1))
      .maxTakeoffTemperature(
        conditions: reportedConditions, weight: .init(value: weightLb, unit: .pounds),
        runway: runway28R(availableTakeoffRunFt: availableTakeoffRunFt))
    return (try whole(search.limit, in: .celsius), search.bindingConstraint)
  }

  /// A figure in whole units, failing the test where the package gives none.
  private static func whole<UnitType: Dimension>(
    _ measurement: Measurement<UnitType>?, in unit: UnitType
  ) throws -> Double {
    try #require(measurement).converted(to: unit).value.rounded()
  }
}

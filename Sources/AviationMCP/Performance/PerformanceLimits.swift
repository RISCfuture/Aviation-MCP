import AircraftPerformance
import Foundation
import MCP
import MeasurementKit

extension PerformanceTools {
  /// The lightest weight the AFM takeoff data covers, where the weight search starts by default.
  private static let defaultMinimumWeightLb = 5_000.0

  /// The maximum takeoff weight, or the maximum temperature at a weight, for one runway end or
  /// every end of an airport.
  func takeoffLimits(_ arguments: ToolArguments) async throws -> ToolResult {
    let target = try LimitTarget(arguments)
    let aircraft = try PerformanceAircraft(arguments, requiringWeight: target == .temperature)
    let obstacle = try arguments.obstacle()
    let site = try await site(arguments)
    let (runways, omitted) = try Self.limitRunways(arguments, site: site, obstacle: obstacle)
    let weather = try await surfaceWeather(
      arguments, airport: site.airport, needsTemperature: target == .weight)
    let minimumWeightLb =
      try arguments.number("minimum_weight_lb", range: 3_000...7_000)
      ?? Self.defaultMinimumWeightLb
    var figures = FigureEncoder(model: aircraft.model)
    let ignored = target == .weight ? ["weight_lb"] : ["temperature_c", "minimum_weight_lb"]
    let warnings =
      omitted + runways.flatMap(\.warnings) + weather.resolved.warnings
      + ignored.filter { arguments.values[$0] != nil }.map {
        "\($0) is ignored when solving for \(target.rawValue)."
      }
    let results = try runways.map { runway in
      let input = runway.input()
      let conditions = weather.resolved.conditions(runwayHeadingDeg: runway.headingTrueDeg.value)
      let search = TakeoffLimitSearch(
        target: target, aircraft: aircraft, conditions: conditions, obstacle: obstacle,
        minimumWeightLb: minimumWeightLb)
      let inputs = try site.inputs(
        runway: runway, weather: weather.resolved,
        pressureAltitude: conditions.pressureAltitude(elevation: input.elevation))
      var value: [String: MCP.Value] = [
        "aircraft": aircraft.description().merging(["flaps": "50"]),
        "solve_for": .string(target.rawValue), "inputs": .object(inputs),
        "wind_components": PerformanceJSON.windComponents(input, conditions: conditions),
        "disclaimers": [.string(FigureEncoder.disclaimer)]
      ]
      value.merge(try search.limit(runway: input, figures: &figures)) { $1 }
      return MCP.Value.object(value)
    }
    return Self.result(
      results, site: site, weather: weather.reported, figures: figures, warnings: warnings)
  }

  /// The runway end the arguments name, or every end of the airport NASR describes well enough
  /// to calculate, with a warning naming each end left out.
  static func limitRunways(
    _ arguments: ToolArguments, site: PerformanceSite, obstacle: Obstacle?
  ) throws -> (runways: [ResolvedRunway], omitted: [String]) {
    guard let airport = site.airport, try arguments.string("runway") == nil else {
      return (
        [try site.runway(arguments, requiring: "available_takeoff_run_ft") { $0.takeoffRunFt }],
        []
      )
    }
    guard try !RunwayOverrides(arguments).describesOneEnd, obstacle == nil else {
      throw ToolInputError(
        reason: "Runway overrides and obstacles describe one runway end; name the runway.")
    }
    var omitted: [String] = []
    let runways = airport.endIdentifiers.compactMap { name -> ResolvedRunway? in
      guard
        let runway = try? ResolvedRunway.resolve(
          airport: airport, end: airport.end(name), overrides: .init()),
        runway.takeoffRunFt != nil
      else {
        omitted.append(
          "Runway \(name) is left out: NASR does not publish enough about it; name it and supply "
            + "the missing values.")
        return nil
      }
      return runway
    }
    guard !runways.isEmpty else {
      throw ToolInputError(
        reason: "NASR does not publish enough about any runway at \(airport.identifier); name "
          + "a runway and supply its values.")
    }
    return (runways, omitted)
  }
}

/// What a takeoff limit search solves for.
enum LimitTarget: String {
  case weight, temperature

  init(_ arguments: ToolArguments) throws {
    guard let target = Self(rawValue: try arguments.string("solve_for", required: true) ?? "")
    else { throw ToolInputError(reason: "solve_for must be weight or temperature.") }
    self = target
  }
}

/// A takeoff limit search at fixed conditions, run for one runway end at a time.
struct TakeoffLimitSearch {
  private static let constraints: [BindingConstraint: String] = [
    .fieldLength: "A takeoff distance exceeds what the runway declares available.",
    .AFMData: "The AFM data gives no figure beyond this point.",
    .obstacleClearance: "The takeoff climb gradient falls short of what the obstacle requires.",
    .goAroundClimbGradient: "The aircraft cannot meet the AFM go-around climb gradient.",
    .structuralLimit: "The structural maximum takeoff weight.",
    .temperatureLimit: "The AFM maximum operating temperature.",
    .windLimit: "The tailwind component exceeds the AFM limit.",
    .elevationLimit: "The airport elevation lies outside the range the AFM approves."
  ]

  let target: LimitTarget
  let aircraft: PerformanceAircraft
  let conditions: Conditions
  let obstacle: Obstacle?
  let minimumWeightLb: Double

  private var calculator: PerformanceCalculator { .init(settings: aircraft.settings) }

  /// The limit for one runway end and the constraint that sets it.
  func limit(runway: RunwayInput, figures: inout FigureEncoder) throws -> [String: MCP.Value] {
    switch target {
    case .weight: try maximumWeight(runway: runway, figures: &figures)
    case .temperature: try maximumTemperature(runway: runway, figures: &figures)
    }
  }

  private func maximumWeight(runway: RunwayInput, figures: inout FigureEncoder) throws
    -> [String: MCP.Value]
  {
    let search = try calculator.maxTakeoffWeight(
      conditions: conditions, runway: runway, obstacle: obstacle,
      minimumWeight: Measurement(value: minimumWeightLb, unit: .pounds))
    if search.limit == nil {
      figures.warn(
        "Runway \(runway.name): no takeoff weight from \(Int(minimumWeightLb)) lb up satisfies "
          + "the constraints.")
    }
    return Self.fields(
      search, key: "max_takeoff_weight_lb", runway: runway, figures: &figures
    ) { $0.converted(to: .pounds).value }
  }

  private func maximumTemperature(runway: RunwayInput, figures: inout FigureEncoder) throws
    -> [String: MCP.Value]
  {
    let weight = aircraft.weight ?? Measurement(value: 0, unit: .pounds)
    guard weight <= aircraft.limitations.maxTakeoffWeight else {
      figures.warn(
        "Runway \(runway.name): weight_lb exceeds the structural maximum takeoff weight.")
      return [
        "max_temperature_c": .null, "binding_constraint": "structural_limit",
        "binding_constraint_description": .string(Self.constraints[.structuralLimit] ?? ""),
        "relies_on_offscale_data": false
      ]
    }
    let search = try calculator.maxTakeoffTemperature(
      conditions: conditions, weight: weight, runway: runway, obstacle: obstacle)
    if search.limit == nil {
      figures.warn(
        "Runway \(runway.name): no temperature in the AFM range permits a takeoff at weight_lb.")
    }
    return Self.fields(search, key: "max_temperature_c", runway: runway, figures: &figures) {
      $0.converted(to: .celsius).value
    }
  }

  private static func fields<UnitType: Dimension & Sendable>(
    _ search: LimitSearchResult<UnitType>, key: String, runway: RunwayInput,
    figures: inout FigureEncoder, value: (Measurement<UnitType>) -> Double
  ) -> [String: MCP.Value] {
    if search.reliesOnOffscaleData { figures.noteOffscale("Runway \(runway.name) \(key)") }
    return [
      key: search.limit.map { .double(value($0).rounded()) } ?? .null,
      "binding_constraint": .string(search.bindingConstraint.rawValue),
      "binding_constraint_description": .string(constraints[search.bindingConstraint] ?? ""),
      "relies_on_offscale_data": .bool(search.reliesOnOffscaleData)
    ]
  }
}

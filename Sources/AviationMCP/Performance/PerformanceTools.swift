import AircraftPerformance
import Foundation
import MCP
import MeasurementKit

/// The SF50 performance tools: takeoff, landing, climb profile and takeoff limits.
///
/// Each resolves its runway from the current NASR cycle and its weather from the weather
/// service, lets the caller override any input, and echoes every input with its origin.
struct PerformanceTools: Sendable {
  let store: AviationStore
  let weather: WeatherService

  /// Runs one of the performance tools.
  func call(_ tool: ToolDefinition, _ arguments: ToolArguments) async throws -> ToolResult {
    switch tool {
    case .takeoffPerformance: try await takeoff(arguments)
    case .landingPerformance: try await landing(arguments)
    case .climbProfile: try await climbProfile(arguments)
    case .takeoffLimits: try await takeoffLimits(arguments)
    default: throw MCPError.invalidParams("\(tool.rawValue) is not a performance tool")
    }
  }

  /// Ground run, distance over a 50 ft screen, climb gradient and margins for a takeoff.
  func takeoff(_ arguments: ToolArguments) async throws -> ToolResult {
    let aircraft = try PerformanceAircraft(arguments)
    let weight = try aircraft.weight(
      within: aircraft.limitations.maxTakeoffWeight, operation: "takeoff")
    let obstacle = try arguments.obstacle()
    let site = try await site(arguments)
    let runway = try site.runway(arguments, requiring: "available_takeoff_run_ft") {
      $0.takeoffRunFt
    }
    let weather = try await surfaceWeather(arguments, airport: site.airport, needsTemperature: true)
    let conditions = weather.resolved.conditions(runwayHeadingDeg: runway.headingTrueDeg.value)
    let input = runway.input()
    let report = try PerformanceCalculator(settings: aircraft.settings).takeoff(
      conditions: conditions, weight: weight, runway: input)
    let notes = PerformanceNotes.takeoffNotes(
      for: report,
      inputs: PerformanceNoteInputs(
        settings: aircraft.settings,
        configuration: Configuration(
          weight: weight, flapSetting: PerformanceCalculator.takeoffFlapSetting),
        runway: input, conditions: conditions, obstacle: obstacle))
    var figures = FigureEncoder(model: aircraft.model)
    var value = Self.takeoffFigures(report, runway: input, figures: &figures)
    value.merge([
      "aircraft": aircraft.description().merging(["flaps": "50"]),
      "inputs": .object(
        try site.inputs(
          runway: runway, weather: weather.resolved, pressureAltitude: report.pressureAltitude)),
      "wind_components": PerformanceJSON.windComponents(input, conditions: conditions),
      "notes": PerformanceJSON.notes(notes),
      "disclaimers": [.string(FigureEncoder.disclaimer)]
    ]) { $1 }
    value["obstacle"] = obstacle.map { Self.obstacle($0, results: report.results, runway: input) }
    return Self.result(
      [.object(value)], site: site, weather: weather.reported, figures: figures,
      warnings: runway.warnings + weather.resolved.warnings)
  }

  /// Vref, landing run and distance from 50 ft, the go-around gradient and margins for a landing.
  func landing(_ arguments: ToolArguments) async throws -> ToolResult {
    let aircraft = try PerformanceAircraft(arguments)
    let weight = try aircraft.weight(
      within: aircraft.limitations.maxLandingWeight, operation: "landing")
    let flaps = try PerformanceAircraft.landingFlapSetting(arguments)
    let contamination = try PerformanceContamination.parse(arguments)
    let site = try await site(arguments)
    let runway = try site.runway(arguments, requiring: "available_landing_distance_ft") {
      $0.landingDistanceFt
    }
    let weather = try await surfaceWeather(arguments, airport: site.airport, needsTemperature: true)
    let conditions = weather.resolved.conditions(runwayHeadingDeg: runway.headingTrueDeg.value)
    let input = runway.input(contamination: contamination)
    let configuration = Configuration(
      weight: weight, flapSetting: flaps, iceProtection: [.flaps50Ice, .flapsUpIce].contains(flaps))
    let report = try PerformanceCalculator(settings: aircraft.settings).landing(
      conditions: conditions, configuration: configuration, runway: input)
    let notes = PerformanceNotes.landingNotes(
      for: report,
      inputs: PerformanceNoteInputs(
        settings: aircraft.settings, configuration: configuration, runway: input,
        conditions: conditions))
    var figures = FigureEncoder(model: aircraft.model)
    var inputs = try site.inputs(
      runway: runway, weather: weather.resolved, pressureAltitude: report.pressureAltitude)
    inputs["contamination"] = Self.contamination(contamination)
    var value = Self.landingFigures(report, runway: input, figures: &figures)
    value.merge([
      "aircraft": aircraft.description().merging([
        "flaps": .string(try arguments.string("flaps") ?? "100"),
        "vref_additive_kt": .double(aircraft.settings.VREFAdditiveKts)
      ]),
      "inputs": .object(inputs),
      "wind_components": PerformanceJSON.windComponents(input, conditions: conditions),
      "notes": PerformanceJSON.notes(notes),
      "disclaimers": .array(Self.disclaimers(contamination).map(MCP.Value.string))
    ]) { $1 }
    return Self.result(
      [.object(value)], site: site, weather: weather.reported, figures: figures,
      warnings: runway.warnings + weather.resolved.warnings)
  }

  private static func takeoffFigures(
    _ report: TakeoffReport, runway: RunwayInput, figures: inout FigureEncoder
  ) -> [String: MCP.Value] {
    let results = report.results
    return [
      "takeoff_run_ft": figures.encode(results.takeoffRun, "takeoff_run_ft", in: .feet),
      "takeoff_run_breakdown": PerformanceJSON.breakdown(report.groundRunBreakdown),
      "takeoff_distance_ft": figures.encode(
        results.takeoffDistance, "takeoff_distance_ft", in: .feet),
      "takeoff_distance_breakdown": PerformanceJSON.breakdown(report.distanceBreakdown),
      "takeoff_climb_gradient_ft_per_nm": figures.encode(
        results.takeoffClimbGradient, "takeoff_climb_gradient_ft_per_nm",
        in: .feetPerNauticalMile),
      "takeoff_climb_rate_ft_per_min": figures.encode(
        results.takeoffClimbRate, "takeoff_climb_rate_ft_per_min", in: .feetPerMinute),
      "runway_margins": .object([
        "takeoff_run": PerformanceJSON.margin(
          required: results.takeoffRun, available: runway.availableTakeoffRun),
        "takeoff_distance": PerformanceJSON.margin(
          required: results.takeoffDistance, available: runway.availableTakeoffDistance)
      ])
    ]
  }

  private static func landingFigures(
    _ report: LandingReport, runway: RunwayInput, figures: inout FigureEncoder
  ) -> [String: MCP.Value] {
    let results = report.results
    return [
      "vref_kt": figures.encode(results.Vref, "vref_kt", in: .knots),
      "landing_run_ft": figures.encode(results.landingRun, "landing_run_ft", in: .feet),
      "landing_run_breakdown": PerformanceJSON.breakdown(report.groundRunBreakdown),
      "landing_distance_ft": figures.encode(
        results.landingDistance, "landing_distance_ft", in: .feet),
      "landing_distance_breakdown": PerformanceJSON.breakdown(report.distanceBreakdown),
      "meets_go_around_climb_gradient": figures.encode(
        results.meetsGoAroundClimbGradient, "meets_go_around_climb_gradient"),
      "runway_margins": .object([
        "landing_distance": PerformanceJSON.margin(
          required: results.landingDistance, available: runway.availableLandingDistance)
      ])
    ]
  }

  /// The disclaimer, and the AFM's qualification of contaminated-runway data when it applies.
  private static func disclaimers(_ contamination: Contamination?) -> [String] {
    guard let contamination, contamination != .wetRunway else {
      return [FigureEncoder.disclaimer]
    }
    return [FigureEncoder.disclaimer, FigureEncoder.contaminationDisclaimer]
  }

}

// MARK: - Inputs

extension PerformanceTools {

  /// The airport the arguments name, if any, with the NASR cycle it came from.
  func site(_ arguments: ToolArguments) async throws -> PerformanceSite {
    guard let identifier = try arguments.string("airport") else { return PerformanceSite() }
    let found = try await PeriodicQueries(store: store).search(
      kinds: ["airport"], sources: [.nasr],
      arguments: ToolArguments(["identifier": .string(identifier), "limit": 10]))
    let records = found.results.compactMap(\.objectValue)
    guard let record = records.first else {
      throw ToolInputError(reason: "No airport \(identifier) is in the current NASR cycle.")
    }
    guard records.count == 1 else {
      throw ToolInputError(
        reason: "\(identifier) matches several airports: "
          + records.compactMap { $0["id"]?.stringValue }.joined(separator: ", ") + ".")
    }
    return PerformanceSite(
      airport: PerformanceAirport(record), sources: found.sources, warnings: found.warnings)
  }

  /// Surface weather at the airport, fetched only for the fields the caller did not override.
  ///
  /// - Throws: ``WeatherFailure`` when the temperature or wind the calculation needs is neither
  ///   overridden nor available.
  func surfaceWeather(
    _ arguments: ToolArguments, airport: PerformanceAirport?, needsTemperature: Bool
  ) async throws -> (resolved: ResolvedWeather, reported: ReportedWeather) {
    let overrides = try WeatherOverrides(arguments)
    let time = try arguments.instant("time", default: .now) ?? .now
    let reported = try await report(
      overrides.missingSurfaceFields(
        needsTemperature: needsTemperature, hasAirport: airport != nil),
      at: time, airport: airport, required: true)
    return (
      try ResolvedWeather.resolve(
        reported: reported, overrides: overrides, time: time, needsTemperature: needsTemperature),
      reported
    )
  }

  /// The weather service's report of `fields` at the airport.
  ///
  /// - Parameter required: Whether a missing report fails the calculation; otherwise an empty
  ///   report comes back carrying the reason as a warning.
  /// - Throws: ``WeatherFailure`` when a required report is unavailable, naming the overrides
  ///   that would let the calculation proceed without it.
  func report(
    _ fields: [String], at time: Date, airport: PerformanceAirport?, required: Bool
  ) async throws -> ReportedWeather {
    guard !fields.isEmpty else { return ReportedWeather() }
    let overrides = Self.overrideNames(for: fields)
    guard let airport, let position = airport.position else {
      return try unavailable(
        "Weather is looked up only for an airport with a published position; supply "
          + "\(overrides) instead.", required: required)
    }
    let result = try await weather.weather(
      WeatherQuery(
        station: airport.identifier, latitude: position.latitude,
        longitude: position.longitude, instant: time, fields: fields, sources: nil))
    guard result.error == nil else {
      let reasons = result.warnings.isEmpty ? "" : " (\(result.warnings.joined(separator: " ")))"
      return try unavailable(
        "No report or forecast covers \(airport.identifier) at \(time.ISO8601Format())"
          + "\(reasons). Supply \(overrides) to calculate without it.", required: required)
    }
    return ReportedWeather(result)
  }

  private func unavailable(_ reason: String, required: Bool) throws -> ReportedWeather {
    guard !required else { throw WeatherFailure(provider: "weather", reason: reason) }
    var report = ReportedWeather()
    report.warnings = [reason]
    return report
  }

  private static func overrideNames(for fields: [String]) -> String {
    let names = fields.compactMap { field -> String? in
      switch field {
      case "temperature_c", "altimeter_inhg": field
      case "wind_speed_kt": "wind_direction_true_deg and wind_speed_kt"
      default: nil
      }
    }
    return names.isEmpty ? "temperature_c" : names.joined(separator: ", ")
  }

}

// MARK: - Results

extension PerformanceTools {

  static func result(
    _ results: [MCP.Value], site: PerformanceSite, weather: ReportedWeather,
    figures: FigureEncoder, warnings: [String]
  ) -> ToolResult {
    var seen = Set<String>()
    let sources = (site.sources + weather.sources).filter {
      seen.insert($0.source + "/" + $0.cycle).inserted
    }
    return ToolResult(
      results: results, sources: sources,
      completeness: figures.isPartial
        || ![warnings, site.warnings, weather.warnings].allSatisfy(\.isEmpty)
        ? "partial" : "complete",
      warnings: warnings + figures.allWarnings + site.warnings + weather.warnings,
      rateLimits: weather.rateLimits,
      liveSources: weather.liveSources(for: Array(weather.fields.keys).sorted()))
  }

  private static func obstacle(
    _ obstacle: Obstacle, results: TakeoffResults, runway: RunwayInput
  ) -> MCP.Value {
    var fields: [String: MCP.Value] = [
      "height_ft": .double(obstacle.height.converted(to: .feet).value),
      "distance_from_departure_end_ft": .double(
        obstacle.distanceFromDepartureEnd.converted(to: .feet).value)
    ]
    guard let distance = results.takeoffDistance.nominalOrClamped else {
      fields["requirement"] = "unknown"
      return .object(fields)
    }
    let climb = results.takeoffClimbGradient.nominalOrClamped
    if results.takeoffDistance.isOffscale || results.takeoffClimbGradient.isOffscale {
      fields["basis"] = "clamped"
      fields["basis_note"] = .string(PerformanceJSON.clampedNote)
    }
    let requirement = obstacle.climbRequirement(
      takeoffDistance: distance, availableTakeoffRun: runway.availableTakeoffRun)
    fields["cleared"] = .bool(requirement.isMet(by: climb))
    switch requirement {
    case .none: fields["requirement"] = "none"
    case .unclearable: fields["requirement"] = "unclearable"
    case .gradient(let required):
      let requiredFtNM = PerformanceJSON.feetPerNauticalMile(required)
      fields["requirement"] = "gradient"
      fields["required_gradient_ft_per_nm"] = .double(requiredFtNM)
      if let climb {
        fields["margin_ft_per_nm"] = .double(
          PerformanceJSON.feetPerNauticalMile(climb) - requiredFtNM)
      }
    }
    return .object(fields)
  }

  private static func contamination(_ contamination: Contamination?) -> MCP.Value? {
    guard let contamination else { return nil }
    var fields: [String: MCP.Value] = ["origin": "override"]
    switch contamination {
    case .wetRunway: fields["type"] = "wet"
    case .drySnow: fields["type"] = "dry_snow"
    case .compactSnow: fields["type"] = "compact_snow"
    case .waterOrSlush(let depth), .slushOrWetSnow(let depth):
      fields["type"] = .string(
        contamination.type == "waterOrSlush" ? "water_or_slush" : "slush_or_wet_snow")
      fields["depth_in"] = .double(depth.converted(to: .inches).value)
    case .rwyCC(let code):
      fields["type"] = "rwycc"
      fields["rwycc"] = .int(Int(code))
    }
    return .object(fields)
  }
}

/// The airport a calculation is for, if any, and the NASR cycle it came from.
struct PerformanceSite: Sendable {
  var airport: PerformanceAirport?
  var sources: [SourceStamp] = []
  var warnings: [String] = []

  /// The runway end the arguments name, refusing a calculation that lacks a distance it needs.
  ///
  /// - Parameters:
  ///   - distanceArgument: The argument that supplies the needed distance.
  ///   - distance: Reads the needed distance from the resolved runway.
  func runway(
    _ arguments: ToolArguments, requiring distanceArgument: String,
    distance: (ResolvedRunway) -> Sourced<Double>?
  ) throws -> ResolvedRunway {
    let runway = try runway(arguments, name: arguments.string("runway"))
    guard distance(runway) != nil else {
      throw ToolInputError(
        reason: "The runway's available distance is unknown; supply \(distanceArgument).")
    }
    return runway
  }

  /// The runway end `name`, or the runway the overrides describe when there is no airport.
  func runway(_ arguments: ToolArguments, name: String?) throws -> ResolvedRunway {
    let overrides = try RunwayOverrides(arguments)
    guard let airport else {
      var runway = try ResolvedRunway.resolve(airport: nil, end: nil, overrides: overrides)
      runway.name = name
      return runway
    }
    guard let name else { throw ToolInputError(reason: "runway is required with airport.") }
    return try ResolvedRunway.resolve(
      airport: airport, end: airport.end(name), overrides: overrides)
  }

  /// Every input echoed with its origin.
  func inputs(
    runway: ResolvedRunway, weather: ResolvedWeather, pressureAltitude: Measurement<UnitLength>
  ) throws -> [String: MCP.Value] {
    var inputs = try runway.provenance().merging(
      weather.provenance(pressureAltitude: pressureAltitude)
    ) { $1 }
    inputs["airport"] = airport?.description
    return inputs
  }
}

extension MCP.Value {
  /// The object with `fields` added, replacing any of the same name.
  func merging(_ fields: [String: Self]) -> Self {
    .object((objectValue ?? [:]).merging(fields) { $1 })
  }
}

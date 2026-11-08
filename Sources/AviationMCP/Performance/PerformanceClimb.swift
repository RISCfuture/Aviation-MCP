import AircraftPerformance
import Foundation
import MCP
import MeasurementKit

extension PerformanceTools {
  /// Climb gradient and rate by altitude for every climb schedule, from the field to a top
  /// altitude, in the forecast winds aloft.
  func climbProfile(_ arguments: ToolArguments, through interface: PerformanceInterface)
    async throws -> ToolResult
  {
    let aircraft = try PerformanceAircraft(arguments, through: interface)
    let weight = try aircraft.weight(
      within: aircraft.limitations.maxTakeoffWeight, operation: "takeoff")
    let topFt = try aircraft.climbTopFt(arguments)
    let course = try arguments.number("course_true_deg", range: 0...360)
    let site = try await site(arguments)
    var fieldWarnings: [String] = []
    let field = try Self.fieldElevation(arguments, site: site, warnings: &fieldWarnings)
    guard topFt > field.value else {
      throw ToolInputError(reason: "top_altitude_ft must be above the field elevation.")
    }
    let overrides = try WeatherOverrides(arguments)
    let time = try arguments.instant("time", default: .now) ?? .now
    let reported = try await report(
      Self.climbWeatherFields(overrides), at: time, airport: site.airport, required: false)
    let atmosphere = ClimbAtmosphere(
      reported: reported, overrides: overrides, time: time, fieldElevationFt: field.value)
    let profile = try ClimbProfileGenerator.generate(
      windsAloft: atmosphere.observations, weightLb: weight.converted(to: .pounds).value,
      aircraft: aircraft.aircraft, seaLevelPressureInHg: atmosphere.altimeterInHg?.value ?? 29.92,
      useRegressionModel: aircraft.model == .regression)
    let climb = ClimbReport(
      profile: profile, schedules: ClimbReport.schedules(for: aircraft.aircraft),
      fieldFt: field.value, topFt: topFt, courseDeg: course,
      windsApplied: !atmosphere.isCalm,
      terrainStart: try Self.terrainStart(arguments, site: site, field: field))
    var figures = FigureEncoder(model: aircraft.model)
    var inputs = try Self.climbInputs(
      arguments, atmosphere: atmosphere, time: time, field: field, site: site)
    inputs["top_altitude_ft"] = .double(topFt)
    let schedules = climb.schedules(figures: &figures)
    var value: [String: MCP.Value] = [
      "aircraft": aircraft.description(includingSafetyFactor: false), "inputs": .object(inputs),
      "levels": .array(climb.levels()), "schedules": .object(schedules),
      "disclaimers": .array(aircraft.disclaimers.map(MCP.Value.string))
    ]
    value.merge(
      try Self.timeFuelDistance(
        aircraft, fromFt: field.value, toFt: topFt, altimeterInHg: atmosphere.altimeterInHg?.value,
        figures: &figures)
    ) { $1 }
    value["unavailable_outputs"] = aircraft.unavailable(
      ClimbReport.unavailableSchedules(for: aircraft.aircraft) + Self.timeFuelDistanceOutputs)
    value["query_terrain"] = climb.terrainComparison(schedules)
    Self.warnAboveKnownAtmosphere(topFt, atmosphere: atmosphere, figures: &figures)
    return Self.result(
      [.object(value)], site: site, weather: reported, figures: figures,
      warnings: fieldWarnings + atmosphere.warnings)
  }

  private static func warnAboveKnownAtmosphere(
    _ topFt: Double, atmosphere: ClimbAtmosphere, figures: inout FigureEncoder
  ) {
    guard topFt > atmosphere.highestLevelFt else { return }
    figures.warn(
      "The atmosphere above \(Int(atmosphere.highestLevelFt)) ft is unknown; figures above it "
        + "hold the conditions there.")
  }

  /// Every input of a climb echoed with its origin.
  private static func climbInputs(
    _ arguments: ToolArguments, atmosphere: ClimbAtmosphere, time: Date, field: Sourced<Double>,
    site: PerformanceSite
  ) throws -> [String: MCP.Value] {
    var inputs = try atmosphere.inputs(time: time)
    inputs["field_elevation_ft"] = try .encoded(field)
    inputs["airport"] = site.airport?.description
    inputs["runway"] = try arguments.string("runway").map(MCP.Value.string)
    inputs["course_true_deg"] = try arguments.number("course_true_deg", range: 0...360).map(
      MCP.Value.double)
    return inputs
  }

  /// The weather fields a climb reads that the caller did not override.
  private static func climbWeatherFields(_ overrides: WeatherOverrides) -> [String] {
    ["pressure_levels"] + (overrides.temperatureC == nil ? ["temperature_c"] : [])
      + (overrides.altimeterInHg == nil ? ["altimeter_inhg"] : [])
  }

  private static func fieldElevation(
    _ arguments: ToolArguments, site: PerformanceSite, warnings: inout [String]
  ) throws -> Sourced<Double> {
    if let value = try arguments.number("elevation_ft", range: -1_500...15_000) {
      return Sourced(value, .override)
    }
    guard let airport = site.airport else {
      throw ToolInputError(reason: "The field elevation is unknown; supply elevation_ft.")
    }
    if let runway = try arguments.string("runway") {
      if let threshold = try airport.end(runway).number("threshold_elevation_msl_ft") {
        return Sourced(threshold, .nasr)
      }
      warnings.append(
        "NASR publishes no threshold elevation for this runway end; the airport elevation is used.")
    }
    guard let elevation = airport.elevationFt else {
      throw ToolInputError(
        reason: "NASR publishes no elevation for the airport; supply elevation_ft.")
    }
    return Sourced(elevation, .nasr, note: "airport elevation")
  }

  /// Where the departure corridor starts for `query_terrain`: the departure end of a named
  /// runway, which is the lower of its two threshold elevations, or the field elevation when no
  /// runway or an elevation override stands in for it.
  ///
  /// - Returns: `nil` when a named runway's departure-end elevation is unknown.
  private static func terrainStart(
    _ arguments: ToolArguments, site: PerformanceSite, field: Sourced<Double>
  ) throws -> ClimbReport.TerrainStart? {
    guard field.origin != .override, let airport = site.airport,
      let runway = try arguments.string("runway")
    else { return .init(altitudeFt: field.value, point: "field_elevation") }
    let end = try airport.end(runway)
    guard let threshold = end.number("threshold_elevation_msl_ft"),
      let far = end.opposite?["threshold_elevation_msl_ft"].flatMap(\.number)
    else { return nil }
    return .init(altitudeFt: min(threshold, far), point: "departure_end")
  }
}

/// A climb profile read out between the field and the top altitude.
struct ClimbReport {
  /// A climb schedule, by the name results give it.
  typealias Schedule = (name: String, type: ClimbProfile.ProfileType)

  /// Every climb schedule a profile can carry, with the capabilities an aircraft needs for it.
  private static let allSchedules: [(schedule: Schedule, needs: Set<PerformanceCapability>)] = [
    (("takeoff", .takeoff), []),
    (("enroute_obstacle", .enrouteObstacle(antiIce: false)), [.enrouteObstacleClimb]),
    (
      ("enroute_obstacle_ice", .enrouteObstacle(antiIce: true)),
      [.enrouteObstacleClimb, .iceProtection]
    ),
    (("enroute", .enroute(antiIce: false)), []),
    (("enroute_ice", .enroute(antiIce: true)), [.iceProtection])
  ]

  private static let levelStepFt = 1_000.0
  private static let samplingStepFt = 100.0

  /// Where `query_terrain` should start the climb.
  struct TerrainStart {
    let altitudeFt: Double
    /// `departure_end` or `field_elevation`.
    let point: String
  }

  let profile: ClimbProfile
  /// The schedules the aircraft's manuals have figures for.
  let schedules: [Schedule]
  let fieldFt: Double
  let topFt: Double
  let courseDeg: Double?
  /// Whether the profile's column carries wind, so that ground gradients differ from still-air
  /// ones.
  let windsApplied: Bool
  let terrainStart: TerrainStart?

  init(
    profile: ClimbProfile, schedules: [Schedule], fieldFt: Double, topFt: Double,
    courseDeg: Double?, windsApplied: Bool = true, terrainStart: TerrainStart? = nil
  ) {
    self.profile = profile
    self.schedules = schedules
    self.fieldFt = fieldFt
    self.topFt = topFt
    self.courseDeg = courseDeg
    self.windsApplied = windsApplied
    self.terrainStart = terrainStart
  }

  /// The schedules the aircraft's manuals have figures for.
  static func schedules(for aircraft: Aircraft) -> [Schedule] {
    allSchedules.filter { $0.needs.isSubset(of: aircraft.capabilities) }.map(\.schedule)
  }

  /// Each schedule the aircraft's manuals have no figures for, with a capability it lacks.
  static func unavailableSchedules(for aircraft: Aircraft) -> [(
    output: String, capability: PerformanceCapability
  )] {
    allSchedules.compactMap { schedule, needs in
      needs.subtracting(aircraft.capabilities).min { $0.rawValue < $1.rawValue }.map {
        ("schedules.\(schedule.name)", $0)
      }
    }
  }

  /// The field, each whole thousand feet above it, and the top.
  var levelAltitudes: [Double] {
    let first = ((fieldFt / Self.levelStepFt).rounded(.down) + 1) * Self.levelStepFt
    return [fieldFt] + Array(stride(from: first, to: topFt, by: Self.levelStepFt)) + [topFt]
  }

  /// The gradient over the ground along a course, from the still-air gradient and the wind.
  ///
  /// - Returns: The ground gradient, or `nil` where the wind leaves no groundspeed along the
  ///   course.
  static func groundGradient(
    air: Double, trueAirspeedKt: Double, windFromDeg: Double, windSpeedKt: Double,
    courseDeg: Double
  ) -> Double? {
    let angle = (windFromDeg - courseDeg) * .pi / 180
    let headwind = windSpeedKt * cos(angle)
    let crosswind = windSpeedKt * sin(angle)
    guard trueAirspeedKt > abs(crosswind) else { return nil }
    let groundSpeed =
      (trueAirspeedKt * trueAirspeedKt - crosswind * crosswind).squareRoot()
      - headwind
    guard groundSpeed > 0 else { return nil }
    return air * trueAirspeedKt / groundSpeed
  }

  /// Conditions and every schedule's figures at each level.
  func levels() -> [MCP.Value] {
    levelAltitudes.map { altitude in
      var level: [String: MCP.Value] = ["altitude_ft": .double(altitude.rounded())]
      if let point = profile.dataPoints.min(by: {
        abs($0.altitudeFt - altitude) < abs($1.altitudeFt - altitude)
      }) {
        level["outside_air_temperature_c"] = .double(
          (point.outsideAirTemperatureC * 10).rounded() / 10)
      }
      level["wind_direction_true_deg"] = profile.windDirection(at: altitude).map {
        .double($0.rounded())
      }
      level["wind_speed_kt"] = profile.windSpeed(at: altitude).map { .double($0.rounded()) }
      level["schedules"] = .object(
        Dictionary(
          uniqueKeysWithValues: schedules.map { ($0.name, figures(at: altitude, $0.type)) }))
      return .object(level)
    }
  }

  /// Each schedule's minimum gradient over the climb, distance to the top and any bands the manual
  /// data does not cover.
  func schedules(figures: inout FigureEncoder) -> [String: MCP.Value] {
    var schedules: [String: MCP.Value] = [:]
    for (name, type) in self.schedules {
      var summary: [String: MCP.Value] = [
        "minimum_gradient_ft_per_nm": figures.encode(
          minimum(type) { gradient(at: $0, type) }, "\(name) minimum_gradient_ft_per_nm"),
        "bands_without_gradient": .array(
          profile.bandsWithoutGradient(from: fieldFt, to: topFt, profile: type).map {
            .object(["from_ft": .double($0.lowerBound), "to_ft": .double($0.upperBound)])
          })
      ]
      summary["still_air_distance_nm"] = profile.distance(from: fieldFt, to: topFt, profile: type)
        .map { .double(($0 * 10).rounded() / 10) }
      if courseDeg != nil {
        summary["minimum_ground_gradient_ft_per_nm"] = FigureEncoder.json(
          minimum(type) { groundGradient(at: $0, type) }
        ) { .double($0.rounded(.down)) }
        summary["ground_distance_nm"] = groundDistance(type).map {
          .double(($0 * 10).rounded() / 10)
        }
      }
      schedules[name] = .object(summary)
    }
    return schedules
  }

  /// The takeoff schedule's minimum gradient, rounded down, ready for `query_terrain`.
  ///
  /// The gradient is over the ground only when a course is given and the column carries wind;
  /// a regression figure comes with its uncertainty. Nothing is returned where the corridor's
  /// starting point is unknown.
  func terrainComparison(_ schedules: [String: MCP.Value]) -> MCP.Value? {
    let overGround = courseDeg != nil && windsApplied
    let key = overGround ? "minimum_ground_gradient_ft_per_nm" : "minimum_gradient_ft_per_nm"
    guard let terrainStart,
      let gradient = schedules["takeoff"]?.objectValue?[key]?.objectValue,
      let value = gradient["value"]?.number
    else { return nil }
    var fields: [String: MCP.Value] = [
      "schedule": "takeoff", "basis": .string(overGround ? "ground" : "still_air"),
      "starting_point": .string(terrainStart.point),
      "starting_altitude_ft": .double(terrainStart.altitudeFt.rounded()),
      "gradient_ft_per_nm": .double(value.rounded(.down))
    ]
    fields["gradient_uncertainty_ft_per_nm"] = gradient["uncertainty"]
    return .object(fields)
  }

  private func figures(at altitude: Double, _ type: ClimbProfile.ProfileType) -> MCP.Value {
    let gradient = gradient(at: altitude, type)
    var fields: [String: MCP.Value] = [
      "gradient_ft_per_nm": FigureEncoder.json(gradient) { .double($0.rounded()) }
    ]
    if let air = gradient.nominal, let speed = profile.trueAirspeed(at: altitude, profile: type) {
      fields["true_airspeed_kt"] = .double(speed.rounded())
      fields["rate_ft_per_min"] = .double((air * speed / 60).rounded())
    }
    if courseDeg != nil {
      fields["ground_gradient_ft_per_nm"] = FigureEncoder.json(groundGradient(at: altitude, type)) {
        .double($0.rounded())
      }
    }
    return .object(fields)
  }

  /// The still-air gradient at an altitude, interpolated between the data points that bracket
  /// it with any uncertainty kept, or the model's refusal at the nearest bracketing point that
  /// has none.
  private func gradient(at altitude: Double, _ type: ClimbProfile.ProfileType)
    -> AircraftPerformance.Value<Double>
  {
    let points = profile.dataPoints
    guard let low = points.last(where: { $0.altitudeFt <= altitude }) ?? points.first,
      let high = points.first(where: { $0.altitudeFt >= altitude }) ?? points.last
    else { return .notAvailable }
    let (lowFigure, highFigure) = (
      low.climbData(for: type).gradientFtPerNM, high.climbData(for: type).gradientFtPerNM
    )
    guard let lowValue = lowFigure.nominal else { return lowFigure }
    guard let highValue = highFigure.nominal else { return highFigure }
    let span = high.altitudeFt - low.altitudeFt
    let fraction = span > 0 ? min(max((altitude - low.altitudeFt) / span, 0), 1) : 0
    func interpolated(_ low: Double, _ high: Double) -> Double { low + fraction * (high - low) }
    let value = interpolated(lowValue, highValue)
    guard lowFigure.uncertainty != nil || highFigure.uncertainty != nil else {
      return .value(value)
    }
    return .valueWithUncertainty(
      value,
      uncertainty: interpolated(lowFigure.uncertainty ?? 0, highFigure.uncertainty ?? 0))
  }

  private func groundGradient(at altitude: Double, _ type: ClimbProfile.ProfileType)
    -> AircraftPerformance.Value<Double>
  {
    let air = gradient(at: altitude, type)
    guard let courseDeg, air.nominal != nil else { return air }
    guard let speed = profile.trueAirspeed(at: altitude, profile: type),
      let factor = Self.groundGradient(
        air: 1, trueAirspeedKt: speed, windFromDeg: profile.windDirection(at: altitude) ?? 0,
        windSpeedKt: profile.windSpeed(at: altitude) ?? 0, courseDeg: courseDeg)
    else { return .notAvailable }
    return air.scaled(by: factor)
  }

  /// The lowest figure over the climb, with its uncertainty, or the first refusal met on the way
  /// up.
  func minimum(
    _ type: ClimbProfile.ProfileType, _ figure: (Double) -> AircraftPerformance.Value<Double>
  ) -> AircraftPerformance.Value<Double> {
    var lowest: AircraftPerformance.Value<Double>?
    for altitude in Array(stride(from: fieldFt, to: topFt, by: Self.samplingStepFt)) + [topFt] {
      let value = figure(altitude)
      guard let nominal = value.nominal else { return value }
      if lowest.flatMap(\.nominal).map({ nominal < $0 }) ?? true { lowest = value }
    }
    return lowest ?? .notAvailable
  }

  /// The ground distance to climb from the field to the top along the course.
  func groundDistance(_ type: ClimbProfile.ProfileType) -> Double? {
    var distance = 0.0
    var altitude = fieldFt
    while altitude < topFt {
      let step = min(Self.samplingStepFt, topFt - altitude)
      guard let low = groundGradient(at: altitude, type).nominal,
        let high = groundGradient(at: altitude + step, type).nominal, low + high > 0
      else { return nil }
      distance += step / ((low + high) / 2)
      altitude += step
    }
    return distance
  }
}

extension AircraftPerformance.Value where T == Double {
  /// The uncertainty of a figure that carries one.
  fileprivate var uncertainty: Double? {
    if case .valueWithUncertainty(_, let uncertainty) = self { uncertainty } else { nil }
  }

  /// A value or uncertain figure multiplied by a factor, uncertainty included; any other figure
  /// unchanged.
  fileprivate func scaled(by factor: Double) -> Self {
    switch self {
    case .value(let value): .value(value * factor)
    case .valueWithUncertainty(let value, let uncertainty):
      .valueWithUncertainty(value * factor, uncertainty: uncertainty * factor)
    default: self
    }
  }
}

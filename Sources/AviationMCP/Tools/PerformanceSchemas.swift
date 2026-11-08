import MCP

import enum AircraftPerformance.FlapSetting

extension ToolDefinition {
  /// The parameters a performance tool requires, and none for any other tool.
  var aircraftRequired: [String] {
    switch self {
    case .climbProfile: ["aircraft", "weight_lb", "top_altitude_ft"]
    case .takeoffLimits: ["aircraft", "solve_for"]
    case .takeoffPerformance, .landingPerformance: ["aircraft", "weight_lb"]
    case .sf50ClimbProfile: ["aircraft_generation", "weight_lb", "top_altitude_ft"]
    case .sf50TakeoffLimits: ["aircraft_generation", "solve_for"]
    case .sf50TakeoffPerformance, .sf50LandingPerformance: ["aircraft_generation", "weight_lb"]
    default: []
    }
  }

  /// The parameters a performance tool accepts, and none for any other tool.
  var aircraftParameters: [String: Value] {
    switch self {
    case .landingPerformance: PerformanceSchemas.landing
    case .climbProfile: PerformanceSchemas.climb
    case .takeoffLimits: PerformanceSchemas.limits
    case .takeoffPerformance: PerformanceSchemas.takeoff
    case .sf50TakeoffPerformance: PerformanceSchemas.sf50Takeoff
    case .sf50LandingPerformance: PerformanceSchemas.sf50Landing
    case .sf50ClimbProfile: PerformanceSchemas.sf50Climb
    case .sf50TakeoffLimits: PerformanceSchemas.sf50Limits
    default: [:]
    }
  }
}

/// Input schemas for the performance tools.
enum PerformanceSchemas {
  /// The `aircraft` object: one branch per aircraft type, told apart by `type`.
  static let aircraftObject: Value = ToolSchemas.described(
    [
      "type": "object",
      "anyOf": [
        .object([
          "type": "object", "required": ["type", "generation"], "additionalProperties": false,
          "properties": .object([
            "type": .object(["const": "sf50"]),
            "generation": ToolSchemas.choice(
              SF50Generations.names,
              "Cirrus SF50 generation: g1, g2, g2_updated_thrust (G2 with the updated thrust "
                + "schedule, SB5X-72-01), g2_plus or g3.")
          ])
        ]),
        .object([
          "type": "object",
          "required": ["type", .string(SR22Fields.hartzell), .string(SR22Fields.turbo)],
          "additionalProperties": false,
          "properties": .object([
            "type": .object(["const": "sr22"]),
            SR22Fields.hartzell: ToolSchemas.boolean(
              "Whether the Hartzell composite propeller is installed (POH supplement 13772-129)."),
            SR22Fields.turbo: ToolSchemas.boolean(
              "Whether the Tornado Alley turbonormalizing system is installed (STC SA10588SC).")
          ])
        ])
      ]
    ],
    "The aircraft and its installed options. Each result lists the aircraft's capabilities, "
      + "the manuals its figures come from, and any output those manuals have no figures for.")

  static let aircraft: [String: Value] = [
    "aircraft": aircraftObject,
    "weight_lb": ToolSchemas.number(
      PerformanceAircraft.weightRangeLb,
      "Aircraft weight in pounds, no more than the aircraft's maximum for the operation."),
    "model": ToolSchemas.choice(
      ["tabular", "regression"],
      "tabular (default) interpolates the AFM tables and reports offscale or not available "
        + "outside them; regression extrapolates and reports an uncertainty."),
    "safety_factor": ToolSchemas.number(
      1...3, "Multiplier applied to the calculated distances. Defaults to 1.")
  ]

  static let runway: [String: Value] = [
    "airport": ToolSchemas.text(
      "Airport as an FAA location identifier or ICAO code, such as OAK or KOAK; runway data "
        + "comes from the current NASR cycle and weather from the nearest report and forecast."),
    "runway": ToolSchemas.text("Runway end, such as 28R. Required with airport."),
    "elevation_ft": ToolSchemas.number(
      -1_500...15_000,
      "Runway elevation in feet MSL, replacing the threshold elevation. Required without airport."),
    "runway_heading_true_deg": ToolSchemas.number(
      0...360, "Runway true heading in degrees. Required without airport."),
    "slope_percent": ToolSchemas.number(
      -5...5, "Runway slope in percent, positive uphill in the direction of travel."),
    "surface": ToolSchemas.choice(
      ["paved", "grooved", "pfc", "turf"],
      "Runway surface; turf applies the manual's unpaved correction.")
  ]

  static let takeoffDistances: [String: Value] = [
    "available_takeoff_run_ft": ToolSchemas.number(
      0...30_000,
      "Takeoff run available (TORA) in feet, such as one a NOTAM shortens. Required without "
        + "airport."),
    "available_takeoff_distance_ft": ToolSchemas.number(
      0...30_000,
      "Takeoff distance available (TODA) in feet. Defaults to the published TODA, or to the "
        + "takeoff run available.")
  ]

  static let weather: [String: Value] = [
    "time": ToolSchemas.date(
      "Time of the takeoff or landing, ISO 8601 with a time zone. Defaults to now. Weather is the "
        + "METAR within an hour, otherwise the TAF and the Open-Meteo model."),
    "temperature_c": ToolSchemas.number(-60...60, "Outside air temperature in °C."),
    "wind_direction_true_deg": ToolSchemas.number(
      0...360, "Wind direction in degrees true, the direction the wind blows from."),
    "wind_speed_kt": ToolSchemas.number(0...100, "Steady wind speed in knots."),
    "altimeter_inhg": ToolSchemas.number(26...32, "Altimeter setting in inches of mercury.")
  ]

  static let obstacle: [String: Value] = [
    "obstacle_height_ft": ToolSchemas.number(
      0...3_000,
      "Height of an obstacle above the runway in feet. Requires obstacle_distance_ft."),
    "obstacle_distance_ft": ToolSchemas.number(
      0...100_000,
      "Distance of the obstacle beyond the departure end of the runway in feet. Requires "
        + "obstacle_height_ft.")
  ]

  static let contamination: [String: Value] = [
    "contamination": ToolSchemas.choice(
      PerformanceContamination.types,
      "Runway contamination, where the aircraft's manuals have figures for it: an aircraft with "
        + "the contamination capability takes any type on landing, and one with "
        + "wet_unpaved_correction takes wet on a turf runway for takeoff and landing. "
        + "water_or_slush and slush_or_wet_snow require contamination_depth_in; rwycc requires "
        + "rwycc."),
    "contamination_depth_in": ToolSchemas.number(0...4, "Contaminant depth in inches."),
    "rwycc": ToolSchemas.described(
      ["type": "integer", "minimum": 1, "maximum": 6],
      "Runway condition code, 1–6, for contamination rwycc.")
  ]

  static let takeoff = aircraft.merging(runway) { $1 }.merging(takeoffDistances) { $1 }
    .merging(weather) { $1 }.merging(obstacle) { $1 }.merging(contamination) { $1 }.merging([
      "air_conditioner": ToolSchemas.boolean(
        "Whether the air conditioner is on for takeoff, for an aircraft with the "
          + "air_conditioner_correction capability. Defaults to false.")
    ]) { $1 }

  static let landing = aircraft.merging(runway) { $1 }.merging(weather) { $1 }.merging([
    "available_landing_distance_ft": ToolSchemas.number(
      0...30_000,
      "Landing distance available (LDA) in feet, such as one a NOTAM shortens. Required without "
        + "airport."),
    "flaps": ToolSchemas.choice(
      landingFlapSettings.map(\.argument),
      "Landing flap setting, among those the aircraft's manuals give figures for; the _ice "
        + "settings are with ice protection on. Defaults to 100."),
    "vref_additive_kt": ToolSchemas.number(
      0...20,
      "Speed added to Vref in knots, for an aircraft with the vref capability. Defaults to 0.")
  ]) { $1 }.merging(contamination) { $1 }

  /// Every landing flap setting some aircraft has figures for, in the package's order.
  private static let landingFlapSettings = FlapSetting.allCases.filter { setting in
    AircraftArgument.all.contains { $0.landingFlapSettings.contains(setting) }
  }

  static let climb = aircraft.filter { $0.key != "safety_factor" }.merging([
    "airport": runway["airport"] ?? .null,
    "runway": ToolSchemas.text("Runway end whose threshold elevation the climb starts from."),
    "elevation_ft": ToolSchemas.number(
      -1_500...15_000,
      "Field elevation in feet MSL where the climb starts. Required without airport."),
    "top_altitude_ft": ToolSchemas.number(
      0...PerformanceAircraft.highestCeilingFt,
      "Altitude in feet MSL the climb ends at, no higher than the aircraft's maximum operating "
        + "altitude."),
    "course_true_deg": ToolSchemas.number(
      0...360, "True course flown during the climb, for ground gradients in the winds aloft."),
    "time": ToolSchemas.date(
      "Time of the climb, ISO 8601 with a time zone. Defaults to now. Winds aloft come from the "
        + "Open-Meteo model at this hour."),
    "temperature_c": ToolSchemas.described(
      weather["temperature_c"]?.objectValue ?? [:],
      "Surface temperature in °C. Replaces the forecast column with a calm one that holds this "
        + "temperature's deviation from the standard atmosphere all the way up."),
    "altimeter_inhg": weather["altimeter_inhg"] ?? .null
  ]) { $1 }

  static let limits = aircraft.merging(runway) { $1 }.merging(takeoffDistances) { $1 }
    .merging(weather) { $1 }.merging(obstacle) { $1 }.merging(contamination) { $1 }.merging([
      "runway": ToolSchemas.text(
        "Runway end, such as 15. Omit to calculate every end of the airport."),
      "solve_for": ToolSchemas.choice(
        ["weight", "temperature"],
        "weight finds the maximum takeoff weight at the conditions; temperature finds the "
          + "maximum outside air temperature at weight_lb."),
      "weight_lb": ToolSchemas.number(
        PerformanceAircraft.weightRangeLb,
        "Takeoff weight in pounds. Required when solve_for is temperature."),
      "minimum_weight_lb": ToolSchemas.number(
        PerformanceAircraft.weightRangeLb,
        "Lightest weight the weight search considers. Defaults to the lightest weight the "
          + "aircraft's takeoff tables cover.")
    ]) { $1 }

  /// The aircraft arguments of the deprecated SF50 aliases.
  static let sf50AliasAircraft: [String: Value] = [
    "aircraft_generation": ToolSchemas.choice(
      SF50Generations.names,
      "SF50 generation: g1, g2, g2_updated_thrust (G2 with the updated thrust schedule), "
        + "g2_plus or g3."),
    "weight_lb": ToolSchemas.number(
      PerformanceInterface.sf50AliasWeightRangeLb, "Aircraft weight in pounds.")
  ]

  static let sf50Takeoff = sf50Alias(takeoff, removing: contamination.keys + ["air_conditioner"])
  static let sf50Landing = sf50Alias(landing)
  static let sf50Climb = sf50Alias(climb)
  static let sf50Limits = sf50Alias(limits, removing: Array(contamination.keys)).merging([
    "weight_lb": ToolSchemas.number(
      PerformanceInterface.sf50AliasWeightRangeLb,
      "Takeoff weight in pounds. Required when solve_for is temperature."),
    "minimum_weight_lb": ToolSchemas.number(
      PerformanceInterface.sf50AliasWeightRangeLb,
      "Lightest weight the weight search considers. Defaults to 5,000 lb, the lightest weight "
        + "the AFM takeoff data covers.")
  ]) { $1 }

  /// A tool's parameters as its SF50 alias takes them: `aircraft_generation` in place of the
  /// `aircraft` object, without the parameters the alias does not take.
  private static func sf50Alias(_ parameters: [String: Value], removing removed: [String] = [])
    -> [String: Value]
  {
    parameters.filter { $0.key != "aircraft" && !removed.contains($0.key) }
      .merging(sf50AliasAircraft) { $1 }
  }
}

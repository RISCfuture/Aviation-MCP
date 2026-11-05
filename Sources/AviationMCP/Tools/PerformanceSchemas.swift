import MCP

extension ToolDefinition {
  /// The parameters a performance tool requires.
  var sf50Required: [String] {
    switch self {
    case .climbProfile: ["aircraft_generation", "weight_lb", "top_altitude_ft"]
    case .takeoffLimits: ["aircraft_generation", "solve_for"]
    case .takeoffPerformance, .landingPerformance: ["aircraft_generation", "weight_lb"]
    default: []
    }
  }

  /// The parameters a performance tool accepts.
  var sf50Parameters: [String: Value] {
    switch self {
    case .landingPerformance: PerformanceSchemas.landing
    case .climbProfile: PerformanceSchemas.climb
    case .takeoffLimits: PerformanceSchemas.limits
    case .takeoffPerformance: PerformanceSchemas.takeoff
    default: [:]
    }
  }
}

/// Input schemas for the SF50 performance tools.
enum PerformanceSchemas {
  static let aircraft: [String: Value] = [
    "aircraft_generation": ToolSchemas.choice(
      PerformanceAircraft.generations,
      "SF50 generation: g1, g2, g2_updated_thrust (G2 with the updated thrust schedule), "
        + "g2_plus or g3."),
    "weight_lb": ToolSchemas.number(3_000...7_000, "Aircraft weight in pounds."),
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
      "Runway surface; turf applies the AFM unpaved correction.")
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

  static let takeoff = aircraft.merging(runway) { $1 }.merging(takeoffDistances) { $1 }
    .merging(weather) { $1 }.merging(obstacle) { $1 }

  static let landing = aircraft.merging(runway) { $1 }.merging(weather) { $1 }.merging([
    "available_landing_distance_ft": ToolSchemas.number(
      0...30_000,
      "Landing distance available (LDA) in feet, such as one a NOTAM shortens. Required without "
        + "airport."),
    "flaps": ToolSchemas.choice(
      PerformanceAircraft.landingFlaps,
      "Landing flap setting; the _ice settings are with ice protection on. Defaults to 100."),
    "contamination": ToolSchemas.choice(
      PerformanceContamination.types,
      "Runway contamination. water_or_slush and slush_or_wet_snow require "
        + "contamination_depth_in; rwycc requires rwycc."),
    "contamination_depth_in": ToolSchemas.number(0...4, "Contaminant depth in inches."),
    "rwycc": ToolSchemas.described(
      ["type": "integer", "minimum": 1, "maximum": 6],
      "Runway condition code, 1–6, for contamination rwycc."),
    "vref_additive_kt": ToolSchemas.number(0...20, "Speed added to Vref in knots. Defaults to 0.")
  ]) { $1 }

  static let climb = aircraft.filter { $0.key != "safety_factor" }.merging([
    "airport": runway["airport"] ?? .null,
    "runway": ToolSchemas.text("Runway end whose threshold elevation the climb starts from."),
    "elevation_ft": ToolSchemas.number(
      -1_500...15_000,
      "Field elevation in feet MSL where the climb starts. Required without airport."),
    "top_altitude_ft": ToolSchemas.number(0...31_000, "Altitude in feet MSL the climb ends at."),
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
    .merging(weather) { $1 }.merging(obstacle) { $1 }.merging([
      "runway": ToolSchemas.text(
        "Runway end, such as 15. Omit to calculate every end of the airport."),
      "solve_for": ToolSchemas.choice(
        ["weight", "temperature"],
        "weight finds the maximum takeoff weight at the conditions; temperature finds the "
          + "maximum outside air temperature at weight_lb."),
      "weight_lb": ToolSchemas.number(
        3_000...7_000, "Takeoff weight in pounds. Required when solve_for is temperature."),
      "minimum_weight_lb": ToolSchemas.number(
        3_000...7_000,
        "Lightest weight the weight search considers. Defaults to 5,000 lb, the lightest weight "
          + "the AFM takeoff data covers.")
    ]) { $1 }
}

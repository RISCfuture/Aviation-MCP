import MCP

enum DomainGroup: String, CaseIterable, Sendable {
  case airports, navigation, airspace, procedures, obstacles, aircraft, weather, notams, geography,
    status, terrain, performance
}

enum ToolDefinition: String, CaseIterable, Sendable {
  case findAirports = "find_airports"
  case getAirport = "get_airport"
  case findNavigation = "find_navigation"
  case getAirway = "get_airway"
  case findRoutes = "find_routes"
  case queryAirspace = "query_airspace"
  case findProcedures = "find_procedures"
  case getProcedure = "get_procedure"
  case queryObstacles = "query_obstacles"
  case getAircraft = "get_aircraft"
  case getWeather = "get_weather"
  case parseWeather = "parse_weather"
  case queryNOTAMs = "query_notams"
  case convertCoordinates = "convert_coordinates"
  case computeGeometry = "compute_geometry"
  case getDataStatus = "get_data_status"
  case queryTerrain = "query_terrain"
  case takeoffPerformance = "takeoff_performance"
  case landingPerformance = "landing_performance"
  case climbProfile = "climb_profile"
  case takeoffLimits = "takeoff_limits"
  // Deprecated aliases of the four tools above, for clients built against the SF50-only names;
  // to be removed once those clients have moved.
  case sf50TakeoffPerformance = "sf50_takeoff_performance"
  case sf50LandingPerformance = "sf50_landing_performance"
  case sf50ClimbProfile = "sf50_climb_profile"
  case sf50TakeoffLimits = "sf50_takeoff_limits"

  var group: DomainGroup {
    switch self {
    case .findAirports, .getAirport: .airports
    case .findNavigation, .getAirway, .findRoutes: .navigation
    case .queryAirspace: .airspace
    case .findProcedures, .getProcedure: .procedures
    case .queryObstacles: .obstacles
    case .getAircraft: .aircraft
    case .getWeather, .parseWeather: .weather
    case .queryNOTAMs: .notams
    case .convertCoordinates, .computeGeometry: .geography
    case .getDataStatus: .status
    case .queryTerrain: .terrain
    case .takeoffPerformance, .landingPerformance, .climbProfile, .takeoffLimits,
      .sf50TakeoffPerformance, .sf50LandingPerformance, .sf50ClimbProfile, .sf50TakeoffLimits:
      .performance
    }
  }

  var description: String {
    switch self {
    case .findAirports:
      "Search current FAA airports by identifier, name, position, runway length or surface. "
        + "Records include runways, elevation in feet MSL and CTAF/UNICOM frequencies."
    case .getAirport:
      "Get one airport and its runways by FAA location identifier or ICAO code (SQL or KSQL). "
        + "An identifier shared by several airports returns candidates; select one with record_id."
    case .findNavigation:
      "Find navaids, fixes, ILS facilities, holds, flight service stations and AWOS/ASOS "
        + "stations in the current cycle by identifier, name or position."
    case .getAirway:
      "Get an airway's ordered fixes with MEA, MOCA, distance and magnetic course per segment. "
        + "Supply entry_fix and exit_fix to return only that portion, in travel order."
    case .findRoutes:
      "Find preferred IFR routes and coded departure routes by origin, destination or identifier; "
        + "airport matches either end."
    case .queryAirspace:
      "Find airspace containing or near a position or route, optionally at an MSL altitude, "
        + "or by identifier or airport. Results give distance_nm and whether the reference is "
        + "inside; ARTCC facility and boundary point records do not establish containment."
    case .findProcedures:
      "List an airport's approaches, departures and arrivals as summaries: identifier, "
        + "approach name, runways, transition and fix sequence, one record per transition. "
        + "Use get_procedure for legs and altitude and speed restrictions."
    case .getProcedure:
      "Get a procedure's legs with altitude and speed restrictions, joining the common route to "
        + "an optional transition. available_transitions lists each transition's initial fix and "
        + "altitude. Approaches use CIFP identifiers: I04R is ILS RWY 4R."
    case .queryObstacles:
      "Find obstacles near coordinates, a route, an airport/runway departure sector or an exact "
        + "procedure_id; highest ordering uses MSL elevation."
    case .getAircraft:
      "Get FAA Aircraft Characteristics Database data for an ICAO type designator: dimensions, "
        + "maximum takeoff weight, approach category, design groups and wake category. "
        + "It is not performance data."
    case .getWeather:
      "Get weather for a station or position at a time: the covering AWC METAR and the TAF in "
        + "force, from the nearest reporting station when needed. Modeled Open-Meteo values are "
        + "kept apart in model_supplement. Altimeter is in inHg and hPa; visibility in statute "
        + "miles."
    case .parseWeather:
      "Parse supplied METAR, TAF or winds-aloft text with an explicit reference date."
    case .queryNOTAMs:
      "Find NOTAMs overlapping a time window for an airport or position, including overlying-ARTCC "
        + "area NOTAMs such as TFRs; runway and procedure text matches are listed first."
    case .convertCoordinates: "Convert WGS84 latitude/longitude, UTM, UPS and MGRS coordinates."
    case .computeGeometry:
      "Compute WGS84 geodesic distances and initial true bearings, destination points, "
        + "or densified route paths."
    case .getDataStatus:
      "Report each source's effective cycle, availability, parse errors and next version."
    case .queryTerrain:
      "Find native-cell terrain maxima within a coordinate route corridor, "
        + "with optional conservative supplied-gradient comparison in EGM2008."
    case .takeoffPerformance:
      "Takeoff ground run and distance over a 50 ft screen for \(Self.aircraft), with the wind, "
        + "slope, surface and wet-turf corrections the manual gives, takeoff climb gradient, "
        + "margins against the runway, an optional obstacle and limitation notes. Runway data and "
        + "weather are looked up and can be overridden. \(Self.planningOnly)"
    case .landingPerformance:
      "Landing ground run and distance from 50 ft for \(Self.aircraft), with corrections for "
        + "wind, slope, surface and runway contamination where the manual gives them, Vref and "
        + "the go-around climb gradient or the balked landing climb where it has them, margins "
        + "against the runway and "
        + "limitation notes. \(Self.planningOnly)"
    case .climbProfile:
      "Climb gradient and rate by altitude from the field to a top altitude for "
        + "\(Self.aircraft), for each climb schedule the manual has (takeoff and enroute, and the "
        + "SF50's enroute-obstacle and ice-protection schedules), using forecast winds aloft, "
        + "with the SR22's time, fuel and distance to climb. "
        + "Gives ground gradients along a course and a minimum gradient for query_terrain. "
        + "\(Self.planningOnly)"
    case .takeoffLimits:
      "Maximum takeoff weight, or maximum outside air temperature at a weight, for "
        + "\(Self.aircraft), for one runway end or every end of an airport, with the constraint "
        + "that limits each. \(Self.planningOnly)"
    case .sf50TakeoffPerformance:
      "Cirrus SF50 Vision Jet takeoff ground run and distance over a 50 ft screen, with the wind, "
        + "slope and surface corrections applied, takeoff climb gradient, margins against the "
        + "runway, an optional obstacle and AFM limitation notes. \(Self.deprecation(of: .takeoffPerformance))"
    case .sf50LandingPerformance:
      "Cirrus SF50 Vision Jet landing Vref, ground run and distance from 50 ft, with corrections "
        + "for wind, slope, surface and runway contamination, the AFM go-around climb gradient and "
        + "margins against the runway. \(Self.deprecation(of: .landingPerformance))"
    case .sf50ClimbProfile:
      "Cirrus SF50 Vision Jet climb gradient and rate by altitude from the field to a top "
        + "altitude for every climb schedule, using forecast winds aloft. "
        + "\(Self.deprecation(of: .climbProfile))"
    case .sf50TakeoffLimits:
      "Cirrus SF50 Vision Jet maximum takeoff weight, or maximum outside air temperature at a "
        + "weight, with the constraint that limits each. \(Self.deprecation(of: .takeoffLimits))"
    }
  }

  /// The notice every SF50 alias's description ends with.
  private static func deprecation(of tool: Self) -> String {
    "Deprecated alias of \(tool.rawValue), to be removed: it takes aircraft_generation where "
      + "\(tool.rawValue) takes aircraft {\"type\": \"sf50\", \"generation\": …}. "
      + planningOnly
  }

  private static let planningOnly =
    "For pre-flight planning only, not for cockpit use; not FAA- or manufacturer-approved."
  private static let aircraft = "the Cirrus SF50 Vision Jet or Cirrus SR22, chosen by aircraft"

  var title: String {
    switch self {
    case .findAirports: "Find airports"
    case .getAirport: "Get airport and runways"
    case .findNavigation: "Find navigation records"
    case .getAirway: "Get airway segments"
    case .findRoutes: "Find published routes"
    case .queryAirspace: "Query airspace records"
    case .findProcedures: "Find instrument procedures"
    case .getProcedure: "Get procedure legs and restrictions"
    case .queryObstacles: "Query obstacles"
    case .getAircraft: "Get aircraft characteristics"
    case .getWeather: "Get aviation weather"
    case .parseWeather: "Parse weather reports"
    case .queryNOTAMs: "Query NOTAMs"
    case .convertCoordinates: "Convert coordinates"
    case .computeGeometry: "Compute distance and bearings"
    case .getDataStatus: "Get data availability and cycles"
    case .queryTerrain: "Query terrain elevations"
    case .takeoffPerformance: "Calculate takeoff performance"
    case .landingPerformance: "Calculate landing performance"
    case .climbProfile: "Calculate climb profile"
    case .takeoffLimits: "Calculate takeoff limits"
    case .sf50TakeoffPerformance: "Calculate SF50 takeoff performance (deprecated)"
    case .sf50LandingPerformance: "Calculate SF50 landing performance (deprecated)"
    case .sf50ClimbProfile: "Calculate SF50 climb profile (deprecated)"
    case .sf50TakeoffLimits: "Calculate SF50 takeoff limits (deprecated)"
    }
  }

  var tool: Tool {
    Tool(
      name: rawValue, title: title, description: description, inputSchema: ToolSchemas.input(self),
      annotations: .init(
        title: title, readOnlyHint: true, destructiveHint: false, idempotentHint: true,
        openWorldHint: [.weather, .notams, .terrain, .performance].contains(group)),
      outputSchema: ToolSchemas.output)
  }

  var periodicSources: [SourceName] {
    switch group {
    case .airports, .navigation, .performance: [.nasr]
    case .airspace: [.nasr, .cifp]
    case .procedures: [.cifp]
    case .obstacles: [.dof]
    case .aircraft: [.aircraft]
    default: []
    }
  }

  var kinds: [String] {
    switch self {
    case .findAirports, .getAirport: ["airport"]
    case .findNavigation: ["navaid", "fix", "ils", "hold", "fss", "awos"]
    case .getAirway: ["airway"]
    case .findRoutes: ["preferred_route", "coded_departure_route"]
    case .queryAirspace:
      [
        "airspace", "artcc_airspace", "artcc", "artcc_boundary", "parachute_area",
        "military_route"
      ]
    case .findProcedures, .getProcedure: ["procedure"]
    case .queryObstacles: ["obstacle"]
    case .getAircraft: ["aircraft"]
    default: []
    }
  }
}

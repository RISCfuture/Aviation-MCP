import MCP

enum DomainGroup: String, CaseIterable, Sendable {
  case airports, navigation, airspace, procedures, obstacles, aircraft, weather, notams, geography,
    status, terrain
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
      "Get weather for a station or position at a time: AWC METAR and TAF first, then modeled "
        + "Open-Meteo values. Altimeter is in inHg and hPa; visibility in statute miles."
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
    }
  }

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
    }
  }

  var tool: Tool {
    Tool(
      name: rawValue, title: title, description: description, inputSchema: ToolSchemas.input(self),
      annotations: .init(
        title: title, readOnlyHint: true, destructiveHint: false, idempotentHint: true,
        openWorldHint: group == .weather || group == .notams || group == .terrain),
      outputSchema: ToolSchemas.output)
  }

  var periodicSources: [SourceName] {
    switch group {
    case .airports, .navigation: [.nasr]
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

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
      "Find current airports by identifier, name, location or minimum runway length."
    case .getAirport: "Get an airport and its runways; ambiguous identifiers return candidates."
    case .findNavigation:
      "Find navaids, fixes, ILS, holds, FSS and AWOS records in the effective cycle."
    case .getAirway: "Get an airway with ordered source segments and restrictions."
    case .findRoutes: "Find preferred and coded departure routes in the effective cycle."
    case .queryAirspace:
      "Find published airspace and ARTCC records by identifier or available geometry; "
        + "point and boundary records do not establish airspace containment."
    case .findProcedures: "Find departures, arrivals and approaches by airport and identifier."
    case .getProcedure: "Get procedure transitions, leg restrictions and geometry coverage gaps."
    case .queryObstacles:
      "Find obstacles near coordinates, a route, an airport/runway departure end or an exact procedure_id; "
        + "highest ordering uses MSL elevation."
    case .getAircraft:
      "Find published aircraft characteristics and performance by ICAO type identifier."
    case .getWeather:
      "Get aviation weather with AWC priority and modeled Open-Meteo supplements; sources are selectable."
    case .parseWeather:
      "Parse supplied METAR, TAF or winds-aloft text with an explicit reference date."
    case .queryNOTAMs:
      "Find overlapping NOTAMs; preserve schedules and include uncertain runway or procedure matches."
    case .convertCoordinates: "Convert WGS84 latitude/longitude, UTM, UPS and MGRS coordinates."
    case .computeGeometry:
      "Compute WGS84 geodesic routes, distances, true bearings or destination coordinates."
    case .getDataStatus: "Report effective source cycles, availability and provenance."
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
    case .queryAirspace: ["airspace", "artcc", "artcc_boundary", "parachute_area", "military_route"]
    case .findProcedures, .getProcedure: ["procedure"]
    case .queryObstacles: ["obstacle"]
    case .getAircraft: ["aircraft"]
    default: []
    }
  }
}

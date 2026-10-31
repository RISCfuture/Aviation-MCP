import MCP

enum ToolSchemas {
  static let output: Value = .object([
    "type": "object", "required": ["results", "sources", "completeness", "warnings", "retrievedAt"],
    "properties": .object([
      "results": .object(["type": "array", "items": .object(["type": "object"])]),
      "sources": .object([
        "type": "array",
        "items": .object(["type": "object", "required": ["source", "cycle", "effectiveFrom"]])
      ]),
      "liveSources": .object([
        "type": "array",
        "items": .object([
          "type": "object",
          "required": ["provider", "retrievedAt"]
        ])
      ]),
      "completeness": enumeration(["complete", "partial", "unavailable"]),
      "warnings": .object(["type": "array", "items": textSchema]),
      "nextCursor": textSchema, "retrievedAt": .object(["type": "string", "format": "date-time"]),
      "rateLimits": .object(["type": ["array", "object"]]), "error": .object(["type": "object"])
    ])
  ])

  private static let textSchema: Value = .object([
    "type": "string", "minLength": 1, "maxLength": 16384
  ])

  static func input(_ tool: ToolDefinition) -> Value {
    .object([
      "type": "object", "properties": .object(tool.parameters),
      "required": .array(tool.requiredParameters.map(Value.string)), "additionalProperties": false
    ])
  }

  static func validate(_ arguments: ToolArguments, for tool: ToolDefinition) throws {
    let accepted = tool.parameters
    let unknown = arguments.values.keys.filter { accepted[$0] == nil }.sorted()
    guard unknown.isEmpty else {
      throw MCPError.invalidParams(
        "\(tool.rawValue) does not accept \(unknown.joined(separator: ", ")); "
          + "it accepts \(accepted.keys.sorted().joined(separator: ", ")).")
    }
    for key in tool.requiredParameters where arguments.values[key] == nil {
      throw MCPError.invalidParams("\(tool.rawValue) requires \(key).")
    }
  }

  fileprivate static func described(_ schema: [String: Value], _ description: String) -> Value {
    .object(schema.merging(["description": .string(description)]) { $1 })
  }

  fileprivate static func text(_ description: String) -> Value {
    described(textSchema.objectValue ?? [:], description)
  }

  fileprivate static func number(_ range: ClosedRange<Double>, _ description: String) -> Value {
    described(
      [
        "type": "number", "minimum": .double(range.lowerBound), "maximum": .double(range.upperBound)
      ],
      description)
  }

  fileprivate static func boolean(_ description: String) -> Value {
    described(["type": "boolean"], description)
  }

  fileprivate static func date(_ description: String) -> Value {
    described(["type": "string", "format": "date-time"], description)
  }

  fileprivate static func positions(_ count: ClosedRange<Int>, _ description: String) -> Value {
    described(
      [
        "type": "array", "minItems": .int(count.lowerBound), "maxItems": .int(count.upperBound),
        "items": .object([
          "type": "array", "minItems": 2, "maxItems": 2, "items": .object(["type": "number"])
        ])
      ], description)
  }

  fileprivate static func choice(_ values: [String], _ description: String) -> Value {
    described(enumeration(values).objectValue ?? [:], description)
  }

  private static func enumeration(_ values: [String]) -> Value {
    .object(["type": "string", "enum": .array(values.map(Value.string))])
  }
}

extension ToolDefinition {
  fileprivate var requiredParameters: [String] {
    switch self {
    case .getAirport, .getAirway, .getProcedure, .getAircraft: ["identifier"]
    case .parseWeather: ["type", "report"]
    case .queryNOTAMs: ["start", "end"]
    case .computeGeometry: ["operation"]
    case .queryTerrain: ["route", "half_width_nm"]
    default: []
    }
  }

  fileprivate var parameters: [String: Value] {
    switch self {
    case .findAirports: Airports.search
    case .getAirport: ["identifier": Airports.identifier, "record_id": Common.recordID]
    case .findNavigation: Navigation.search
    case .getAirway: Navigation.airway
    case .findRoutes: Navigation.routes
    case .queryAirspace: Airspace.search
    case .findProcedures: Procedures.search
    case .getProcedure: Procedures.detail
    case .queryObstacles: Obstacles.search
    case .getAircraft:
      ["identifier": ToolSchemas.text("ICAO aircraft type designator, such as C172, B738 or SF50.")]
    case .getWeather: Weather.query
    case .parseWeather: Weather.parsing
    case .queryNOTAMs: NOTAMs.query
    case .convertCoordinates: Geography.conversion
    case .computeGeometry: Geography.computation
    case .queryTerrain: Terrain.query
    case .getDataStatus: [:]
    }
  }
}

private enum Common {
  static let latitude = ToolSchemas.number(
    -90...90, "Latitude in decimal degrees (WGS84); north is positive. Requires longitude.")
  static let longitude = ToolSchemas.number(
    -180...180,
    "Longitude in decimal degrees (WGS84); east is positive, so U.S. longitudes are negative. "
      + "Requires latitude.")
  static let position = ["latitude": latitude, "longitude": longitude]
  static let radius = ToolSchemas.described(
    ["type": "number", "minimum": 0.01, "maximum": 500, "default": 5],
    "Search radius in nautical miles around the spatial context. Defaults to 5.")
  static let limit = ToolSchemas.described(
    ["type": "integer", "minimum": 1, "maximum": 200, "default": 50],
    "Maximum records per page, 1–200. Defaults to 50.")
  static let pagination: [String: Value] = [
    "limit": limit,
    "cursor": ToolSchemas.text(
      "nextCursor from the previous page; repeat every other argument unchanged.")
  ]
  static let query = textSearch("Case-insensitive substring of the record identifier or name.")
  static let recordID = ToolSchemas.text(
    "The id of one record from an earlier result, to select a single candidate.")
  static let geometry = ToolSchemas.described(
    ["type": "boolean", "default": false],
    "Include line and polygon GeoJSON geometry, which can be large. "
      + "Point positions are always included. Defaults to false.")
  static let airport = ToolSchemas.text(
    "Airport as an FAA location identifier or ICAO code, such as BOS or KBOS.")
  static let nearestOrder = ToolSchemas.choice(
    ["identifier", "nearest"],
    "nearest sorts by distance from latitude/longitude, which it requires, and is the default "
      + "when they are given; identifier sorts alphabetically and is the default otherwise.")
  static let route = ToolSchemas.positions(
    2...200, "Route as [longitude, latitude] pairs; searches within radius_nm of it.")

  /// A text search parameter; the trigram index needs at least three characters.
  static func textSearch(_ description: String) -> Value {
    ToolSchemas.described(
      ["type": "string", "minLength": 3, "maxLength": 16384],
      description + " At least 3 characters.")
  }

  static func kinds(_ tool: ToolDefinition) -> Value {
    ToolSchemas.described(
      [
        "type": "array", "minItems": 1,
        "items": .object(["type": "string", "enum": .array(tool.kinds.map(Value.string))])
      ],
      "Record kinds to search. Defaults to all: \(tool.kinds.joined(separator: ", ")).")
  }

  /// Identifier, name and position search over every kind the tool covers.
  static func spatialSearch(_ tool: ToolDefinition) -> [String: Value] {
    position.merging(pagination) { $1 }.merging([
      "identifier": ToolSchemas.text("Exact record identifier."), "query": query,
      "radius_nm": radius, "order": nearestOrder, "kinds": kinds(tool)
    ]) { $1 }
  }
}

private enum Airports {
  static let identifier = ToolSchemas.text(
    "Airport identifier: FAA location identifier or ICAO code, such as SQL or KSQL.")
  static let search = Common.position.merging(Common.pagination) { $1 }.merging([
    "identifier": identifier,
    "query": Common.textSearch("Case-insensitive substring of the airport identifier or name."),
    "radius_nm": Common.radius, "order": Common.nearestOrder,
    "minimum_runway_length_ft": ToolSchemas.number(
      0...30_000, "Require a runway at least this many feet long."),
    "public_use": ToolSchemas.boolean(
      "true returns only public-use airports; false only private-use airports."),
    "paved": ToolSchemas.boolean(
      "Require a runway with a paved (true) or unpaved (false) surface. "
        + "With minimum_runway_length_ft, the same runway must satisfy both."),
    "facility_type": ToolSchemas.choice(AirportFilters.facilityTypes, "Landing facility type.")
  ]) { $1 }
}

private enum Navigation {
  static let search = Common.spatialSearch(.findNavigation).merging([
    "identifier": ToolSchemas.text(
      "Exact identifier of a navaid (SFO), fix (GOSHI), ILS facility, hold, FSS or AWOS."),
    "airport": ToolSchemas.text(
      "Airport of ILS and FSS records, as an FAA location identifier or ICAO code.")
  ]) { $1 }
  static let airway: [String: Value] = [
    "identifier": ToolSchemas.text("Airway designation, such as V25, J80 or T319."),
    "record_id": Common.recordID,
    "entry_fix": ToolSchemas.text(
      "Fix or navaid identifier where the returned portion starts. Requires exit_fix."),
    "exit_fix": ToolSchemas.text(
      "Fix or navaid identifier where the returned portion ends. Requires entry_fix."),
    "include_geometry": Common.geometry
  ]
  static let routes = Common.pagination.merging([
    "identifier": ToolSchemas.text(
      "Coded departure route code or preferred route designator."),
    "query": Common.textSearch(
      "Case-insensitive substring of the route identifier or name, such as a destination "
        + "identifier."),
    "airport": ToolSchemas.text(
      "Airport at either end of the route, as an FAA location identifier or ICAO code."),
    "origin": ToolSchemas.text("Departure airport, as an FAA location identifier or ICAO code."),
    "destination": ToolSchemas.text(
      "Arrival airport, as an FAA location identifier or ICAO code."),
    "kinds": Common.kinds(.findRoutes)
  ]) { $1 }
}

private enum Airspace {
  static let search = Common.spatialSearch(.queryAirspace).merging([
    "airport": ToolSchemas.text(
      "Airport whose controlled airspace to return, as an FAA location identifier or ICAO code."),
    "route": ToolSchemas.positions(
      2...200, "Route as [longitude, latitude] pairs; finds airspace the route crosses or nears."),
    "altitude_ft": ToolSchemas.number(
      -1_500...100_000,
      "Altitude in feet MSL; excludes airspace whose vertical limits exclude it."),
    "include_geometry": Common.geometry
  ]) { $1 }
}

private enum Procedures {
  static let identifier = ToolSchemas.text(
    "CIFP procedure identifier. Approaches are the type letter and runway, such as I04R for "
      + "ILS RWY 4R or R30-Y for RNAV (GPS) Y RWY 30; departures and arrivals use their "
      + "computer code, such as PORTE3.")
  static let type = ToolSchemas.choice(["approach", "departure", "arrival"], "Procedure type.")
  static let search = Common.pagination.merging([
    "airport": Common.airport, "identifier": identifier, "procedure_type": type,
    "runway": ToolSchemas.text("Runway served, such as 4R or 04R."),
    "transition": ToolSchemas.text(
      "Transition name; returns that transition and routes common to all transitions.")
  ]) { $1 }
  static let detail: [String: Value] = [
    "identifier": identifier, "airport": Common.airport, "procedure_type": type,
    "transition": ToolSchemas.text(
      "Transition to join to the common route, such as GOSHI; available_transitions lists them. "
        + "Without it, only the common or final route is expanded."),
    "record_id": Common.recordID, "include_geometry": Common.geometry,
    "limit": Common.limit
  ]
}

private enum Obstacles {
  static let search = Common.position.merging(Common.pagination) { $1 }.merging([
    "identifier": ToolSchemas.text("Digital Obstacle File obstacle number."),
    "radius_nm": ToolSchemas.described(
      ["type": "number", "minimum": 0.01, "maximum": 500, "default": 5],
      "Search radius in nautical miles around the coordinates, route or procedure path, or the "
        + "length of a runway departure area. Defaults to 5."),
    "airport": ToolSchemas.text(
      "Airport of a runway departure search, as an FAA location identifier or ICAO code. "
        + "Requires runway."),
    "runway": ToolSchemas.text("Runway whose departure area is searched. Requires airport."),
    "departure_area": ToolSchemas.choice(
      ["sector", "circle"],
      "Area searched for an airport and runway: sector (default) splays 15° either side of the "
        + "runway course from 500 ft either side of the departure end; circle is centered on the "
        + "departure end. Neither is a TERPS assessment."),
    "procedure_id": ToolSchemas.text(
      "Exact procedure id from find_procedures; searches its determinable path."),
    "route": Common.route,
    "order": ToolSchemas.choice(
      ["highest", "nearest", "identifier"],
      "highest (default) sorts by MSL elevation; nearest sorts by distance from the spatial "
        + "context; identifier sorts alphabetically.")
  ]) { $1 }
}

private enum Weather {
  static let query = Common.position.merging([
    "station": ToolSchemas.text(
      "ICAO weather station, such as KSFO. Alternatively supply latitude and longitude."),
    "time": ToolSchemas.date(
      "Time to report, ISO 8601 with a time zone, such as 2026-10-31T18:00:00Z. Defaults to now."),
    "sources": ToolSchemas.described(
      [
        "type": "array", "minItems": 1, "maxItems": 2,
        "items": .object(["type": "string", "enum": ["awc", "open_meteo"]])
      ],
      "Providers in priority order: awc (METAR and TAF) and open_meteo (modeled forecast). "
        + "Defaults to both."),
    "fields": ToolSchemas.described(
      [
        "type": "array", "minItems": 1,
        "items": .object([
          "type": "string", "enum": .array(WeatherQuery.supportedFields.map(Value.string))
        ])
      ], "Weather fields to return. Defaults to all.")
  ]) { $1 }
  static let parsing: [String: Value] = [
    "type": ToolSchemas.choice(["metar", "taf", "winds_aloft"], "Report type."),
    "report": ToolSchemas.text("Raw report text."),
    "reference_date": ToolSchemas.date(
      "A time near the report's issue, ISO 8601 with a time zone, used to resolve its "
        + "day-of-month groups. Defaults to now.")
  ]
}

private enum NOTAMs {
  static let query = Common.position.merging(Common.pagination) { $1 }.merging([
    "location": ToolSchemas.text(
      "Airport as an FAA location identifier or ICAO code (SFO or KSFO), or another NOTAM "
        + "location such as an ARTCC. Required unless latitude and longitude are given."),
    "latitude": ToolSchemas.number(
      -90...90, "Reference latitude for area NOTAMs, decimal degrees. Requires longitude."),
    "longitude": ToolSchemas.number(
      -180...180,
      "Reference longitude for area NOTAMs, decimal degrees; west is negative. Requires latitude."),
    "radius_nm": ToolSchemas.described(
      ["type": "number", "minimum": 1, "maximum": 200, "default": 30],
      "Radius in nautical miles around the airport or position within which overlying-ARTCC "
        + "NOTAM centers (TFRs and other area NOTAMs) are included. Defaults to 30."),
    "start": ToolSchemas.date("Start of the time window, ISO 8601 with a time zone."),
    "end": ToolSchemas.date(
      "End of the time window, ISO 8601 with a time zone. NOTAMs overlapping the window match."),
    "scope": ToolSchemas.choice(
      ["A", "E", "W"], "Q-line scope: A aerodrome, E en route, W navigation warning."),
    "runway": ToolSchemas.text(
      "Runway to match as a whole word in NOTAM text, such as 4R (also matches 04R); matches "
        + "sort first and the rest are included as uncertain."),
    "procedure": ToolSchemas.text(
      "Procedure name to match in NOTAM text; matches sort first and the rest are included as "
        + "uncertain.")
  ]) { $1 }
}

private enum Geography {
  static let conversion = Common.position.merging([
    "coordinate": ToolSchemas.text("UTM, UPS or MGRS coordinate to convert. Requires format."),
    "format": ToolSchemas.choice(["utm", "ups", "mgrs"], "Format of coordinate.")
  ]) { $1 }
  static let computation: [String: Value] = [
    "operation": ToolSchemas.choice(
      ["destination", "distance", "route"],
      "destination projects latitude/longitude along course_true_deg for distance_nm. "
        + "distance returns the geodesic distance and initial true bearing along coordinates. "
        + "route also returns the densified geodesic path as GeoJSON."),
    "latitude": ToolSchemas.number(-90...90, "Start latitude for destination, decimal degrees."),
    "longitude": ToolSchemas.number(
      -180...180, "Start longitude for destination, decimal degrees; west is negative."),
    "distance_nm": ToolSchemas.number(0...20_000, "Distance to project, nautical miles."),
    "course_true_deg": ToolSchemas.number(0...360, "True course to project along, degrees."),
    "coordinates": ToolSchemas.positions(
      2...200, "Points for distance and route, as [longitude, latitude] pairs.")
  ]
}

private enum Terrain {
  static let query: [String: Value] = [
    "route": ToolSchemas.positions(2...20, "Corridor centerline as [longitude, latitude] pairs."),
    "half_width_nm": ToolSchemas.number(
      0.05...2, "Corridor half-width either side of the centerline, nautical miles."),
    "starting_altitude_ft": ToolSchemas.number(
      -1_500...60_000,
      "Altitude at the first route point in feet above the EGM2008 geoid, for a climb "
        + "comparison. Requires gradient_ft_per_nm, clearance_ft and vertical_datum."),
    "gradient_ft_per_nm": ToolSchemas.number(0...2_000, "Climb gradient, feet per nautical mile."),
    "clearance_ft": ToolSchemas.number(0...10_000, "Required clearance above terrain, feet."),
    "vertical_datum": ToolSchemas.choice(
      ["EGM2008"], "Vertical datum of starting_altitude_ft; required for a climb comparison.")
  ]
}

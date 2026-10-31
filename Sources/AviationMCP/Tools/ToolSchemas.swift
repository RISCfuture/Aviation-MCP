import MCP

enum ToolSchemas {
  static let text: Value = .object(["type": "string", "minLength": 1, "maxLength": 16384])
  static let number: Value = .object(["type": "number"])
  static let strings: Value = .object(["type": "array", "items": text, "maxItems": 20])
  static let position: [String: Value] = [
    "latitude": .object(["type": "number", "minimum": -90, "maximum": 90]),
    "longitude": .object(["type": "number", "minimum": -180, "maximum": 180])
  ]
  static let pagination: [String: Value] = [
    "limit": .object([
      "type": "integer", "minimum": 1,
      "maximum": 200, "default": 50
    ]), "cursor": text
  ]
  static let output: Value = .object([
    "type": "object", "required": ["results", "sources", "completeness", "warnings", "retrievedAt"],
    "properties": .object([
      "results": .object(["type": "array", "items": .object(["type": "object"])]),
      "sources": .object([
        "type": "array",
        "items": .object([
          "type": "object",
          "required": ["source", "cycle", "effectiveFrom", "checksum", "parserRevision"]
        ])
      ]),
      "liveSources": .object([
        "type": "array",
        "items": .object([
          "type": "object",
          "required": ["provider", "retrievedAt"]
        ])
      ]),
      "completeness": enumeration(["complete", "partial", "unavailable"]), "warnings": strings,
      "nextCursor": text, "retrievedAt": .object(["type": "string", "format": "date-time"]),
      "rateLimits": .object(["type": ["array", "object"]]), "error": .object(["type": "object"])
    ])
  ])

  static func input(_ tool: ToolDefinition) -> Value {
    var properties: [String: Value]
    var required: [String] = []
    switch tool {
    case .getWeather:
      properties = weatherProperties
    case .parseWeather:
      properties = [
        "type": enumeration(["metar", "taf", "winds_aloft"]), "report": text, "reference_date": date
      ]
      required = ["type", "report"]
    case .queryNOTAMs:
      properties = pagination.merging(notamArea) { _, new in new }.merging([
        "location": described(
          text,
          "Airport as a FAA LID or ICAO code, or another NOTAM location such as an ARTCC; "
            + "required unless latitude and longitude are given."),
        "start": date, "end": date,
        "scope": enumeration(["A", "E", "W"]), "runway": text, "procedure": text
      ]) { _, new in new }
      required = ["start", "end"]
    case .convertCoordinates:
      properties = position.merging([
        "coordinate": text, "format": enumeration(["utm", "ups", "mgrs"])
      ]) { _, new in new }
    case .computeGeometry:
      properties = position.merging([
        "operation": enumeration(["destination", "distance", "route"]),
        "distance_nm": number, "course_true_deg": number,
        "coordinates": .object([
          "type": "array", "minItems": 2, "maxItems": 200,
          "items": .object([
            "type": "array", "minItems": 2, "maxItems": 2, "items": number
          ])
        ])
      ]) { _, new in new }
      required = ["operation"]
    case .queryTerrain:
      properties = terrainProperties
      required = ["route", "half_width_nm"]
    case .getDataStatus: properties = [:]
    default:
      properties = periodic(tool)
      if [.getAirport, .getAirway, .getProcedure, .getAircraft].contains(tool) {
        required = ["identifier"]
      }
    }
    return .object([
      "type": "object", "properties": .object(properties),
      "required": .array(required.map(Value.string)), "additionalProperties": false
    ])
  }

  static func validate(_ arguments: ToolArguments, for tool: ToolDefinition) throws {
    guard let schema = input(tool).objectValue,
      let properties = schema["properties"]?.objectValue
    else { return }
    guard Set(arguments.values.keys).isSubset(of: Set(properties.keys)) else {
      throw MCPError.invalidParams("Unknown arguments for \(tool.rawValue)")
    }
    for key in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
      guard arguments.values[key] != nil else { throw MCPError.invalidParams("Missing \(key)") }
    }
  }

  private static var terrainProperties: [String: Value] {
    return [
      "route": .object([
        "type": "array", "minItems": 2, "maxItems": 20,
        "items": .object(["type": "array", "minItems": 2, "maxItems": 2, "items": number])
      ]),
      "half_width_nm": .object(["type": "number", "minimum": 0.05, "maximum": 2]),
      "starting_altitude_ft": number, "gradient_ft_per_nm": number, "clearance_ft": number,
      "vertical_datum": enumeration(["EGM2008"])
    ]
  }

  private static var weatherProperties: [String: Value] {
    position.merging([
      "station": text, "time": date,
      "sources": .object([
        "type": "array", "items": enumeration(["awc", "open_meteo"]), "minItems": 1, "maxItems": 2
      ]),
      "fields": .object([
        "type": "array", "items": enumeration(WeatherQuery.supportedFields), "minItems": 1
      ])
    ]) { _, new in new }
  }

  private static var date: Value { .object(["type": "string", "format": "date-time"]) }

  private static var route: Value {
    .object([
      "type": "array", "minItems": 2, "maxItems": 200,
      "items": .object(["type": "array", "minItems": 2, "maxItems": 2, "items": number])
    ])
  }

  private static var notamArea: [String: Value] {
    position.mapValues {
      described($0, "Reference position for area NOTAMs; replaces the airport position.")
    }.merging([
      "radius_nm": described(
        .object(["type": "number", "minimum": 1, "maximum": 200, "default": 30]),
        "Radius around the airport or position in which overlying-ARTCC NOTAM centers "
          + "(TFRs and other area NOTAMs) are included, in nautical miles.")
    ]) { _, new in new }
  }

  /// Departure areas, airspace position and altitude, and route endpoint parameters.
  private static func searchContext(_ tool: ToolDefinition) -> [String: Value] {
    switch tool {
    case .queryObstacles:
      [
        "departure_area": described(
          enumeration(["sector", "circle"]),
          "Area searched for an airport and runway: a sector along the runway course from the "
            + "departure end (default), or a circle around the departure end; radius_nm sets "
            + "its size.")
      ]
    case .queryAirspace:
      [
        "route": described(
          route, "Route as [longitude, latitude] pairs; finds airspace the route crosses or nears."),
        "altitude_ft": described(
          number, "MSL altitude in feet; excludes airspace whose vertical limits exclude it.")
      ]
    case .findRoutes:
      [
        "origin": described(text, "Departure airport, as a FAA LID or ICAO code."),
        "destination": described(text, "Arrival airport, as a FAA LID or ICAO code.")
      ]
    default: [:]
    }
  }

  private static func described(_ schema: Value, _ description: String) -> Value {
    var fields = schema.objectValue ?? [:]
    fields["description"] = .string(description)
    return .object(fields)
  }

  private static func periodic(_ tool: ToolDefinition) -> [String: Value] {
    var properties = position.merging(pagination) { _, new in new }
    properties.merge([
      "identifier": text, "record_id": text, "radius_nm": number,
      "airport": described(
        text,
        "Airport as a FAA LID or ICAO code. Routes match it as origin or destination; obstacle "
          + "searches use it with runway to locate a departure end."),
      "query": described(
        .object(["type": "string", "minLength": 3, "maxLength": 16384]),
        "Case-insensitive substring of the record identifier or name; at least 3 characters."),
      "order": described(
        enumeration(["identifier", "highest", "nearest"]),
        "Result order; defaults to highest for obstacles, nearest when coordinates or a route "
          + "are given, and identifier otherwise.")
    ]) { _, new in new }
    if tool == .findAirports {
      properties["minimum_runway_length_ft"] = number
      properties["public_use"] = .object(["type": "boolean"])
      properties["paved"] = .object(["type": "boolean"])
      properties["facility_type"] = enumeration(AirportFilters.facilityTypes)
    }
    if tool == .getAirway {
      properties["entry_fix"] = text
      properties["exit_fix"] = text
    }
    if [.findProcedures, .getProcedure].contains(tool) {
      properties["transition"] = text
      properties["runway"] = text
      properties["procedure_type"] = enumeration(["approach", "departure", "arrival"])
    }
    if tool == .queryObstacles {
      properties["runway"] = text
      properties["procedure_id"] = text
      properties["route"] = route
    }
    properties.merge(searchContext(tool)) { _, new in new }
    if tool.kinds.count > 1 {
      properties["kinds"] = .object([
        "type": "array", "items": enumeration(tool.kinds), "minItems": 1
      ])
    }
    return properties
  }

  private static func enumeration(_ values: [String]) -> Value {
    .object(["type": "string", "enum": .array(values.map(Value.string))])
  }
}

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
      properties = pagination.merging([
        "location": text, "start": date, "end": date,
        "scope": enumeration(["A", "E", "W"]), "runway": text, "procedure": text
      ]) { _, new in new }
      required = ["location", "start", "end"]
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

  private static func periodic(_ tool: ToolDefinition) -> [String: Value] {
    var properties = position.merging(pagination) { _, new in new }
    properties.merge([
      "identifier": text, "record_id": text, "query": text, "airport": text, "radius_nm": number,
      "order": enumeration(["identifier", "highest", "nearest"])
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
      properties["route"] = .object([
        "type": "array", "minItems": 2, "maxItems": 200,
        "items": .object(["type": "array", "minItems": 2, "maxItems": 2, "items": number])
      ])
    }
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

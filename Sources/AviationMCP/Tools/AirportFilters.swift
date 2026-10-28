import MCP
import SQLKit

enum AirportFilters {
  static let facilityTypes = [
    "AIRPORT", "BALLOONPORT", "SEAPLANE BASE", "GLIDERPORT", "HELIPORT", "ULTRALIGHT"
  ]

  static func predicate(_ arguments: ToolArguments) throws -> SQLQueryString {
    var query: SQLQueryString = ""
    if let publicUse = try arguments.boolean("public_use") {
      query += " AND (data->>'public_use')::boolean = \(bind: publicUse)"
    }
    if let type = try arguments.string("facility_type")?.uppercased() {
      guard facilityTypes.contains(type) else {
        throw MCPError.invalidParams("Unknown airport facility type")
      }
      query += " AND data->>'facility_type' = \(bind: type)"
    }
    let minimum = try arguments.number("minimum_runway_length_ft", range: 0...30_000)
    let paved = try arguments.boolean("paved")
    if minimum != nil || paved != nil {
      query +=
        " AND EXISTS (SELECT 1 FROM jsonb_array_elements(data->'runways') AS runway WHERE TRUE"
      if let minimum {
        query += " AND (runway->>'length_ft')::double precision >= \(bind: minimum)"
      }
      if let paved { query += " AND (runway->>'paved')::boolean = \(bind: paved)" }
      query += ")"
    }
    return query
  }
}

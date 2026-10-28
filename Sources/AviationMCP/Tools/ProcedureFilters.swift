import MCP
import SQLKit

enum ProcedureFilters {
  static func predicate(_ arguments: ToolArguments) throws -> SQLQueryString {
    var query: SQLQueryString = ""
    if let type = try arguments.string("procedure_type") {
      guard ["approach", "departure", "arrival"].contains(type) else {
        throw MCPError.invalidParams("Unknown procedure_type")
      }
      query += " AND data->>'procedure_type' = \(bind: type)"
    }
    if let transition = try arguments.string("transition")?.uppercased() {
      query +=
        " AND (data->>'transition' IS NULL OR upper(data->>'transition') = \(bind: transition))"
    }
    if let runway = try arguments.string("runway") {
      let canonical = RunwayName.canonical(runway)
      var names = [canonical, "RW" + canonical, "ALL", "RWALL"]
      if ["L", "C", "R"].contains(String(canonical.suffix(1))) {
        names += [canonical.dropLast() + "B", "RW" + canonical.dropLast() + "B"]
      }
      query += """
         AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(data->'runways') AS r(name)
           WHERE upper(r.name) IN (\(binds: names)))
        """
    }
    return query
  }
}

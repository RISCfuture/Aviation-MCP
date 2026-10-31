import Foundation
import MCP
import SQLKit

struct SpatialContext {
  var geometry: Value?
  var warnings: [String] = []
  var candidates: [Value] = []

  static func resolve(
    _ arguments: ToolArguments, on sql: any SQLDatabase, snapshot: SourceSnapshot
  ) async throws -> Self {
    let coordinate = try arguments.coordinate()
    let runway = try arguments.string("runway")
    guard try arguments.string("airport") == nil || runway != nil else {
      throw MCPError.invalidParams("An airport obstacle context requires a runway departure end")
    }
    let procedure = try arguments.string("procedure_id")
    let route = arguments.values["route"]
    guard
      [coordinate != nil, runway != nil, procedure != nil, route != nil].filter({ $0 }).count <= 1
    else {
      throw MCPError.invalidParams(
        "Choose one spatial context: coordinates, runway, route or procedure_id")
    }
    if let coordinate {
      return Self(
        geometry: Normalization.point(
          latitude: coordinate.latitude, longitude: coordinate.longitude))
    }
    if let route { return Self(geometry: try routeGeometry(route)) }
    if let runway {
      return try await departure(runway, arguments: arguments, on: sql, snapshot: snapshot)
    }
    if let procedure { return try await procedureGeometry(procedure, on: sql, snapshot: snapshot) }
    return Self()
  }

  private static func departure(
    _ runway: String, arguments: ToolArguments, on sql: any SQLDatabase, snapshot: SourceSnapshot
  ) async throws -> Self {
    guard let airport = try arguments.string("airport", required: true)?.uppercased(),
      let version = snapshot.versions[.nasr]
    else { throw StorageError.unavailable(.nasr, reason: snapshot.unavailability(of: .nasr)) }
    let rows = try await sql.raw(
      """
      SELECT id, identifier, name, data::text AS payload FROM aviation_records
      WHERE version_id = \(bind: version.id) AND kind = 'airport'
        AND (upper(identifier) = \(bind: airport) OR upper(data->>'faa_lid') = \(bind: airport)
          OR upper(id) = \(bind: airport))
      ORDER BY id LIMIT 200
      """
    ).all()
    guard !rows.isEmpty else {
      throw StorageError.invalidImport("The requested airport was not found.")
    }
    if rows.count > 1 {
      return Self(
        warnings: ["The airport identifier is ambiguous; select a candidate."],
        candidates: try rows.map {
          .object([
            "id": .string(try $0.decode(column: "id", as: String.self)),
            "identifier": .string(try $0.decode(column: "identifier", as: String.self)),
            "name": .string(try $0.decode(column: "name", as: String.self))
          ])
        })
    }
    let data = try payload(rows[0])
    let ends =
      data["runways"]?.arrayValue?.flatMap { $0.objectValue?["ends"]?.arrayValue ?? [] } ?? []
    guard
      let end = ends.first(where: {
        $0.objectValue?["identifier"]?.stringValue.map(RunwayName.canonical)
          == RunwayName.canonical(runway)
      }),
      let geometry = end.objectValue?["departure_end"], geometry != .null
    else {
      throw StorageError.invalidImport(
        "The requested runway departure end has no published position.")
    }
    return Self(geometry: geometry)
  }

  private static func procedureGeometry(
    _ identifier: String, on sql: any SQLDatabase, snapshot: SourceSnapshot
  ) async throws -> Self {
    let version = try snapshot.require(.cifp)
    guard
      let row = try await sql.raw(
        """
        SELECT data::text AS payload, ST_AsGeoJSON(geometry)::text AS geometry FROM aviation_records
        WHERE version_id = \(bind: version.id) AND kind = 'procedure' AND id = \(bind: identifier)
        """
      ).first(), let geometry = try row.decode(column: "geometry", as: String?.self)
    else {
      throw StorageError.invalidImport(
        "The procedure has no determinable geometry; select its exact id from find_procedures.")
    }
    let data = try payload(row)
    var warnings = [
      "Obstacle search covers determinable procedure segments only; "
        + "it does not assess obstacle clearance or chart minima."
    ]
    if let gaps = data["geometry_gaps"]?.arrayValue, !gaps.isEmpty {
      warnings.append(
        "\(gaps.count) unresolved procedure legs are excluded; consult the procedure geometry_gaps."
      )
    }
    warnings.append(
      "Missed approach legs require a separate analysis and are excluded from this search.")
    return Self(
      geometry: try JSONDecoder().decode(Value.self, from: Data(geometry.utf8)), warnings: warnings)
  }

  private static func routeGeometry(_ value: Value) throws -> Value {
    guard let coordinates = value.arrayValue, (2...200).contains(coordinates.count) else {
      throw MCPError.invalidParams("route requires 2 to 200 longitude/latitude pairs")
    }
    for coordinate in coordinates {
      guard let pair = coordinate.arrayValue, pair.count == 2 else {
        throw MCPError.invalidParams("route coordinates must be longitude/latitude pairs")
      }
      _ = try ToolArguments(["longitude": pair[0], "latitude": pair[1]]).coordinate()
    }
    return .object(["type": "LineString", "coordinates": value])
  }

  private static func payload(_ row: any SQLRow) throws -> [String: Value] {
    try JSONDecoder().decode(
      [String: Value].self, from: Data(row.decode(column: "payload", as: String.self).utf8))
  }
}

enum RunwayName {
  static func matches(_ published: String, requested: String) -> Bool {
    let published = canonical(published)
    let requested = canonical(requested)
    if published == "ALL" || published == requested { return true }
    return published.hasSuffix("B") && ["L", "C", "R"].contains(String(requested.suffix(1)))
      && published.dropLast() == requested.dropLast()
  }

  static func canonical(_ value: String) -> String {
    var value = value.uppercased()
    if value.hasPrefix("RW") { value.removeFirst(2) }
    if value.first?.isNumber == true, value.prefix(2).last?.isNumber != true { value = "0" + value }
    if value.count == 1, value.first?.isNumber == true { value = "0" + value }
    return value
  }
}

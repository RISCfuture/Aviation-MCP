import Fluent
import Foundation
import MCP
import SQLKit
import SwiftGeographic

struct GeometryTools: Sendable {
  let database: any Database

  static func convert(_ arguments: ToolArguments) throws -> ToolResult {
    let coordinate = try geographic(arguments)
    var result: [String: Value] = [
      "latitude": .double(coordinate.latitude),
      "longitude": .double(coordinate.longitude), "datum": "WGS84",
      "mgrs": .string(try coordinate.mgrs().description)
    ]
    if (-80..<84).contains(coordinate.latitude) {
      result["utm"] = .string(try coordinate.utm.description)
    } else {
      result["ups"] = .string(try coordinate.ups.description)
    }
    return ToolResult(results: [.object(result)])
  }

  func compute(_ arguments: ToolArguments) async throws -> ToolResult {
    try await database.transaction { transaction in
      let sql = try transaction.sqlDatabase()
      try await sql.raw("SET TRANSACTION READ ONLY").run()
      try await sql.raw("SET LOCAL statement_timeout = '10s'").run()
      let geometry = GeometryTools(database: transaction)
      switch try arguments.string("operation", required: true) {
      case "destination": return try await geometry.destination(arguments)
      case "route", "distance": return try await geometry.route(arguments)
      default: throw MCPError.invalidParams("Supported operations: destination, distance, route")
      }
    }
  }

  private func route(_ arguments: ToolArguments) async throws -> ToolResult {
    let coordinates = try Self.coordinates(arguments)
    let geoJSON = Value.object(["type": "LineString", "coordinates": .array(coordinates)])
    let json = String(data: try JSONEncoder().encode(geoJSON), encoding: .utf8)
    let sql = try database.sqlDatabase()
    guard
      let row = try await sql.raw(
        """
        WITH route AS (SELECT ST_SetSRID(ST_GeomFromGeoJSON(\(bind: json)),4326) AS line),
        segments AS (SELECT (ST_DumpSegments(ST_Segmentize(line::geography,10000)::geometry)).geom
        AS segment FROM route),
        display AS (SELECT ST_LineMerge(ST_Collect(CASE WHEN ST_XMax(segment) - ST_XMin(segment) > 180
          THEN ST_WrapX(ST_ShiftLongitude(segment),180,-360) ELSE segment END)) AS shape FROM segments)
        SELECT ST_Length(line::geography)/1852 AS distance_nm,
          degrees(ST_Azimuth(ST_StartPoint(line)::geography,ST_EndPoint(line)::geography)) AS bearing,
          ST_AsGeoJSON(shape) AS geometry FROM route, display
        """
      ).first()
    else { throw StorageError.requiresPostgreSQL }
    var value: [String: Value] = [
      "distance_nm": .double(try row.decode(column: "distance_nm", as: Double.self)),
      "datum": "WGS84"
    ]
    if let bearing = try row.decode(column: "bearing", as: Double?.self) {
      value["initial_bearing_true_deg_to_endpoint"] = .double(bearing)
    }
    let geometry = try row.decode(column: "geometry", as: String.self)
    var result = ToolResult(results: [])
    if geometry.utf8.count <= 131_072 {
      value["geometry"] = try JSONDecoder().decode(Value.self, from: Data(geometry.utf8))
    } else {
      result.completeness = "partial"
      result.warnings = ["Route geometry exceeds the payload limit; distance remains available."]
    }
    result.results = [.object(value)]
    return result
  }

  private func destination(_ arguments: ToolArguments) async throws -> ToolResult {
    guard let point = try arguments.coordinate(),
      let course = try arguments.number("course_true_deg", range: 0...360),
      let distance = try arguments.number("distance_nm", range: 0...20_000)
    else {
      throw MCPError.invalidParams("Coordinates, true course and distance are required")
    }
    let sql = try database.sqlDatabase()
    guard
      let row = try await sql.raw(
        """
        SELECT ST_Y(point) AS latitude, ST_X(point) AS longitude FROM (
          SELECT ST_Project(ST_SetSRID(ST_MakePoint(\(bind: point.longitude),\(bind: point.latitude)),4326)::geography,
            \(bind: distance * 1852), radians(\(bind: course)))::geometry AS point) AS projected
        """
      ).first()
    else { throw StorageError.requiresPostgreSQL }
    return ToolResult(results: [
      .object([
        "latitude": .double(try row.decode(column: "latitude", as: Double.self)),
        "longitude": .double(try row.decode(column: "longitude", as: Double.self)), "datum": "WGS84"
      ])
    ])
  }

  private static func coordinates(_ arguments: ToolArguments) throws -> [Value] {
    guard let points = arguments.values["coordinates"]?.arrayValue, (2...200).contains(points.count)
    else {
      throw MCPError.invalidParams("A route requires 2–200 [longitude, latitude] pairs")
    }
    for point in points {
      guard let pair = point.arrayValue, pair.count == 2 else {
        throw MCPError.invalidParams("Coordinates must be [longitude, latitude] pairs")
      }
      _ = try ToolArguments(["longitude": pair[0], "latitude": pair[1]]).coordinate()
    }
    return points
  }

  private static func geographic(_ arguments: ToolArguments) throws -> GeographicCoordinate {
    if let point = try arguments.coordinate() {
      return try GeographicCoordinate(latitude: point.latitude, longitude: point.longitude)
    }
    guard let text = try arguments.string("coordinate", required: true) else {
      throw MCPError.invalidParams("Coordinates are required")
    }
    switch try arguments.string("format", required: true)?.lowercased() {
    case "mgrs": return try MGRSCoordinate(string: text).geographic
    case "utm":
      guard let utm = UTMCoordinate(text) else {
        throw MCPError.invalidParams("Invalid UTM coordinate")
      }
      return try utm.geographic
    case "ups":
      guard let ups = UPSCoordinate(text) else {
        throw MCPError.invalidParams("Invalid UPS coordinate")
      }
      return try ups.geographic
    default:
      throw MCPError.invalidParams("Supported input formats: mgrs, utm, ups, or latitude/longitude")
    }
  }
}

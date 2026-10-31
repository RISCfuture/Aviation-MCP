import Fluent
import Foundation
import MCP
import SQLKit

struct PeriodicQueries: Sendable {
  let store: AviationStore

  func search(kinds: [String], sources: [SourceName], arguments: ToolArguments) async throws
    -> ToolResult
  {
    let limit = try arguments.limit()
    let includeGeometry = try arguments.boolean("include_geometry") ?? false
    let cursor = try arguments.string("cursor").map(QueryCursor.decode)
    let signature = try QueryCursor.signature(arguments.values)
    return try await store.withSnapshot { sql, snapshot in
      if let cursor, cursor.versionToken != snapshot.token || cursor.query != signature {
        throw StorageError.expiredCursor
      }
      let versions = try sources.map(snapshot.require)
      let context = try await SpatialContext.resolve(
        Self.spatialArguments(arguments, kinds: kinds), on: sql, snapshot: snapshot)
      if !context.candidates.isEmpty {
        return ToolResult(
          results: context.candidates, sources: versions.map(SourceStamp.init),
          completeness: "partial", warnings: context.warnings)
      }
      let airports = try await AirportReferences.resolve(
        arguments, kinds: kinds, on: sql, snapshot: snapshot)
      let warnings = try Self.coverage(
        versions: versions, kinds: kinds,
        spatial: context.geometry != nil)
      var query = try Self.query(
        kinds: kinds, versionIDs: versions.map(\.id), arguments: arguments, context: context,
        airports: airports)
      query += " LIMIT \(bind: limit + 1) OFFSET \(bind: cursor?.offset ?? 0)"
      let rows = try await sql.raw(query).all()
      var result = ToolResult(
        results: try rows.prefix(limit).map {
          try Self.present($0, includeGeometry: includeGeometry)
        },
        sources: versions.map(SourceStamp.init))
      result.warnings = warnings + context.warnings
      if rows.isEmpty { result.warnings += airports.emptyResultWarnings }
      if arguments.values["altitude_ft"] != nil {
        result.warnings.append(AirspaceAltitude.limitation)
      }
      Self.annotate(&result)
      if rows.count > limit {
        result.nextCursor = try QueryCursor(
          versionToken: snapshot.token, query: signature, offset: (cursor?.offset ?? 0) + limit
        ).encode()
      }
      return result
    }
  }

  /// Obstacle searches take every spatial context; other records take only coordinates or a
  /// route, since their `airport` argument filters instead of locating.
  private static func spatialArguments(_ arguments: ToolArguments, kinds: [String])
    -> ToolArguments
  {
    guard !kinds.contains("obstacle") else { return arguments }
    return ToolArguments(
      arguments.values.filter { ["latitude", "longitude", "route"].contains($0.key) })
  }

  private static func annotate(_ result: inout ToolResult) {
    if result.results.contains(where: { $0.objectValue?["source_warnings"] != nil }) {
      result.warnings.append(
        "Some records contain unrepresentable source fields; consult their source_warnings.")
    }
    if result.results.contains(where: { $0.objectValue?["geometry_omitted"] == true }) {
      result.warnings.append(
        "Some geometry exceeds the per-record payload limit and was omitted.")
    }
    if result.results.contains(where: { value in
      ["geometry_gaps", "geometry_gap_sequences", "missed_approach_geometry_gaps"].contains {
        !(value.objectValue?[$0]?.arrayValue ?? []).isEmpty
      }
    }) {
      result.warnings.append(
        "Some records have unresolved geometry; consult their geometry gap fields.")
    }
    let limitations = result.results.flatMap {
      $0.objectValue?["geometry_limitations"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
    result.warnings += Set(limitations).sorted()
    if !result.warnings.isEmpty { result.completeness = "partial" }
  }

  private static func coverage(
    versions: [SourceVersion], kinds: [String], spatial: Bool
  ) throws -> [String] {
    var warnings = versions.flatMap { $0.omissionWarnings(for: kinds) }
    var covered = 0
    for kind in kinds {
      let total = versions.reduce(0) {
        $0 + ($1.validation?["record_counts"]?.objectValue?[kind]?.intValue ?? 0)
      }
      guard total > 0 else {
        warnings.append("The published source does not cover \(kind).")
        continue
      }
      guard spatial else {
        covered += 1
        continue
      }
      warnings += versions.flatMap {
        $0.validation?["spatial_limitations"]?.objectValue?[kind]?.arrayValue?
          .compactMap(\.stringValue) ?? []
      }
      let count = versions.reduce(0) {
        $0 + ($1.validation?["spatial_counts"]?.objectValue?[kind]?.intValue ?? 0)
      }
      guard count > 0 else {
        warnings.append("Spatial coverage is unavailable for \(kind).")
        continue
      }
      covered += 1
      if count < total {
        warnings.append(
          "Some \(kind) records have unresolved geometry and cannot be spatially matched.")
      }
    }
    guard covered > 0 else {
      throw StorageError.invalidImport(warnings.joined(separator: " "))
    }
    return warnings
  }

  private static func query(
    kinds: [String], versionIDs: [UUID], arguments: ToolArguments, context: SpatialContext,
    airports: AirportReferences
  ) throws -> SQLQueryString {
    let altitude = try arguments.number("altitude_ft", range: -2_000...100_000).map(
      AirspaceAltitude.match)
    var query: SQLQueryString = """
      SELECT id, kind, identifier, name, airport, sequence,
        elevation_msl_ft, height_agl_ft, data::text AS payload,
        ST_AsGeoJSON(geometry)::text AS geometry
      """
    query += try context.measurementColumns()
    if let altitude { query += ", \(altitude) AS altitude_match" }
    query += """
       FROM aviation_records WHERE version_id IN (\(binds: versionIDs))
        AND kind IN (\(binds: kinds))
      """
    query += try filters(arguments, kinds: kinds)
    query += airports.predicate
    query += try context.filter(
      radiusNM: arguments.number("radius_nm", default: 5, range: 0.01...500) ?? 5)
    if let altitude { query += " AND \(altitude) <> 'outside'" }
    query += try ordering(order(arguments, kinds: kinds, context: context), context: context)
    return query
  }

  private static func filters(_ arguments: ToolArguments, kinds: [String])
    throws -> SQLQueryString
  {
    var query: SQLQueryString = ""
    if let identifier = try arguments.string("identifier")?.uppercased() {
      query +=
        " AND (upper(identifier) = \(bind: identifier) OR upper(data->>'faa_lid') = \(bind: identifier))"
    }
    if let id = try arguments.string("record_id") { query += " AND id = \(bind: id)" }
    if let text = try arguments.string("query") {
      query += try SearchIndexes.predicate(matching: text)
    }
    if kinds.contains("airport") { query += try AirportFilters.predicate(arguments) }
    if kinds.contains("procedure") { query += try ProcedureFilters.predicate(arguments) }
    return query
  }

  /// The requested ordering; by default the highest obstacles, otherwise the nearest records to
  /// a spatial context, otherwise identifiers.
  private static func order(_ arguments: ToolArguments, kinds: [String], context: SpatialContext)
    throws -> String
  {
    let order =
      try arguments.string("order")
      ?? (kinds.contains("obstacle")
        ? "highest" : context.geometry != nil ? "nearest" : "identifier")
    guard ["identifier", "highest", "nearest"].contains(order) else {
      throw MCPError.invalidParams("Unsupported ordering")
    }
    guard order != "nearest" || context.geometry != nil else {
      throw MCPError.invalidParams("Nearest ordering requires coordinates")
    }
    return order
  }

  /// The ORDER BY clause; identifier ordering follows the `aviation_identifier` index so that a
  /// broad text match can stop scanning once a page is filled.
  private static func ordering(_ order: String, context: SpatialContext) throws -> SQLQueryString {
    if order == "highest" {
      return " ORDER BY elevation_msl_ft DESC NULLS LAST, id, kind, version_id"
    }
    if order == "nearest", let nearest = try context.nearestOrdering() { return nearest }
    return " ORDER BY upper(identifier), sequence NULLS LAST, id, kind, version_id"
  }

  private static let lineGeometryFields = [
    "missed_approach_geometry", "geometry_gaps", "missed_approach_geometry_gaps",
    "geometry_gap_sequences", "geometry_scope", "geometry_limitations"
  ]

  private static func present(_ row: any SQLRow, includeGeometry: Bool) throws -> Value {
    let payload = try row.decode(column: "payload", as: String.self)
    var object = try JSONDecoder().decode([String: Value].self, from: Data(payload.utf8))
    object["id"] = .string(try row.decode(column: "id", as: String.self))
    object["record_kind"] = .string(try row.decode(column: "kind", as: String.self))
    object["identifier"] = .string(try row.decode(column: "identifier", as: String.self))
    object["name"] = .string(try row.decode(column: "name", as: String.self))
    if let msl = try row.decode(column: "elevation_msl_ft", as: Double?.self) {
      object["elevation_msl_ft"] = .double(msl)
    }
    if let agl = try row.decode(column: "height_agl_ft", as: Double?.self) {
      object["height_agl_ft"] = .double(agl)
    }
    object.merge(try SpatialContext.measurements(in: row)) { _, new in new }
    if row.contains(column: "altitude_match") {
      object["altitude_match"] = .string(try row.decode(column: "altitude_match", as: String.self))
    }
    let geometry = try row.decode(column: "geometry", as: String?.self)
    guard includeGeometry || geometry.map(isPoint) == true else {
      for field in lineGeometryFields { object.removeValue(forKey: field) }
      return .object(object)
    }
    if let geometry {
      if geometry.utf8.count <= 32_768 {
        object["geometry"] = try JSONDecoder().decode(Value.self, from: Data(geometry.utf8))
      } else {
        object["geometry_omitted"] = true
      }
    }
    return .object(object)
  }

  private static func isPoint(_ geoJSON: String) -> Bool {
    geoJSON.hasPrefix(#"{"type":"Point""#)
  }
}

struct QueryCursor: Codable {
  let versionToken: String
  let query: String
  let offset: Int

  static func signature(_ arguments: [String: Value]) throws -> String {
    var arguments = arguments
    arguments.removeValue(forKey: "cursor")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(arguments).base64EncodedString()
  }

  static func decode(_ text: String) throws -> Self {
    guard let data = Data(base64Encoded: text) else { throw StorageError.expiredCursor }
    do {
      let cursor = try JSONDecoder().decode(Self.self, from: data)
      guard (0...2_000_000).contains(cursor.offset) else { throw StorageError.expiredCursor }
      return cursor
    } catch {
      throw StorageError.expiredCursor
    }
  }

  func encode() throws -> String {
    try JSONEncoder().encode(self).base64EncodedString()
  }
}

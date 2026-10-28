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
    let cursor = try arguments.string("cursor").map(QueryCursor.decode)
    let signature = try QueryCursor.signature(arguments.values)
    return try await store.withSnapshot { sql, snapshot in
      if let cursor, cursor.versionToken != snapshot.token || cursor.query != signature {
        throw StorageError.expiredCursor
      }
      let versions = try sources.map { source in
        guard let version = snapshot.versions[source] else {
          throw StorageError.unavailable(source)
        }
        return version
      }
      let spatialArguments =
        kinds.contains("obstacle")
        ? arguments
        : ToolArguments(
          arguments.values.filter { ["latitude", "longitude"].contains($0.key) })
      let context = try await SpatialContext.resolve(spatialArguments, on: sql, snapshot: snapshot)
      if !context.candidates.isEmpty {
        return ToolResult(
          results: context.candidates, sources: versions.map(SourceStamp.init),
          completeness: "partial", warnings: context.warnings)
      }
      let versionIDs = versions.map(\.id)
      let warnings = try Self.coverage(
        versions: versions, kinds: kinds,
        spatial: context.geometry != nil)
      var query = try Self.query(
        kinds: kinds, versionIDs: versionIDs, arguments: arguments, geometry: context.geometry)
      query += " LIMIT \(bind: limit + 1) OFFSET \(bind: cursor?.offset ?? 0)"
      let rows = try await sql.raw(query).all()
      var result = ToolResult(
        results: try rows.prefix(limit).map(Self.present), sources: versions.map(SourceStamp.init))
      result.warnings = warnings + context.warnings
      Self.annotate(&result)
      if rows.count > limit {
        result.nextCursor = try QueryCursor(
          versionToken: snapshot.token, query: signature, offset: (cursor?.offset ?? 0) + limit
        ).encode()
      }
      return result
    }
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
    var warnings: [String] = []
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
    kinds: [String], versionIDs: [UUID], arguments: ToolArguments, geometry: Value?
  ) throws
    -> SQLQueryString
  {
    let identifier = try arguments.string("identifier")?.uppercased()
    let airport = try arguments.string("airport")?.uppercased()
    let text = try arguments.string("query")
    let radius = try arguments.number("radius_nm", default: 5, range: 0.01...500) ?? 5
    let order = try arguments.string("order") ?? "identifier"
    guard ["identifier", "highest", "nearest"].contains(order) else {
      throw MCPError.invalidParams("Unsupported ordering")
    }
    guard order != "nearest" || geometry != nil else {
      throw MCPError.invalidParams("Nearest ordering requires coordinates")
    }
    var query: SQLQueryString = """
      SELECT id, kind, identifier, name, airport, sequence,
        elevation_msl_ft, height_agl_ft, data::text AS payload,
        ST_AsGeoJSON(geometry)::text AS geometry
      FROM aviation_records WHERE version_id IN (\(binds: versionIDs))
        AND kind IN (\(binds: kinds))
      """
    if let identifier {
      query +=
        " AND (upper(identifier) = \(bind: identifier) OR upper(data->>'faa_lid') = \(bind: identifier))"
    }
    if let id = try arguments.string("record_id") { query += " AND id = \(bind: id)" }
    if let airport, !kinds.contains("obstacle") {
      query += " AND upper(airport) = \(bind: airport)"
    }
    if let text {
      query +=
        " AND (name ILIKE \(bind: "%" + text + "%") OR identifier ILIKE \(bind: "%" + text + "%"))"
    }
    if kinds.contains("airport") { query += try AirportFilters.predicate(arguments) }
    if kinds.contains("procedure") { query += try ProcedureFilters.predicate(arguments) }
    if let geometry {
      let json = try Normalization.jsonText(geometry)
      query +=
        " AND ST_DWithin(geometry, ST_GeomFromGeoJSON(\(bind: json))::geography, \(bind: radius * 1852))"
    }
    query += try ordering(order, geometry: geometry)
    return query
  }

  private static func ordering(_ order: String, geometry: Value?) throws -> SQLQueryString {
    if order == "highest" {
      return " ORDER BY elevation_msl_ft DESC NULLS LAST, id, kind, version_id"
    }
    if order == "nearest", let geometry {
      let json = try Normalization.jsonText(geometry)
      return
        " ORDER BY ST_Distance(geometry, ST_GeomFromGeoJSON(\(bind: json))::geography), id, kind, version_id"
    }
    return " ORDER BY identifier, sequence NULLS LAST, id, kind, version_id"
  }

  private static func present(_ row: any SQLRow) throws -> Value {
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
    if let geometry = try row.decode(column: "geometry", as: String?.self) {
      if geometry.utf8.count <= 32_768 {
        object["geometry"] = try JSONDecoder().decode(Value.self, from: Data(geometry.utf8))
      } else {
        object["geometry_omitted"] = true
      }
    }
    return .object(object)
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

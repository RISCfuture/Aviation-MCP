import Foundation
import MCP
import SQLKit

/// Resolves a route string against one snapshot of the published NASR and CIFP data.
struct RouteResolver: Sendable {
  static let routeLengthLimit = 1024
  /// The most route points query_airspace and query_obstacles accept.
  static let pathPointLimit = 200
  private static let geometryLimit = 131_072
  private static let navigationKinds = ["airport", "fix", "navaid", "airway"]

  let store: AviationStore

  func resolve(_ arguments: ToolArguments) async throws -> ToolResult {
    let text = try arguments.string("route_string", required: true) ?? ""
    guard text.utf8.count <= Self.routeLengthLimit else {
      throw ToolInputError(
        reason: "route_string is longer than \(Self.routeLengthLimit) characters.")
    }
    let words = try RouteGrammar.parse(text)
    let selections = try Self.selections(arguments)
    let departureRunway = try arguments.string("departure_runway")
    let arrivalRunway = try arguments.string("arrival_runway")
    let includeGeometry = try arguments.boolean("include_geometry") ?? false
    return try await store.withSnapshot { sql, snapshot in
      let nasr = try snapshot.require(.nasr)
      var assembly = try RouteAssembly(
        words: words,
        navigation: try await Self.navigation(Self.names(words), version: nasr, on: sql),
        selections: selections, departureRunway: departureRunway, arrivalRunway: arrivalRunway)
      let requests = assembly.procedureRequests
      let cifp = snapshot.versions[.cifp]
      if let cifp, !requests.isEmpty {
        let procedures = try await Self.procedures(requests, version: cifp, on: sql)
        assembly.departures = procedures.filter { $0.data["procedure_type"] == "departure" }
        assembly.arrivals = procedures.filter { $0.data["procedure_type"] == "arrival" }
      } else if !requests.isEmpty {
        assembly.procedureUnavailability =
          snapshot.unavailability(of: .cifp) ?? "No effective CIFP cycle is published."
      }
      try assembly.assemble()
      let measures = try await Self.measure(assembly.runs, on: sql)
      var record = Self.record(words: words, assembly: assembly, measures: measures)
      var versions = [nasr]
      var warnings = assembly.warnings + nasr.omissionWarnings(for: Self.navigationKinds)
      if let cifp, assembly.usedProcedures {
        versions.append(cifp)
        warnings += cifp.omissionWarnings(for: ["procedure"])
      }
      if !assembly.gaps.isEmpty {
        warnings.append(
          "The route has \(assembly.gaps.count) geometry gap(s); the path is split there. "
            + "Consult geometry_gaps.")
      }
      if includeGeometry {
        if let geometry = try await Self.displayGeometry(assembly.runs, on: sql) {
          record["geometry"] = geometry
        } else if assembly.runs.contains(where: { $0.count > 1 }) {
          warnings.append("Route geometry exceeds the payload limit; paths remain available.")
        }
      }
      var result = ToolResult(results: [.object(record)], sources: versions.map(SourceStamp.init))
      result.completeness = warnings.isEmpty ? "complete" : "partial"
      result.warnings = warnings
      // A long path is complete; it only has to be split before another tool takes it.
      if assembly.runs.contains(where: { $0.count > Self.pathPointLimit }) {
        result.warnings.append(
          "A path has more than \(Self.pathPointLimit) points, the most query_airspace and "
            + "query_obstacles accept; split it by leg using path_index and start_point_index.")
      }
      return result
    }
  }

  // MARK: Arguments

  private static func selections(_ arguments: ToolArguments) throws -> [Int: String] {
    guard let raw = arguments.values["selections"] else { return [:] }
    guard let entries = raw.arrayValue, entries.count <= RouteGrammar.maximumElements else {
      throw MCPError.invalidParams("selections must be a bounded array")
    }
    var selections: [Int: String] = [:]
    for entry in entries {
      guard let fields = entry.objectValue, let index = fields["index"]?.intValue,
        let id = fields["record_id"]?.stringValue, !id.isEmpty, fields.count == 2
      else {
        throw MCPError.invalidParams("Each selection requires only an index and a record_id")
      }
      guard selections.updateValue(id, forKey: index) == nil else {
        throw MCPError.invalidParams("selections names element \(index) more than once")
      }
    }
    return selections
  }

  /// Every identifier the route could look up in NASR.
  private static func names(_ words: [RouteWord]) -> [String] {
    let names = words.compactMap { word -> String? in
      switch word.token {
      case .name(let name): name
      case .placeBearingDistance(let place, _, _): place
      default: nil
      }
    }
    return Set(names).sorted()
  }

  // MARK: Lookups

  private static func navigation(
    _ names: [String], version: SourceVersion, on sql: any SQLDatabase
  ) async throws -> [RouteRecord] {
    guard !names.isEmpty else { return [] }
    return try await sql.raw(
      """
      SELECT id, kind, identifier, name, data::text AS payload,
        CASE WHEN kind <> 'airway' THEN ST_AsGeoJSON(geometry)::text END AS geometry
      FROM aviation_records WHERE version_id = \(bind: version.id)
        AND ((kind IN (\(binds: navigationKinds)) AND upper(identifier) IN (\(binds: names)))
          OR (kind = 'airport' AND upper(data->>'faa_lid') IN (\(binds: names))))
      ORDER BY kind, id
      """
    ).all().map(routeRecord)
  }

  private static func procedures(
    _ requests: [RouteAssembly.ProcedureRequest], version: SourceVersion, on sql: any SQLDatabase
  ) async throws -> [RouteRecord] {
    var conditions: SQLQueryString = ""
    for (offset, request) in requests.enumerated() {
      if offset > 0 { conditions += " OR " }
      conditions += """
        (upper(airport) IN (\(binds: request.airportCodes))
          AND upper(identifier) = \(bind: request.identifier)
          AND data->>'procedure_type' = \(bind: request.type))
        """
    }
    var query: SQLQueryString = """
      SELECT id, kind, identifier, name, data::text AS payload, NULL::text AS geometry
      FROM aviation_records WHERE version_id = \(bind: version.id) AND kind = 'procedure' AND (
      """
    query += conditions
    query += ") ORDER BY id"
    return try await sql.raw(query).all().map(routeRecord)
  }

  private static func routeRecord(_ row: any SQLRow) throws -> RouteRecord {
    let payload = try row.decode(column: "payload", as: String.self)
    let geometry = try row.decode(column: "geometry", as: String?.self)
    return RouteRecord(
      id: try row.decode(column: "id", as: String.self),
      kind: try row.decode(column: "kind", as: String.self),
      identifier: try row.decode(column: "identifier", as: String.self),
      name: try row.decode(column: "name", as: String.self),
      data: try JSONDecoder().decode([String: Value].self, from: Data(payload.utf8)),
      position: try geometry.flatMap {
        GeoPoint(geoJSON: try JSONDecoder().decode(Value.self, from: Data($0.utf8)))
      })
  }

  // MARK: Measurement

  private struct LegMeasure: Decodable {
    let distance: Double
    let course: Double?
  }

  /// The geodesic length and initial true course of every leg, in run and point order.
  private static func measure(
    _ runs: [[RoutePoint]], on sql: any SQLDatabase
  ) async throws -> [LegMeasure] {
    var legs: [Value] = []
    for run in runs {
      for (start, end) in zip(run, run.dropFirst()) {
        legs.append(
          .object([
            "ord": .int(legs.count), "x1": .double(start.position.longitude),
            "y1": .double(start.position.latitude), "x2": .double(end.position.longitude),
            "y2": .double(end.position.latitude)
          ]))
      }
    }
    guard !legs.isEmpty else { return [] }
    let measures = try await sql.raw(
      """
      SELECT ST_Distance(a, b) / 1852 AS distance, degrees(ST_Azimuth(a, b)) AS course
      FROM (
        SELECT ord, ST_SetSRID(ST_MakePoint(x1, y1), 4326)::geography AS a,
          ST_SetSRID(ST_MakePoint(x2, y2), 4326)::geography AS b
        FROM jsonb_to_recordset(\(bind: try Normalization.jsonText(.array(legs)))::jsonb) AS leg(
          ord integer, x1 double precision, y1 double precision,
          x2 double precision, y2 double precision)
      ) AS legs ORDER BY ord
      """
    ).all(decoding: LegMeasure.self)
    guard measures.count == legs.count else { throw StorageError.requiresPostgreSQL }
    return measures
  }

  /// The runs densified to 10 km geodesic segments and split at the antimeridian, or `nil`
  /// when there is no line to draw or it exceeds the payload limit.
  private static func displayGeometry(
    _ runs: [[RoutePoint]], on sql: any SQLDatabase
  ) async throws -> Value? {
    let lines = runs.filter { $0.count > 1 }.map { Value.array($0.map(\.position.position)) }
    guard !lines.isEmpty else { return nil }
    let source = try Normalization.jsonText(
      .object(["type": "MultiLineString", "coordinates": .array(lines)]))
    let geometry = try await sql.raw(
      """
      WITH route AS (SELECT ST_SetSRID(ST_GeomFromGeoJSON(\(bind: source)), 4326) AS line),
      segments AS (
        SELECT (ST_DumpSegments(ST_Segmentize(line::geography, 10000)::geometry)).geom AS segment
        FROM route),
      display AS (
        SELECT ST_LineMerge(ST_Collect(CASE WHEN ST_XMax(segment) - ST_XMin(segment) > 180
          THEN ST_WrapX(ST_ShiftLongitude(segment), 180, -360) ELSE segment END)) AS shape
        FROM segments)
      SELECT ST_AsGeoJSON(shape) AS geometry FROM display
      """
    ).first(decodingColumn: "geometry", as: String.self)
    guard let geometry, geometry.utf8.count <= geometryLimit else { return nil }
    return try JSONDecoder().decode(Value.self, from: Data(geometry.utf8))
  }

  // MARK: Result

  private static func record(
    words: [RouteWord], assembly: RouteAssembly, measures: [LegMeasure]
  ) -> [String: Value] {
    var legs: [Value] = []
    var total = 0.0
    for (pathIndex, run) in assembly.runs.enumerated() {
      for (start, (from, to)) in zip(run, run.dropFirst()).enumerated() {
        let measure = measures[legs.count]
        total += measure.distance
        var leg: [String: Value] = [
          "sequence": .int(legs.count + 1), "via": .string(to.via),
          "via_kind": .string(to.viaKind), "from": .string(from.identifier),
          "to": .string(to.identifier), "distance_nm": rounded(measure.distance, places: 2),
          "path_index": .int(pathIndex), "start_point_index": .int(start)
        ]
        leg["initial_course_true_deg"] = measure.course.map { rounded($0, places: 1) }
        legs.append(.object(leg.merging(to.published) { current, _ in current }))
      }
    }
    return [
      "route_string": .string(words.map(\.text).joined(separator: " ")),
      "elements": .array(assembly.elements.map(Value.object)), "legs": .array(legs),
      "paths": .array(assembly.runs.map { .array($0.map(\.position.position)) }),
      "total_distance_nm": rounded(total, places: 2),
      "distance_complete": .bool(!assembly.isBroken),
      "geometry_gaps": .array(assembly.gaps),
      "ignored": .array(
        assembly.elements.filter { $0["kind"] == "speed_level" }.map(Value.object))
    ]
  }

  private static func rounded(_ value: Double, places: Int) -> Value {
    let scale = pow(10, Double(places))
    return .double((value * scale).rounded() / scale)
  }
}

import Fluent
import Foundation
import MCP
import SQLKit

struct NOTAMQueries: Sendable {
  let database: any Database
  var freshness: TimeInterval = 900

  func search(_ arguments: ToolArguments, area: NOTAMArea) async throws -> ToolResult {
    let filter = try NOTAMFilter(arguments, area: area)
    return try await database.withSQLTransaction { database in
      let sql = try database.sqlDatabase()
      try await sql.raw("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY").run()
      try await sql.raw("SET LOCAL statement_timeout = '10s'").run()
      let poll = try await sql.raw("SELECT value FROM ingestion_state WHERE key = 'last_poll_time'")
        .first(decodingColumn: "value", as: String.self)
      let generation =
        try await sql.raw(filter.generation)
        .first(decodingColumn: "token", as: String.self) ?? "empty"
      let token = (poll ?? "unknown") + generation
      if let cursor = filter.cursor,
        cursor.versionToken != token || cursor.query != filter.signature
      {
        throw StorageError.expiredCursor
      }
      let rows = try await sql.raw(filter.query).all()
      let now = try await sql.clock()
      var result = ToolResult(results: try rows.prefix(filter.limit).map { try filter.present($0) })
      result.liveSources = [
        LiveSourceStamp(
          provider: "notams", retrievedAt: now.ISO8601Format(),
          observationTime: poll, validFrom: filter.start.ISO8601Format(),
          validUntil: filter.end.ISO8601Format())
      ]
      annotate(&result, filter: filter, poll: poll, now: now)
      if rows.count > filter.limit {
        result.nextCursor = try QueryCursor(
          versionToken: token, query: filter.signature,
          offset: (filter.cursor?.offset ?? 0) + filter.limit
        ).encode()
      }
      return result
    }
  }

  private func annotate(_ result: inout ToolResult, filter: NOTAMFilter, poll: String?, now: Date) {
    if poll.flatMap(ISO8601Timestamp.parse).map({
      now.timeIntervalSince($0) <= freshness
    }) != true {
      result.warnings.append(
        "NOTAM ingestion freshness is unavailable or older than the configured freshness interval."
      )
    }
    result.warnings += filter.area.warnings
    if !filter.context.isEmpty {
      result.warnings.append(
        "NOTAMs whose text matches the runway or procedure are listed first; the rest remain "
          + "included because text matching cannot rule them out.")
    }
    if result.results.contains(where: { $0.objectValue?["scope_match"] == "uncertain" }) {
      result.warnings.append(
        "Some NOTAMs have no published scope; their scope matches are uncertain.")
    }
    if result.results.contains(where: { $0.objectValue?["schedule"] != nil }) {
      result.warnings.append(
        "Published schedules are preserved but not interpreted; time-window matches may be conditional."
      )
    }
    if !result.warnings.isEmpty { result.completeness = "partial" }
  }

  func verifyReadOnlyRole() async throws {
    let sql = try database.sqlDatabase()
    let writable = try await sql.raw(
      """
      SELECT has_table_privilege(current_user,'notams','INSERT,UPDATE,DELETE,TRUNCATE')
        OR has_table_privilege(current_user,'ingestion_state','INSERT,UPDATE,DELETE,TRUNCATE') AS writable
      """
    ).first(decodingColumn: "writable", as: Bool.self)
    guard writable == false else {
      throw StorageError.invalidImport("NOTAM connections must use a read-only database role.")
    }
  }
}

private struct NOTAMFilter: Sendable {
  private static let earthRadiusNM = 3440.065
  private static let qLineCoordinates = "^[0-9]{4}[NS][0-9]{5}[EW]"

  let area: NOTAMArea
  let start: Date
  let end: Date
  let scope: String?
  /// Case-insensitive patterns that NOTAM text must all match to be a context match.
  let context: [String]
  let limit: Int
  let cursor: QueryCursor?
  let signature: String

  var query: SQLQueryString {
    var query: SQLQueryString = """
      SELECT notam_id, icao_location, effective_start, effective_end, schedule, notam_text, scope,
        q_line::text AS q_line, updated_at
      """
    if let contextMatch { query += ", \(contextMatch) AS context_match" }
    if let centerDistance { query += ", \(centerDistance) AS center_distance_nm" }
    query += predicate
    query += " ORDER BY "
    if let contextMatch { query += "\(contextMatch) DESC, " }
    if !area.locations.isEmpty, centerDistance != nil {
      query += "icao_location IN (\(binds: area.locations)) DESC, "
    }
    query += "notam_id LIMIT \(bind: limit + 1) OFFSET \(bind: cursor?.offset ?? 0)"
    return query
  }

  var generation: SQLQueryString {
    var query: SQLQueryString = "SELECT concat(count(*),':',max(updated_at)) AS token"
    query += predicate
    return query
  }

  private var predicate: SQLQueryString {
    var query: SQLQueryString = """
       FROM notams WHERE \(locationMatch) AND effective_start < \(bind: end)
        AND (effective_end IS NULL OR effective_end > \(bind: start))
      """
    if let scope {
      query += " AND (scope IS NULL OR btrim(scope) = '' OR scope LIKE \(bind: "%" + scope + "%"))"
    }
    return query
  }

  private var locationMatch: SQLQueryString {
    var arms: [SQLQueryString] = []
    if !area.locations.isEmpty { arms.append("icao_location IN (\(binds: area.locations))") }
    if let centerDistance {
      arms.append(
        "(icao_location IN (\(binds: area.centers)) AND \(centerDistance) <= \(bind: area.radiusNM))"
      )
    }
    return Self.joined(arms, by: " OR ") ?? "FALSE"
  }

  private var contextMatch: SQLQueryString? {
    Self.joined(
      context.map { pattern in "notam_text ~* \(bind: pattern)" }, by: " AND ")
  }

  /// Great-circle distance from the area reference to an overlying-ARTCC NOTAM's Q-line center.
  private var centerDistance: SQLQueryString? {
    guard !area.centers.isEmpty, let reference = area.reference else { return nil }
    let coordinates: SQLQueryString = "(q_line->>'coordinates')"
    let latitude: SQLQueryString = """
      ((substr(\(coordinates), 1, 2)::double precision
        + substr(\(coordinates), 3, 2)::double precision / 60)
        * CASE substr(\(coordinates), 5, 1) WHEN 'S' THEN -1 ELSE 1 END)
      """
    let longitude: SQLQueryString = """
      ((substr(\(coordinates), 6, 3)::double precision
        + substr(\(coordinates), 9, 2)::double precision / 60)
        * CASE substr(\(coordinates), 11, 1) WHEN 'W' THEN -1 ELSE 1 END)
      """
    return """
      (CASE WHEN icao_location IN (\(binds: area.centers))
          AND \(coordinates) ~ \(bind: Self.qLineCoordinates)
        THEN \(literal: Self.earthRadiusNM) * acos(least(1, greatest(-1,
          sin(radians(\(bind: reference.latitude))) * sin(radians(\(latitude)))
          + cos(radians(\(bind: reference.latitude))) * cos(radians(\(latitude)))
            * cos(radians(\(longitude) - \(bind: reference.longitude))))))
        END)
      """
  }

  init(_ arguments: ToolArguments, area: NOTAMArea) throws {
    guard let start = try arguments.instant("start"), let end = try arguments.instant("end"),
      end > start, end.timeIntervalSince(start) <= 31 * 86400
    else {
      throw MCPError.invalidParams(
        "An increasing ISO 8601 time window of at most 31 days is required")
    }
    self.area = area
    self.start = start
    self.end = end
    scope = try arguments.string("scope")?.uppercased()
    if let scope, !["A", "E", "W"].contains(scope) {
      throw MCPError.invalidParams("Scope must be A, E or W")
    }
    context = [
      try arguments.string("runway").map(Self.runwayPattern),
      try arguments.string("procedure").map(Self.phrasePattern)
    ].compactMap(\.self)
    limit = try arguments.limit()
    cursor = try arguments.string("cursor").map(QueryCursor.decode)
    signature = try QueryCursor.signature(arguments.values)
  }

  private static func joined(_ clauses: [SQLQueryString], by separator: String) -> SQLQueryString? {
    guard let first = clauses.first else { return nil }
    return clauses.dropFirst().reduce("(" + first) { $0 + SQLQueryString(separator) + $1 } + ")"
  }

  /// Matches a runway designator as a whole token, with or without a leading zero.
  private static func runwayPattern(_ runway: String) -> String {
    let canonical = RunwayName.canonical(runway)
    let designator =
      canonical.hasPrefix("0") ? "0?" + escaped(canonical.dropFirst()) : escaped(canonical)
    return token(designator)
  }

  /// Matches a procedure name as a whole phrase, allowing any spacing between its words.
  private static func phrasePattern(_ phrase: String) -> String {
    token(
      phrase.split(whereSeparator: \.isWhitespace).map(escaped)
        .joined(separator: "[[:space:]]+"))
  }

  private static func token(_ pattern: String) -> String {
    "(^|[^[:alnum:]])" + pattern + "([^[:alnum:]]|$)"
  }

  private static func escaped(_ text: some StringProtocol) -> String {
    text.map { $0.isLetter || $0.isNumber ? String($0) : "\\" + String($0) }.joined()
  }

  func present(_ row: any SQLRow) throws -> Value {
    let text = try row.decode(column: "notam_text", as: String.self)
    var result: [String: Value] = [
      "id": .string(try row.decode(column: "notam_id", as: String.self)),
      "location": .string(try row.decode(column: "icao_location", as: String.self)),
      "original_text": .string(text),
      "valid_from": .string(
        try row.decode(column: "effective_start", as: Date.self).ISO8601Format())
    ]
    if let end = try row.decode(column: "effective_end", as: Date?.self) {
      result["valid_until"] = .string(end.ISO8601Format())
    }
    if let schedule = try row.decode(column: "schedule", as: String?.self) {
      result["schedule"] = .string(schedule)
    }
    let publishedScope = try row.decode(column: "scope", as: String?.self)
    if let publishedScope { result["scope"] = .string(publishedScope) }
    if scope != nil, publishedScope?.trimmingCharacters(in: .whitespaces).isEmpty != false {
      result["scope_match"] = "uncertain"
      result["scope_explanation"] =
        "No scope is published; the NOTAM is retained because its location and time overlap."
    }
    if let qLine = try row.decode(column: "q_line", as: String?.self) {
      result["q_line"] = try JSONDecoder().decode(Value.self, from: Data(qLine.utf8))
    }
    if row.contains(column: "center_distance_nm"),
      let distance = try row.decode(column: "center_distance_nm", as: Double?.self)
    {
      result["area_match"] = "overlying_artcc"
      result["center_distance_nm"] = .double((distance * 10).rounded() / 10)
    }
    if row.contains(column: "context_match") {
      result["context_match"] =
        try row.decode(column: "context_match", as: Bool.self) ? "text_match" : "uncertain"
      result["context_explanation"] =
        "Text matching cannot establish operational applicability; location and time overlap are confirmed."
    }
    return .object(result)
  }
}

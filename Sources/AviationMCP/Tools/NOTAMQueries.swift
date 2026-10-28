import Fluent
import Foundation
import MCP
import SQLKit

struct NOTAMQueries: Sendable {
  let database: any Database
  var freshness: TimeInterval = 900

  func search(_ arguments: ToolArguments) async throws -> ToolResult {
    let filter = try NOTAMFilter(arguments)
    return try await database.transaction { database in
      let sql = try database.sqlDatabase()
      try await sql.raw("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY").run()
      try await sql.raw("SET LOCAL statement_timeout = '10s'").run()
      let poll = try await sql.raw("SELECT value FROM ingestion_state WHERE key = 'last_poll_time'")
        .first(decodingColumn: "value", as: String.self)
      let generation =
        try await sql.raw("SELECT concat(count(*),':',max(updated_at)) AS token FROM notams")
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
    if poll.flatMap({ ISO8601DateFormatter().date(from: $0) }).map({
      now.timeIntervalSince($0) <= freshness
    }) != true {
      result.warnings.append(
        "NOTAM ingestion freshness is unavailable or older than the configured freshness interval."
      )
    }
    if filter.runway != nil || filter.procedure != nil {
      result.warnings.append("Context matches use NOTAM text; uncertain matches remain included.")
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
  let location: String
  let start: Date
  let end: Date
  let scope: String?
  let runway: String?
  let procedure: String?
  let limit: Int
  let cursor: QueryCursor?
  let signature: String

  var query: SQLQueryString {
    var query: SQLQueryString = """
      SELECT notam_id, icao_location, effective_start, effective_end, schedule, notam_text, scope,
        q_line::text AS q_line, updated_at
      FROM notams WHERE icao_location = \(bind: location) AND effective_start < \(bind: end)
        AND (effective_end IS NULL OR effective_end > \(bind: start))
      """
    if let scope {
      query += " AND (scope IS NULL OR btrim(scope) = '' OR scope LIKE \(bind: "%" + scope + "%"))"
    }
    query += " ORDER BY notam_id LIMIT \(bind: limit + 1) OFFSET \(bind: cursor?.offset ?? 0)"
    return query
  }

  init(_ arguments: ToolArguments) throws {
    guard let location = try arguments.string("location", required: true)?.uppercased(),
      let start = try arguments.instant("start"), let end = try arguments.instant("end"),
      end > start, end.timeIntervalSince(start) <= 31 * 86400
    else {
      throw MCPError.invalidParams(
        "A location and increasing ISO 8601 time window of at most 31 days are required")
    }
    self.location = location
    self.start = start
    self.end = end
    scope = try arguments.string("scope")?.uppercased()
    if let scope, !["A", "E", "W"].contains(scope) {
      throw MCPError.invalidParams("Scope must be A, E or W")
    }
    runway = try arguments.string("runway")?.uppercased()
    procedure = try arguments.string("procedure")?.uppercased()
    limit = try arguments.limit()
    cursor = try arguments.string("cursor").map(QueryCursor.decode)
    signature = try QueryCursor.signature(arguments.values)
  }

  func present(_ row: any SQLRow) throws -> Value {
    let text = try row.decode(column: "notam_text", as: String.self)
    var result: [String: Value] = [
      "id": .string(try row.decode(column: "notam_id", as: String.self)),
      "location": .string(location), "original_text": .string(text),
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
    let context = [runway, procedure].compactMap { $0 }
    if !context.isEmpty {
      result["context_match"] =
        context.allSatisfy { text.uppercased().contains($0) } ? "text_match" : "uncertain"
      result["context_explanation"] =
        "Text matching cannot establish operational applicability; location and time overlap are confirmed."
    }
    return .object(result)
  }
}

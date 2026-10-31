import Fluent
import Foundation
import MCP
import SQLKit

/// Indexes behind text search, airport filters and highest-obstacle ordering.
struct SearchIndexes: AsyncMigration {
  private static let minimumSearchLength = 3
  private static let indexNames = [
    "aviation_search_text", "aviation_airport_code", "aviation_obstacle_elevation"
  ]

  /// Statements creating the indexes; ``AviationSchema`` also creates them on a fresh database.
  static let creations = [
    """
    CREATE INDEX IF NOT EXISTS aviation_search_text
    ON aviation_records USING gin ((identifier || ' ' || name) gin_trgm_ops)
    """,
    """
    CREATE INDEX IF NOT EXISTS aviation_airport_code
    ON aviation_records(kind, upper(airport), version_id) WHERE airport IS NOT NULL
    """,
    """
    CREATE INDEX IF NOT EXISTS aviation_obstacle_elevation
    ON aviation_records(version_id, elevation_msl_ft DESC NULLS LAST) WHERE kind = 'obstacle'
    """
  ]

  /// A case-insensitive substring match against the trigram-indexed identifier and name, which
  /// needs at least three characters.
  static func predicate(matching text: String) throws -> SQLQueryString {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard trimmed.count >= minimumSearchLength else {
      throw MCPError.invalidParams("query requires at least \(minimumSearchLength) characters")
    }
    let escaped = ["\\", "%", "_"].reduce(trimmed) {
      $0.replacingOccurrences(of: $1, with: "\\" + $1)
    }
    return " AND (identifier || ' ' || name) ILIKE \(bind: "%" + escaped + "%")"
  }

  func prepare(on database: any Database) async throws {
    try await database.withSQLTransaction { connection in
      let sql = try connection.sqlDatabase()
      try await sql.raw("SELECT pg_advisory_xact_lock(13799201)").run()
      for statement in Self.creations {
        try await sql.raw(SQLQueryString(stringLiteral: statement)).run()
      }
    }
  }

  func revert(on database: any Database) async throws {
    try await database.withSQLTransaction { connection in
      let sql = try connection.sqlDatabase()
      try await sql.raw("SELECT pg_advisory_xact_lock(13799201)").run()
      for index in Self.indexNames {
        try await sql.raw("DROP INDEX IF EXISTS \(ident: index)").run()
      }
      try await sql.raw(
        "CREATE INDEX IF NOT EXISTS aviation_name ON aviation_records USING gin(name gin_trgm_ops)"
      ).run()
      try await sql.raw(
        """
        CREATE INDEX IF NOT EXISTS aviation_airport
        ON aviation_records(kind, upper(airport), version_id)
        """
      ).run()
    }
  }
}

import Fluent
import SQLKit

struct IdentifierLookupIndex: AsyncMigration {
  func prepare(on database: any Database) async throws {
    try await database.withSQLTransaction { connection in
      let sql = try connection.sqlDatabase()
      try await sql.raw("SELECT pg_advisory_xact_lock(13799201)").run()
      let valid = try await sql.raw(
        "SELECT indisvalid FROM pg_index WHERE indexrelid = to_regclass('aviation_faa_lid')"
      ).first(decodingColumn: "indisvalid", as: Bool.self)
      if valid == false {
        try await sql.raw("DROP INDEX aviation_faa_lid").run()
      }
      try await sql.raw(
        """
        CREATE INDEX IF NOT EXISTS aviation_faa_lid
        ON aviation_records(kind, upper(data->>'faa_lid'), version_id)
        """
      ).run()
    }
  }

  func revert(on database: any Database) async throws {
    try await database.withSQLTransaction { connection in
      let sql = try connection.sqlDatabase()
      try await sql.raw("SELECT pg_advisory_xact_lock(13799201)").run()
      try await sql.raw("DROP INDEX IF EXISTS aviation_faa_lid").run()
    }
  }
}

import Foundation
import SQLKit
import Testing

@testable import AviationMCP

extension `Transactional publication` {
  @Test
  func `re-runs schema migrations over a deployed schema`() async throws {
    try await withDatabase { store in
      let sql = try store.database.sqlDatabase()
      try await sql.raw(
        "ALTER TABLE aviation_records ADD COLUMN supplemental JSONB NOT NULL DEFAULT '{}'"
      ).run()
      for _ in 0..<2 {
        try await AviationSchema().prepare(on: store.database)
        try await TerrainSchema().prepare(on: store.database)
        try await DropSupplementalRecords().prepare(on: store.database)
      }
      let columns = try await sql.raw(
        """
        SELECT count(*) AS total FROM information_schema.columns
        WHERE table_name = 'aviation_records' AND column_name = 'supplemental'
        """
      ).first(decodingColumn: "total", as: Int.self)
      #expect(columns == 0)
    }
  }

  @Test
  func `purges expired and never-fetched weather and vacuums afterwards`() async throws {
    try await withDatabase { store in
      let sql = try store.database.sqlDatabase()
      try await sql.raw(
        """
        INSERT INTO weather_cache(key, provider, fresh_until, lease_until, retry_at) VALUES
          ('expired', 'awc', now() - INTERVAL '1 day', NULL, NULL),
          ('never-fetched', 'awc', NULL, NULL, now() - INTERVAL '1 day'),
          ('backing-off', 'awc', NULL, NULL, now() + INTERVAL '1 hour'),
          ('fetching', 'awc', NULL, now() + INTERVAL '1 minute', NULL)
        """
      ).run()
      try await store.purge()
      let keys = try await sql.raw("SELECT key FROM weather_cache ORDER BY key")
        .all(decodingColumn: "key", as: String.self)
      #expect(keys == ["backing-off", "fetching"])
      let vacuumed = try await sql.raw(
        """
        SELECT count(*) AS total FROM pg_stat_user_tables
        WHERE relname IN ('aviation_records', 'weather_cache') AND last_vacuum IS NOT NULL
        """
      ).first(decodingColumn: "total", as: Int.self)
      #expect(vacuumed == 2)
    }
  }
}

import Fluent
import SQLKit

struct TerrainSchema: AsyncMigration {
  func prepare(on database: any Database) async throws {
    let sql = try database.sqlDatabase()
    try await sql.raw(
      """
      CREATE TABLE terrain_catalog (
        singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK(singleton),
        checksum TEXT NOT NULL, imported_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        source_release TEXT NOT NULL, counts JSONB NOT NULL)
      """
    ).run()
    try await sql.raw(
      """
      CREATE TABLE terrain_tiles (
        latitude SMALLINT NOT NULL, longitude SMALLINT NOT NULL,
        name TEXT NOT NULL, product TEXT NOT NULL CHECK(product IN ('glo30','glo90','ocean')),
        footprint geography(Polygon,4326) NOT NULL,
        PRIMARY KEY(latitude,longitude))
      """
    ).run()
    try await sql.raw("CREATE INDEX terrain_footprint ON terrain_tiles USING gist(footprint)").run()
  }

  func revert(on database: any Database) async throws {
    let sql = try database.sqlDatabase()
    try await sql.raw("DROP TABLE terrain_tiles").run()
    try await sql.raw("DROP TABLE terrain_catalog").run()
  }
}

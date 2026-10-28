import Fluent
import SQLKit

struct AviationSchema: AsyncMigration {
  func prepare(on database: any Database) async throws {
    let sql = try database.sqlDatabase()
    for statement in Self.statements {
      try await sql.raw(SQLQueryString(stringLiteral: statement)).run()
    }
  }

  func revert(on database: any Database) async throws {
    let sql = try database.sqlDatabase()
    for table in [
      "active_manifest", "manifest_versions", "manifests", "aviation_records", "source_versions",
      "weather_cache", "provider_budgets", "provider_cooldowns", "admission_buckets",
      "ingestion_runs"
    ] {
      try await sql.raw("DROP TABLE IF EXISTS \(ident: table)").run()
    }
  }

  private static let statements = [
    "CREATE EXTENSION IF NOT EXISTS postgis",
    "CREATE EXTENSION IF NOT EXISTS pg_trgm",
    """
    CREATE TABLE source_versions (
      id UUID PRIMARY KEY,
      source TEXT NOT NULL CHECK (source IN ('nasr', 'cifp', 'dof', 'aircraft')),
      cycle TEXT NOT NULL, effective_from TIMESTAMPTZ NOT NULL,
      effective_until TIMESTAMPTZ,
      checksum TEXT NOT NULL, parser_revision TEXT NOT NULL,
      validated BOOLEAN NOT NULL DEFAULT FALSE,
      imported_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      validation JSONB NOT NULL DEFAULT '{}',
      CHECK (effective_until IS NULL OR effective_until > effective_from),
      CHECK (source = 'aircraft' OR effective_until IS NOT NULL)
    )
    """,
    "CREATE INDEX source_effective ON source_versions(source, effective_from, effective_until)",
    """
    CREATE TABLE aviation_records (
      version_id UUID NOT NULL REFERENCES source_versions(id) ON DELETE CASCADE,
      kind TEXT NOT NULL, id TEXT NOT NULL, identifier TEXT NOT NULL,
      name TEXT NOT NULL, airport TEXT, sequence INTEGER,
      elevation_msl_ft DOUBLE PRECISION, height_agl_ft DOUBLE PRECISION,
      geometry geography(Geometry, 4326),
      data JSONB NOT NULL, supplemental JSONB NOT NULL DEFAULT '{}',
      PRIMARY KEY (version_id, kind, id)
    )
    """,
    "CREATE INDEX aviation_geometry ON aviation_records USING gist(geometry)",
    "CREATE INDEX aviation_identifier ON aviation_records(kind, upper(identifier), version_id)",
    "CREATE INDEX aviation_airport ON aviation_records(kind, upper(airport), version_id)",
    "CREATE INDEX aviation_name ON aviation_records USING gin(name gin_trgm_ops)",
    "CREATE TABLE manifests (id UUID PRIMARY KEY, created_at TIMESTAMPTZ NOT NULL DEFAULT now())",
    """
    CREATE TABLE manifest_versions (
      manifest_id UUID NOT NULL REFERENCES manifests(id) ON DELETE CASCADE,
      version_id UUID NOT NULL REFERENCES source_versions(id) ON DELETE CASCADE,
      PRIMARY KEY (manifest_id, version_id)
    )
    """,
    """
    CREATE TABLE active_manifest (
      singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
      manifest_id UUID NOT NULL REFERENCES manifests(id)
    )
    """,
    """
    CREATE TABLE ingestion_runs (
      id UUID PRIMARY KEY, source TEXT NOT NULL, checksum TEXT NOT NULL,
      parser_revision TEXT NOT NULL, started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      finished_at TIMESTAMPTZ, outcome TEXT NOT NULL, details JSONB NOT NULL DEFAULT '{}'
    )
    """,
    """
    CREATE TABLE weather_cache (
      key TEXT PRIMARY KEY, provider TEXT NOT NULL, payload JSONB,
      retrieved_at TIMESTAMPTZ, fresh_until TIMESTAMPTZ,
      lease_id UUID, lease_until TIMESTAMPTZ, retry_at TIMESTAMPTZ,
      last_error TEXT
    )
    """,
    """
    CREATE TABLE provider_budgets (
      provider TEXT NOT NULL, period TEXT NOT NULL, window_start TIMESTAMPTZ NOT NULL,
      window_end TIMESTAMPTZ NOT NULL, consumed DOUBLE PRECISION NOT NULL CHECK (consumed >= 0),
      PRIMARY KEY (provider, period, window_start)
    )
    """,
    """
    CREATE TABLE admission_buckets (
      key TEXT PRIMARY KEY, tokens DOUBLE PRECISION NOT NULL,
      updated_at TIMESTAMPTZ NOT NULL
    )
    """,
    """
    CREATE TABLE provider_cooldowns (
      provider TEXT PRIMARY KEY, retry_at TIMESTAMPTZ NOT NULL, source TEXT NOT NULL
    )
    """
  ]
}

extension Database {
  func sqlDatabase() throws -> any SQLDatabase {
    guard let sql = self as? any SQLDatabase else { throw StorageError.requiresPostgreSQL }
    return sql
  }
}

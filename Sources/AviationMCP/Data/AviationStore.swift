import Fluent
import Foundation
import MCP
import SQLKit

struct AviationRecord: Codable, Sendable {
  let versionID: UUID
  let kind: String
  let id: String
  let identifier: String
  let name: String
  var airport: String?
  var sequence: Int?
  var elevationMSLFeet: Double?
  var heightAGLFeet: Double?
  var geometry: Value?
  var data: [String: Value] = [:]
}

struct AviationStore: Sendable {
  let database: any Database

  func snapshot() async throws -> SourceSnapshot {
    try await withSnapshot { _, snapshot in snapshot }
  }

  func withSnapshot<Result: Sendable>(
    _ operation: @escaping @Sendable (any SQLDatabase, SourceSnapshot) async throws -> Result
  ) async throws -> Result {
    try await database.withSQLTransaction { database in
      let sql = try database.sqlDatabase()
      try await sql.raw("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY").run()
      try await sql.raw("SET LOCAL statement_timeout = '10s'").run()
      let instant = try await Self.instant(on: sql)
      let versions = try await Self.publishedVersions(on: sql)
      return try await operation(sql, SourceCatalog(versions: versions).snapshot(at: instant))
    }
  }

  func publish(_ versions: [SourceVersion], records: [AviationRecord]) async throws {
    try Self.validate(versions, records: records)
    let records = SpatialOrder.sorted(records)
    try await database.withSQLTransaction { database in
      let sql = try database.sqlDatabase()
      try await sql.raw("SELECT pg_advisory_xact_lock(13799201)").run()
      let instant = try await Self.instant(on: sql)
      let existing = try await Self.publishedVersions(on: sql)
      for version in versions {
        try await Self.insert(version, on: sql)
      }
      for offset in stride(from: 0, to: records.count, by: 1000) {
        try await Self.insert(Array(records[offset..<min(offset + 1000, records.count)]), on: sql)
      }
      try await sql.raw("ANALYZE aviation_records").run()
      for version in versions { try await Self.recordValidation(version.id, on: sql) }
      let catalog = SourceCatalog(versions: existing + versions)
      let retained = catalog.retained(at: instant)
      let manifestID = UUID()
      try await sql.raw("INSERT INTO manifests(id) VALUES (\(bind: manifestID))").run()
      for version in retained {
        try await sql.raw(
          """
          INSERT INTO manifest_versions(manifest_id, version_id)
          VALUES (\(bind: manifestID), \(bind: version.id))
          """
        ).run()
      }
      try await sql.raw(
        """
        INSERT INTO active_manifest(singleton, manifest_id) VALUES (TRUE, \(bind: manifestID))
        ON CONFLICT(singleton) DO UPDATE SET manifest_id = excluded.manifest_id
        """
      ).run()
      try await Self.purge(on: sql)
    }
  }

  func purge() async throws {
    try await database.withSQLTransaction { database in
      let sql = try database.sqlDatabase()
      try await sql.raw("SELECT pg_advisory_xact_lock(13799201)").run()
      try await Self.purge(on: sql)
    }
  }

  private static func publishedVersions(on sql: any SQLDatabase) async throws -> [SourceVersion] {
    try await sql.raw(
      """
      SELECT v.* FROM source_versions v
      JOIN manifest_versions mv ON mv.version_id = v.id
      JOIN active_manifest m ON m.manifest_id = mv.manifest_id
      """
    ).all(decoding: SourceVersion.self, keyDecodingStrategy: .convertFromSnakeCase)
  }

  private static func instant(on sql: any SQLDatabase) async throws -> Date {
    guard
      let instant = try await sql.raw("SELECT transaction_timestamp() AS instant")
        .first(decodingColumn: "instant", as: Date.self)
    else {
      throw StorageError.requiresPostgreSQL
    }
    return instant
  }

  private static func insert(_ version: SourceVersion, on sql: any SQLDatabase) async throws {
    try await sql.raw(
      """
      INSERT INTO source_versions
        (id, source, cycle, effective_from, effective_until, checksum, parser_revision,
         validated, imported_at, validation)
      VALUES (\(bind: version.id), \(bind: version.source.rawValue), \(bind: version.cycle),
        \(bind: version.effectiveFrom), \(bind: version.effectiveUntil), \(bind: version.checksum),
        \(bind: version.parserRevision), TRUE, \(bind: version.importedAt),
        \(bind: try Normalization.jsonText(.object(version.validation ?? [:])))::jsonb)
      """
    ).run()
  }

  private static func insert(_ records: [AviationRecord], on sql: any SQLDatabase) async throws {
    guard let json = String(data: try JSONEncoder().encode(records), encoding: .utf8) else {
      throw StorageError.invalidImport("Import records are not UTF-8.")
    }
    try await sql.raw(
      """
      INSERT INTO aviation_records
        (version_id, kind, id, identifier, name, airport, sequence,
         elevation_msl_ft, height_agl_ft, geometry, data)
      SELECT "versionID", kind, id, identifier, name, airport, sequence,
        "elevationMSLFeet", "heightAGLFeet",
        ST_SetSRID(ST_GeomFromGeoJSON(geometry::text), 4326)::geography, data
      FROM jsonb_to_recordset(\(bind: json)::jsonb) AS r(
        "versionID" uuid, kind text, id text, identifier text, name text,
        airport text, sequence integer, "elevationMSLFeet" double precision,
        "heightAGLFeet" double precision, geometry jsonb, data jsonb)
      """
    ).run()
  }

  private static func recordValidation(_ versionID: UUID, on sql: any SQLDatabase) async throws {
    try await sql.raw(
      """
      UPDATE source_versions SET validation = COALESCE(validation, '{}'::jsonb) || (
        SELECT jsonb_build_object('record_counts', jsonb_object_agg(kind, total),
          'spatial_counts', jsonb_object_agg(kind, spatial),
          'records_with_warnings', sum(warnings), 'outcome',
          CASE WHEN COALESCE((validation->'parse_errors'->>'count')::int, 0) > 0
            THEN 'partial' ELSE 'validated' END)
        FROM (SELECT kind, count(*) AS total, count(geometry) AS spatial,
          count(*) FILTER (WHERE data ? 'source_warnings') AS warnings
          FROM aviation_records WHERE version_id = \(bind: versionID) GROUP BY kind) counts
      ) WHERE id = \(bind: versionID)
      """
    ).run()
    try await sql.raw(
      """
      UPDATE source_versions SET validation = validation || jsonb_build_object(
        'spatial_limitations', COALESCE((
          SELECT jsonb_object_agg(kind, warnings) FROM (
            SELECT kind, jsonb_agg(DISTINCT warning) AS warnings
            FROM aviation_records
            CROSS JOIN LATERAL jsonb_array_elements_text(
              COALESCE(data->'geometry_limitations', '[]'::jsonb)) AS warning
            WHERE version_id = \(bind: versionID) GROUP BY kind
          ) limitations
        ), '{}'::jsonb)) WHERE id = \(bind: versionID)
      """
    ).run()
  }

  private static func purge(on sql: any SQLDatabase) async throws {
    try await sql.raw(
      """
      DELETE FROM manifests WHERE id NOT IN (SELECT manifest_id FROM active_manifest)
      """
    ).run()
    try await sql.raw(
      """
      DELETE FROM source_versions WHERE effective_until <= transaction_timestamp()
        OR id NOT IN (SELECT version_id FROM manifest_versions)
      """
    ).run()
    try await sql.raw("DELETE FROM provider_budgets WHERE window_end <= now()").run()
    try await sql.raw("DELETE FROM provider_cooldowns WHERE retry_at <= now()").run()
    try await sql.raw("DELETE FROM admission_buckets WHERE updated_at < now() - INTERVAL '1 hour'")
      .run()
    try await sql.raw(
      """
      DELETE FROM weather_cache WHERE fresh_until < now() AND
        COALESCE(lease_until, '-infinity') < now() AND COALESCE(retry_at, '-infinity') < now()
      """
    ).run()
  }

  private static func validate(_ versions: [SourceVersion], records: [AviationRecord]) throws {
    guard !versions.isEmpty, Set(versions.map(\.source)).count == versions.count else {
      throw StorageError.invalidImport("Each publication requires distinct sources.")
    }
    let identifiers = Set(versions.map(\.id))
    guard records.allSatisfy({ identifiers.contains($0.versionID) }) else {
      throw StorageError.invalidImport("Records reference an unknown source version.")
    }
    for version in versions {
      guard version.validated, !version.cycle.isEmpty, !version.parserRevision.isEmpty,
        version.checksum.count == 64, version.checksum.allSatisfy(\.isHexDigit),
        records.contains(where: { $0.versionID == version.id }),
        version.effectiveUntil.map({ $0 > version.effectiveFrom }) != false,
        version.source == .aircraft || version.effectiveUntil != nil
      else {
        throw StorageError.invalidImport(
          "Publication requires validated, nonempty data and source metadata.")
      }
    }
    let nasr = versions.first { $0.source == .nasr }
    let cifp = versions.first { $0.source == .cifp }
    guard
      (nasr == nil && cifp == nil)
        || (nasr != nil && cifp != nil && nasr?.cycle == cifp?.cycle
          && nasr?.effectiveFrom == cifp?.effectiveFrom
          && nasr?.effectiveUntil == cifp?.effectiveUntil)
    else {
      throw StorageError.invalidImport(
        "NASR and CIFP must be published together for the same effective cycle.")
    }
  }
}

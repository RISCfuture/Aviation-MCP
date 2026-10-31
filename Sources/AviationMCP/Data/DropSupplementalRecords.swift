import Fluent
import SQLKit

/// Removes the unread copy of each parsed source record from the record table.
struct DropSupplementalRecords: AsyncMigration {
  func prepare(on database: any Database) async throws {
    try await database.executeSchema([
      "SELECT pg_advisory_xact_lock(13799201)",
      "ALTER TABLE aviation_records DROP COLUMN IF EXISTS supplemental"
    ])
  }

  func revert(on database: any Database) async throws {
    try await database.executeSchema([
      "SELECT pg_advisory_xact_lock(13799201)",
      """
      ALTER TABLE aviation_records
      ADD COLUMN IF NOT EXISTS supplemental JSONB NOT NULL DEFAULT '{}'
      """
    ])
  }
}

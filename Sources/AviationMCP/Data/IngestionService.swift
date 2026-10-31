import Fluent
import Foundation
import SQLKit

struct IngestionService: Sendable {
  /// Longer than any ingestion machine runs, so an older run that is still staging was abandoned.
  private static let abandonedAfter = "1 hour"

  let store: AviationStore

  func ingest(
    source: String, checksum: String, parserRevision: String,
    operation: @Sendable () async throws -> StagedImport
  ) async throws {
    try await failAbandonedRuns()
    let run = IngestionRun(source: source, checksum: checksum, parserRevision: parserRevision)
    try await run.create(on: store.database)
    do {
      let staged = try await operation()
      try ReleaseCompleteness(snapshot: try await store.snapshot()).verify(staged)
      try await store.publish(staged.versions, records: staged.records)
      let errors = staged.versions.reduce(0) { $0 + $1.parseErrorCount }
      run.outcome = errors == 0 ? "published" : "published_partial"
      run.details = [
        "records": String(staged.records.count),
        "parse_errors": String(errors),
        "versions": staged.versions.map { $0.id.uuidString }.joined(separator: ",")
      ]
    } catch {
      run.outcome = error is IncompleteReleaseError ? "withheld" : "failed"
      run.details = [
        "reason": String(
          ((error as? any LocalizedError)?.failureReason ?? String(describing: error)).prefix(2048))
      ]
      run.finishedAt = .now
      try await run.update(on: store.database)
      throw error
    }
    run.finishedAt = .now
    try await run.update(on: store.database)
  }

  private func failAbandonedRuns() async throws {
    try await store.database.sqlDatabase().raw(
      """
      UPDATE ingestion_runs SET outcome = 'failed', finished_at = now(),
        details = details || '{"reason": "The ingestion process stopped before finishing."}'
      WHERE outcome = 'staging' AND started_at < now() - \(bind: Self.abandonedAfter)::interval
      """
    ).run()
  }
}

// Each mutable Fluent model instance belongs to one ingestion operation.
final class IngestionRun: Model, @unchecked Sendable {
  static let schema = "ingestion_runs"

  @ID(key: .id) var id: UUID?
  @Field(key: "source") var source: String
  @Field(key: "checksum") var checksum: String
  @Field(key: "parser_revision") var parserRevision: String
  @Timestamp(key: "started_at", on: .create) var startedAt: Date?
  @OptionalField(key: "finished_at") var finishedAt: Date?
  @Field(key: "outcome") var outcome: String
  @Field(key: "details") var details: [String: String]

  init() {}

  init(source: String, checksum: String, parserRevision: String) {
    id = UUID()
    self.source = source
    self.checksum = checksum
    self.parserRevision = parserRevision
    outcome = "staging"
    details = [:]
  }
}

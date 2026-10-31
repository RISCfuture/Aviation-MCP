import Fluent
import Foundation
import SQLKit
import Testing

@testable import AviationMCP

extension `Transactional publication` {
  @Test
  func `withholds an incomplete release and fails abandoned runs`() async throws {
    try await withDatabase { store in
      let nasr = Self.version(.nasr)
      let cifp = Self.version(.cifp)
      try await store.publish([nasr, cifp], records: [.fixture(nasr), .fixture(cifp)])
      let published = try await store.snapshot().token
      try await Self.insertAbandonedRun(on: store.database.sqlDatabase())
      let truncated = Self.version(.nasr)
      await #expect(throws: IncompleteReleaseError.self) {
        try await IngestionService(store: store).ingest(
          source: "nasr", checksum: truncated.checksum, parserRevision: "fixture"
        ) {
          StagedImport(versions: [truncated], records: [Self.airport(truncated)])
        }
      }
      #expect(try await store.snapshot().token == published)
      let outcomes = try await IngestionRun.query(on: store.database).all().map(\.outcome)
      #expect(outcomes.sorted() == ["failed", "withheld"])
    }
  }

  @Test
  func `explains expired obstacle data without serving or keeping its records`() async throws {
    try await withDatabase { store in
      let expired = SourceVersion(
        id: UUID(), source: .dof, cycle: "expired", effectiveFrom: .now.addingTimeInterval(-7200),
        effectiveUntil: .now.addingTimeInterval(-3600), checksum: String(repeating: "a", count: 64),
        parserRevision: "fixture", validated: true)
      try await store.publish([expired], records: [.fixture(expired)])
      #expect(try await Self.recordCount(expired, on: store.database.sqlDatabase()) == 0)
      let error = await #expect(throws: StorageError.self) {
        try await PeriodicQueries(store: store).search(
          kinds: ["obstacle"], sources: [.dof], arguments: ToolArguments([:]))
      }
      #expect(error?.failureReason?.contains("release expired expired at") == true)
      let replacement = Self.version(.dof)
      try await store.publish([replacement], records: [.fixture(replacement)])
      #expect(try await store.snapshot().lapsed.isEmpty)
    }
  }

  private static func airport(_ version: SourceVersion) -> AviationRecord {
    AviationRecord(
      versionID: version.id, kind: "airport", id: "OAK", identifier: "KOAK", name: "Oakland")
  }

  private static func insertAbandonedRun(on sql: any SQLDatabase) async throws {
    try await sql.raw(
      """
      INSERT INTO ingestion_runs (id, source, checksum, parser_revision, started_at, outcome)
      VALUES (\(bind: UUID()), 'dof', 'fixture', 'fixture', now() - INTERVAL '2 hours', 'staging')
      """
    ).run()
  }

  private static func recordCount(_ version: SourceVersion, on sql: any SQLDatabase) async throws
    -> Int?
  {
    try await sql.raw(
      "SELECT count(*) AS total FROM aviation_records WHERE version_id = \(bind: version.id)"
    ).first(decodingColumn: "total", as: Int.self)
  }
}

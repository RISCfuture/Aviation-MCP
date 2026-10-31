import Foundation
import SQLKit
import Testing

@testable import AviationMCP

extension `Transactional publication` {
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

  private static func recordCount(_ version: SourceVersion, on sql: any SQLDatabase) async throws
    -> Int?
  {
    try await sql.raw(
      "SELECT count(*) AS total FROM aviation_records WHERE version_id = \(bind: version.id)"
    ).first(decodingColumn: "total", as: Int.self)
  }
}

import Foundation
import NIOCore
import PostgresKit
import SQLKit
import Testing
import Vapor

@testable import AviationMCP

@Suite struct `Defect classification` {
  @Test func `treats expected outcomes as non-defects`() {
    for error: any Error in [
      CancellationError(), StorageError.sourceRejected("bad zip"),
      StorageError.unavailable(.nasr), StorageError.expiredCursor,
      ToolInputError(reason: "x"), Abort(.gatewayTimeout), Abort(.serviceUnavailable),
      Abort(.tooManyRequests), ConnectionPoolTimeoutError.connectionRequestTimeout,
      ChannelError.ioOnClosedChannel
    ] { #expect(!DefectClassification.isDefect(error), "\(error)") }
  }

  @Test func `treats unexpected errors as defects`() {
    for error: any Error in [
      StorageError.invalidImport("Invalid ingestion plan."), Abort(.internalServerError),
      DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x"))
    ] { #expect(DefectClassification.isDefect(error), "\(error)") }
  }
}

extension `Transactional publication` {
  @Test func `classifies real database errors`() async throws {
    try await withDatabase { store in
      let sql = try store.database.sqlDatabase()
      let missingTable = await Self.failure {
        try await sql.raw("SELECT * FROM no_such_table").run()
      }
      #expect(DefectClassification.isDefect(try #require(missingTable)))
      let timeout = await Self.failure {
        try await sql.withSession { session in
          try await session.raw("SET statement_timeout = 1").run()
          try await session.raw("SELECT pg_sleep(1)").run()
        }
      }
      #expect(!DefectClassification.isDefect(try #require(timeout)))
    }
  }

  private static func failure(_ work: () async throws -> Void) async -> (any Error)? {
    do { try await work() } catch { return error }
    return nil
  }
}

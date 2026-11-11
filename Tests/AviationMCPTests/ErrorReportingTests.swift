import Foundation
import MCP
import NIOCore
import PostgresKit
import SQLKit
import Synchronization
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

  @Test func `treats download failures as rejected sources`() async {
    let error = await #expect(throws: StorageError.self) {
      try await StorageError.rejectingSource("The source download failed") {
        throw URLError(.timedOut)
      }
    }
    #expect(error.map(DefectClassification.isDefect) == false)
    #expect(error?.failureReason?.hasPrefix("The source download failed: ") == true)
  }
}

final class RecordingErrorReporter: ErrorReporter {
  struct Report {
    let error: String
    let tags: [String: String]
    let context: [String: String]
  }

  private let recorded = Mutex<[Report]>([])

  var reports: [Report] { recorded.withLock { $0 } }

  func report(_ error: any Error, tags: [String: String], context: [String: String]) {
    recorded.withLock {
      $0.append(Report(error: String(describing: error), tags: tags, context: context))
    }
  }
  func flush(timeout: Duration) {}
  func close() {}
}

extension `Defect classification` {
  @Test func `reports unexpected tool failures once with the tool and its arguments`() throws {
    let recorder = RecordingErrorReporter()
    let result = try ToolCatalog.unexpectedFailure(
      DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x")),
      tool: "get_airport", arguments: ["cursor": "secret", "ident": "KSFO"], reporter: recorder)
    #expect(recorder.reports.count == 1)
    #expect(recorder.reports.first?.tags["tool"] == "get_airport")
    #expect(recorder.reports.first?.context["arguments"] == #"{"ident":"KSFO"}"#)
    #expect(result.isError == true)
    #expect(
      Self.text(of: result).hasPrefix("Error service_failure: The request could not be completed."))
  }

  @Test func `does not report expected tool failures`() throws {
    let recorder = RecordingErrorReporter()
    let result = try ToolCatalog.unexpectedFailure(
      ChannelError.ioOnClosedChannel, tool: "get_airport", arguments: nil, reporter: recorder)
    #expect(recorder.reports.isEmpty)
    #expect(result.isError == true)
  }

  private static func text(of result: CallTool.Result) -> String {
    result.content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }.joined()
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

@Suite struct `Tool call log` {
  @Test func `omits cursors from the logged arguments`() {
    let metadata = Self.metadata(arguments: ["cursor": "secret", "ident": "KSFO"])
    #expect(metadata["arguments"] == .string(#"{"ident":"KSFO"}"#))
  }

  @Test func `cuts long arguments on a character boundary`() throws {
    let metadata = Self.metadata(arguments: ["note": .string(String(repeating: "é", count: 2000))])
    guard case .string(let logged) = metadata["arguments"] else { throw LogFailure.missing }
    #expect(logged.hasSuffix("…"))
    #expect(logged.dropLast().utf8.count <= ToolCallLog.argumentLimit)
    #expect(String(validatingUTF8: logged) != nil)
  }

  @Test func `reads the outcome of a failure from its error code`() throws {
    let result = try ToolResult(
      results: [], completeness: "unavailable", error: .object(["code": "service_failure"])
    ).response()
    let metadata = Self.metadata(result: result)
    #expect(metadata["outcome"] == "service_failure")
    #expect(metadata["completeness"] == "unavailable")
  }

  @Test func `reads completeness and result count from a success`() throws {
    let result = try ToolResult(results: [.int(1), .int(2)], completeness: "partial").response()
    let context = ToolCallContext(
      flyRequestID: "01TEST", jsonrpcID: "7", logger: Logger(label: "test"))
    let metadata = Self.metadata(result: result, context: context)
    #expect(metadata["outcome"] == "ok")
    #expect(metadata["completeness"] == "partial")
    #expect(metadata["result_count"] == "2")
    #expect(metadata["fly_request_id"] == "01TEST")
    #expect(metadata["jsonrpc_id"] == "7")
    #expect(metadata["tool"] == "find_airports")
  }

  @Test func `names cancellation and protocol errors`() {
    #expect(Self.metadata(error: CancellationError())["outcome"] == "cancelled")
    #expect(Self.metadata(error: MCPError.invalidParams(nil))["outcome"] == "protocol_error")
  }

  private enum LogFailure: Error { case missing }

  private static func metadata(
    arguments: [String: Value]? = nil, result: CallTool.Result? = nil,
    error: (any Error)? = nil, context: ToolCallContext? = nil
  ) -> Logger.Metadata {
    ToolCallLog.metadata(
      tool: "find_airports", arguments: arguments, result: result, error: error,
      duration: .milliseconds(12), context: context)
  }
}

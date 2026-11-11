import AsyncKit
import MCP
import PostgresKit
import Vapor

/// Separates errors that indicate a bug in this server from expected outcomes such as bad input,
/// unavailable data, an unreachable database, or a cancelled request.
enum DefectClassification {
  private static let expectedSQLStateClasses: Set<Substring> = ["08", "53", "57"]
  private static let expectedSQLStates: Set<String> = ["40001", "40P01"]

  /// Whether `error` is a defect worth reporting rather than an expected outcome.
  static func isDefect(_ error: any Error) -> Bool { !isExpected(error) }

  private static func isExpected(_ error: any Error) -> Bool {
    switch error {
    case is CancellationError, is IncompleteReleaseError, is ToolInputError, is TerrainFailure,
      is WeatherFailure, is ConnectionPoolTimeoutError:
      true
    case let error as StorageError: isExpected(error)
    case MCPError.invalidParams: true
    case is DecodingError: false
    case let error as any AbortError: isExpected(error.status)
    case let error as PSQLError: isExpected(error) || SQLConnectionAcquisition.isTransient(error)
    default: SQLConnectionAcquisition.isTransient(error)
    }
  }

  private static func isExpected(_ error: StorageError) -> Bool {
    switch error {
    case .sourceRejected, .unavailable, .expiredCursor: true
    case .requiresPostgreSQL, .invalidImport: false
    }
  }

  private static func isExpected(_ status: HTTPResponseStatus) -> Bool {
    status.code < 500 || status == .serviceUnavailable || status == .gatewayTimeout
  }

  private static func isExpected(_ error: PSQLError) -> Bool {
    switch error.code {
    case .queryCancelled: true
    case .server: error.serverInfo?[.sqlState].map(isExpectedSQLState) ?? false
    default: false
    }
  }

  private static func isExpectedSQLState(_ state: String) -> Bool {
    expectedSQLStates.contains(state) || expectedSQLStateClasses.contains(state.prefix(2))
  }
}

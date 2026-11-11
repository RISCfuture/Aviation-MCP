import Foundation

protocol AviationStorageError: Error {}

enum StorageError: AviationStorageError, LocalizedError {
  case requiresPostgreSQL
  case invalidImport(String)
  case sourceRejected(String)
  case unavailable(SourceName, reason: String? = nil)
  case expiredCursor

  var errorDescription: String? { "Aviation data request failed." }

  var failureReason: String? {
    switch self {
    case .requiresPostgreSQL: "A PostgreSQL database is required."
    case .invalidImport(let reason), .sourceRejected(let reason): reason
    case .unavailable(let source, let reason):
      (["No effective validated \(source.rawValue) data is available."]
        + [reason].compactMap(\.self))
        .joined(separator: " ")
    case .expiredCursor: "The query's source versions changed or expired. Restart the query."
    }
  }
}

extension StorageError {
  /// Runs `work`, rethrowing any failure other than cancellation as ``sourceRejected(_:)`` with
  /// `reason` and the underlying error's description.
  static func rejectingSource<T>(
    _ reason: String, _ work: () async throws -> T
  ) async throws -> T {
    do {
      return try await work()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw sourceRejected("\(reason): \(error.localizedDescription)")
    }
  }
}

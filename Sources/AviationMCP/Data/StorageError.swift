import Foundation

protocol AviationStorageError: Error {}

enum StorageError: AviationStorageError, LocalizedError {
  case requiresPostgreSQL
  case invalidImport(String)
  case unavailable(SourceName, reason: String? = nil)
  case expiredCursor

  var errorDescription: String? { "Aviation data request failed." }

  var failureReason: String? {
    switch self {
    case .requiresPostgreSQL: "A PostgreSQL database is required."
    case .invalidImport(let reason): reason
    case .unavailable(let source, let reason):
      (["No effective validated \(source.rawValue) data is available."]
        + [reason].compactMap(\.self))
        .joined(separator: " ")
    case .expiredCursor: "The query's source versions changed or expired. Restart the query."
    }
  }
}

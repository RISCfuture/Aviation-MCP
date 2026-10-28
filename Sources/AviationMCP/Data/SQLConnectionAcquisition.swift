import PostgresKit

enum SQLConnectionAcquisition {
  private static let delays: [Duration] = [.milliseconds(500), .seconds(1)]
  private static let retryWindow: Duration = .seconds(15)

  static func run<Value: Sendable>(
    _ acquire: @Sendable () async throws -> Result<Value, any Error>
  ) async throws -> Value {
    let deadline = ContinuousClock.now.advanced(by: retryWindow)
    var failures = 0
    while true {
      try Task.checkCancellation()
      let outcome: Result<Value, any Error>
      do {
        outcome = try await acquire()
      } catch {
        guard failures < delays.count, isTransient(error),
          ContinuousClock.now.advanced(by: delays[failures]) < deadline
        else { throw error }
        try await Task.sleep(for: delays[failures])
        failures += 1
        continue
      }
      // A returned failure belongs to work on a leased connection and must not be replayed.
      return try outcome.get()
    }
  }

  private static func isTransient(_ error: any Error) -> Bool {
    if let error = error as? ChannelError { return error == .ioOnClosedChannel }
    guard let error = error as? PSQLError else { return false }
    switch error.code {
    case .serverClosedConnection, .connectionError, .uncleanShutdown: return true
    case .server: return ["57P01", "57P03"].contains(error.serverInfo?[.sqlState] ?? "")
    default: return false
    }
  }
}

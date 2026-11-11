import Fluent
import PostgresKit
import SQLKit

extension Database {
  func sqlDatabase() throws -> any SQLDatabase {
    guard let postgres = self as? any PostgresDatabase else {
      throw StorageError.requiresPostgreSQL
    }
    return ConnectedSQLDatabase(database: postgres)
  }

  /// Runs `operation` in a transaction. A leased connection that cannot begin one, such as a
  /// pooled connection the server closed while it sat idle, is retried like a failed acquisition,
  /// since nothing has run on it yet.
  func withSQLTransaction<Value: Sendable>(
    _ operation: @escaping @Sendable (any Database) async throws -> Value
  ) async throws -> Value {
    try await runSQLTransaction(beginning: "BEGIN", replayingAfter: { _ in false }, operation)
  }

  /// Runs `operation` in a read-only transaction. Postgres rejects any write in it, so a
  /// transaction that loses its connection at any point is replayed on a fresh connection.
  /// `operation` must have no effects outside the transaction.
  func withReadOnlySQLTransaction<Value: Sendable>(
    _ operation: @escaping @Sendable (any Database) async throws -> Value
  ) async throws -> Value {
    try await runSQLTransaction(
      beginning: "BEGIN READ ONLY", replayingAfter: SQLConnectionAcquisition.isTransient,
      retryDelays: SQLConnectionAcquisition.restartRetryDelays, operation)
  }

  private func runSQLTransaction<Value: Sendable>(
    beginning statement: SQLQueryString,
    replayingAfter isReplayable: @escaping @Sendable (any Error) -> Bool,
    retryDelays: [Duration] = SQLConnectionAcquisition.defaultRetryDelays,
    _ operation: @escaping @Sendable (any Database) async throws -> Value
  ) async throws -> Value {
    try await SQLConnectionAcquisition.run(retryDelays: retryDelays) {
      try await withConnection { database -> Result<Value, any Error> in
        let sql = try await database.beginSQLTransaction(statement)
        do {
          return .success(try await database.completeSQLTransaction(operation, on: sql))
        } catch  where isReplayable(error) {
          throw error
        } catch {
          return .failure(error)
        }
      }
    }
  }

  private func beginSQLTransaction(_ statement: SQLQueryString) async throws -> any SQLDatabase {
    let sql = try sqlDatabase()
    do {
      try await sql.raw(statement).run()
    } catch {
      await closeConnection()
      throw error
    }
    return sql
  }

  private func completeSQLTransaction<Value: Sendable>(
    _ operation: @Sendable (any Database) async throws -> Value, on sql: any SQLDatabase
  ) async throws -> Value {
    do {
      let result = try await operation(self)
      try await sql.raw("COMMIT").run()
      return result
    } catch {
      do {
        try await sql.raw("ROLLBACK").run()
      } catch {
        logger.warning("Transaction rollback failed; closing its connection")
        await closeConnection()
      }
      throw error
    }
  }

  private func closeConnection() async {
    guard let postgres = self as? any PostgresDatabase else { return }
    try? await postgres.withConnection { $0.close() }.get()
  }
}

private struct ConnectedSQLDatabase: SQLDatabase {
  let database: any PostgresDatabase

  var logger: Logger { database.logger }
  var eventLoop: any EventLoop { database.eventLoop }
  var dialect: any SQLDialect { PostgresDialect() }

  func execute(
    sql query: any SQLExpression, _ onRow: @escaping @Sendable (any SQLRow) -> Void
  ) -> EventLoopFuture<Void> {
    eventLoop.makeFutureWithTask {
      try await SQLConnectionAcquisition.run {
        try await database.withConnection { connection in
          connection.eventLoop.flatSubmit {
            ActivePostgresConnection(connection: connection).sql().execute(sql: query, onRow)
          }.map { Result<Void, any Error>.success(()) }
            .flatMapErrorThrowing { .failure($0) }
        }.get()
      }
    }
  }

  func withSession<Value: Sendable>(
    _ operation: @escaping @Sendable (any SQLDatabase) async throws -> Value
  ) async throws -> Value {
    try await SQLConnectionAcquisition.run {
      try await database.withConnection { connection in
        connection.eventLoop.makeFutureWithTask { () -> Result<Value, any Error> in
          do {
            return .success(try await operation(ConnectedSQLDatabase(database: connection)))
          } catch { return .failure(error) }
        }
      }.get()
    }
  }
}

private struct ActivePostgresConnection: PostgresDatabase {
  let connection: PostgresConnection

  var logger: Logger { connection.logger }
  var eventLoop: any EventLoop { connection.eventLoop }

  func withConnection<Result>(
    _ operation: @escaping (PostgresConnection) -> EventLoopFuture<Result>
  ) -> EventLoopFuture<Result> {
    // SQLKit submits its encoded query here, on the connection's event loop.
    eventLoop.preconditionInEventLoop()
    guard !connection.isClosed else {
      return eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel)
    }
    return operation(connection)
  }

  func send(_ request: any PostgresRequest, logger: Logger) -> EventLoopFuture<Void> {
    withConnection { $0.send(request, logger: logger) }
  }
}

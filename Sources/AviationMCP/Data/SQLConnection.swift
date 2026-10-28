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

  func withSQLTransaction<Result: Sendable>(
    _ operation: @escaping @Sendable (any Database) async throws -> Result
  ) async throws -> Result {
    try await withConnection { database in
      let sql = try database.sqlDatabase()
      try await sql.raw("BEGIN").run()
      do {
        let result = try await operation(database)
        try await sql.raw("COMMIT").run()
        return result
      } catch {
        do {
          try await sql.raw("ROLLBACK").run()
        } catch {
          database.logger.warning("Transaction rollback failed; closing its connection")
          if let postgres = database as? any PostgresDatabase {
            try? await postgres.withConnection { $0.close() }.get()
          }
        }
        throw error
      }
    }
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
    database.withConnection { connection in
      connection.eventLoop.flatSubmit {
        ActivePostgresConnection(connection: connection).sql().execute(sql: query, onRow)
      }
    }
  }

  func withSession<Result: Sendable>(
    _ operation: @escaping @Sendable (any SQLDatabase) async throws -> Result
  ) async throws -> Result {
    try await database.withConnection { connection in
      connection.eventLoop.makeFutureWithTask {
        try await operation(ConnectedSQLDatabase(database: connection))
      }
    }.get()
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

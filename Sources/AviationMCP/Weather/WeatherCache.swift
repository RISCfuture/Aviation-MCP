import Fluent
import Foundation
import MCP
import SQLKit

struct CachedWeather: Sendable {
  let payload: Value
  let retrievedAt: Date
  let freshUntil: Date
  let cacheHit: Bool
}

struct WeatherCache: Sendable {
  private static let firstPoll = Duration.milliseconds(250)
  private static let slowestPoll = Duration.seconds(1)

  let database: any Database
  var freshness: TimeInterval = 900

  func value(
    key: String, provider: String,
    fetch: @escaping @Sendable () async throws -> Value
  ) async throws -> CachedWeather {
    let deadline = ContinuousClock.now.advanced(by: .seconds(25))
    var poll = Self.firstPoll
    while ContinuousClock.now < deadline {
      try Task.checkCancellation()
      switch try await claim(key: key, provider: provider) {
      case .cached(let value): return value
      case .failure(let error): throw error
      case .waiting:
        try await Task.sleep(for: poll)
        poll = min(poll * 2, Self.slowestPoll)
      case .lease(let id):
        return try await fetchAndStore(key: key, provider: provider, leaseID: id, fetch: fetch)
      }
    }
    throw WeatherFailure(
      provider: provider, reason: "An identical request is still in progress.",
      retryAt: .now.addingTimeInterval(5))
  }

  private func claim(key: String, provider: String) async throws -> Claim {
    try await database.withSQLTransaction { database in
      let sql = try database.sqlDatabase()
      try await sql.raw(
        """
        INSERT INTO weather_cache(key, provider) VALUES (\(bind: key), \(bind: provider))
        ON CONFLICT(key) DO NOTHING
        """
      ).run()
      guard
        let row = try await sql.raw(
          """
          SELECT payload::text, retrieved_at, fresh_until, lease_until, retry_at, last_error
          FROM weather_cache WHERE key = \(bind: key) FOR UPDATE
          """
        ).first()
      else { throw StorageError.requiresPostgreSQL }
      let now = try await sql.clock()
      if let fresh = try row.decode(column: "fresh_until", as: Date?.self), fresh > now,
        let retrieved = try row.decode(column: "retrieved_at", as: Date?.self),
        let payload = try row.decode(column: "payload", as: String?.self)
      {
        return .cached(
          CachedWeather(
            payload: try JSONDecoder().decode(Value.self, from: Data(payload.utf8)),
            retrievedAt: retrieved, freshUntil: fresh, cacheHit: true))
      }
      if let retry = try row.decode(column: "retry_at", as: Date?.self), retry > now,
        let error = try row.decode(column: "last_error", as: String?.self)
      {
        return .failure(try JSONDecoder().decode(WeatherFailure.self, from: Data(error.utf8)))
      }
      if let lease = try row.decode(column: "lease_until", as: Date?.self), lease > now {
        return .waiting
      }
      let id = UUID()
      try await sql.raw(
        """
        UPDATE weather_cache SET lease_id = \(bind: id), lease_until = \(bind: now.addingTimeInterval(30))
        WHERE key = \(bind: key)
        """
      ).run()
      return .lease(id)
    }
  }

  private func fetchAndStore(
    key: String, provider: String, leaseID: UUID,
    fetch: @escaping @Sendable () async throws -> Value
  ) async throws -> CachedWeather {
    let sql = try database.sqlDatabase()
    do {
      let payload = try await fetch()
      try Task.checkCancellation()
      let retrieved = try await sql.clock()
      let fresh = retrieved.addingTimeInterval(freshness)
      let json = try JSONEncoder().encode(payload)
      guard let text = String(data: json, encoding: .utf8) else {
        throw StorageError.invalidImport("Weather payload is not UTF-8.")
      }
      try await sql.raw(
        """
        UPDATE weather_cache SET payload = \(bind: text)::jsonb,
          retrieved_at = \(bind: retrieved), fresh_until = \(bind: fresh),
          lease_id = NULL, lease_until = NULL, retry_at = NULL, last_error = NULL
        WHERE key = \(bind: key) AND lease_id = \(bind: leaseID)
        """
      ).run()
      return CachedWeather(
        payload: payload, retrievedAt: retrieved, freshUntil: fresh, cacheHit: false)
    } catch {
      let failure =
        error as? WeatherFailure
        ?? WeatherFailure(
          provider: provider, reason: "Upstream request failed.",
          retryAt: .now.addingTimeInterval(30))
      let shared = !(error is CancellationError) && failure.clientSpecific != true
      let retry = shared ? failure.retryAt ?? .now.addingTimeInterval(30) : Date.now
      let text = String(data: try JSONEncoder().encode(failure), encoding: .utf8)
      try await sql.raw(
        """
        UPDATE weather_cache SET lease_id = NULL, lease_until = NULL,
          retry_at = \(bind: retry), last_error = \(bind: text)
        WHERE key = \(bind: key) AND lease_id = \(bind: leaseID)
        """
      ).run()
      if error is CancellationError { throw error }
      throw failure
    }
  }

  private enum Claim {
    case cached(CachedWeather)
    case failure(WeatherFailure)
    case lease(UUID)
    case waiting
  }
}

import Fluent
import Foundation
import SQLKit

enum BudgetPeriod: String, Codable, CaseIterable, Sendable {
  case minute, hour, day, month

  var component: Calendar.Component {
    switch self {
    case .minute: .minute
    case .hour: .hour
    case .day: .day
    case .month: .month
    }
  }

  func interval(containing instant: Date) throws -> DateInterval {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    guard let interval = calendar.dateInterval(of: component, for: instant) else {
      throw StorageError.invalidImport("Cannot calculate provider budget window.")
    }
    return interval
  }
}

struct BudgetLimit: Codable, Sendable {
  let period: BudgetPeriod
  let units: Double

  static let openMeteo: [Self] = [
    .init(period: .minute, units: 600), .init(period: .hour, units: 5000),
    .init(period: .day, units: 10_000), .init(period: .month, units: 300_000)
  ]
}

struct BudgetBalance: Codable, Sendable {
  let period: BudgetPeriod
  let limit: Double
  let remaining: Double
  let resetsAt: String
}

struct BudgetReport: Codable, Sendable {
  let provider: String
  let allowed: Bool
  let requestedUnits: Double
  let limits: [BudgetBalance]
  var tracking = "local_estimate"
  var retryAt: String?
  var retrySource: String?
}

enum WeatherRequestCost {
  static func units(variables: Int, locations: Int, models: Int, hours: Int) -> Double {
    max(1, Double(variables) / 10) * max(1, Double(hours) / 336)
      * Double(max(1, locations)) * Double(max(1, models))
  }
}

struct ProviderBudgets: Sendable {
  let database: any Database

  func reserve(
    provider: String, units: Double, limits: [BudgetLimit]
  ) async throws -> BudgetReport {
    guard units.isFinite, units >= 0,
      limits.allSatisfy({ $0.units.isFinite && $0.units > 0 }),
      Set(limits.map(\.period)).count == limits.count
    else { throw StorageError.invalidImport("Invalid provider budget configuration.") }
    return try await database.withSQLTransaction { database in
      let sql = try database.sqlDatabase()
      try await sql.raw(
        "SELECT pg_advisory_xact_lock(hashtextextended(\(bind: provider), 13799202))"
      ).run()
      let now = try await sql.clock()
      let windows = try await Self.windows(limits, provider: provider, at: now, on: sql)
      let blocked = windows.filter { $0.consumed + units > $0.limit.units }
      let cooldown = try await sql.raw(
        """
        SELECT retry_at, source FROM provider_cooldowns WHERE provider = \(bind: provider) AND retry_at > \(bind: now)
        """
      ).first()
      let cooldownUntil = try cooldown?.decode(column: "retry_at", as: Date.self)
      let allowed = blocked.isEmpty && cooldown == nil
      if allowed, units > 0 {
        for window in windows {
          try await sql.raw(
            """
            INSERT INTO provider_budgets(provider, period, window_start, window_end, consumed)
            VALUES (\(bind: provider), \(bind: window.limit.period.rawValue),
              \(bind: window.interval.start), \(bind: window.interval.end), \(bind: units))
            ON CONFLICT(provider, period, window_start)
            DO UPDATE SET consumed = provider_budgets.consumed + excluded.consumed
            """
          ).run()
        }
      }
      return BudgetReport(
        provider: provider, allowed: allowed, requestedUnits: units,
        limits: windows.map { window in
          BudgetBalance(
            period: window.limit.period, limit: window.limit.units,
            remaining: max(0, window.limit.units - window.consumed - (allowed ? units : 0)),
            resetsAt: window.interval.end.ISO8601Format())
        },
        retryAt: (blocked.map(\.interval.end) + [cooldownUntil].compactMap { $0 }).max()?
          .ISO8601Format(),
        retrySource: try cooldown?.decode(column: "source", as: String.self)
          ?? (allowed ? nil : "local_estimate"))
    }
  }

  func coolDown(provider: String, until: Date, source: String) async throws {
    let sql = try database.sqlDatabase()
    try await sql.raw(
      """
      INSERT INTO provider_cooldowns(provider, retry_at, source)
      VALUES (\(bind: provider), \(bind: until), \(bind: source))
      ON CONFLICT(provider) DO UPDATE SET retry_at = excluded.retry_at, source = excluded.source
      WHERE provider_cooldowns.retry_at < excluded.retry_at
      """
    ).run()
  }

  private static func windows(
    _ limits: [BudgetLimit], provider: String, at now: Date,
    on sql: any SQLDatabase
  ) async throws -> [Window] {
    var windows: [Window] = []
    for limit in limits {
      let interval = try limit.period.interval(containing: now)
      let consumed =
        try await sql.raw(
          """
          SELECT consumed FROM provider_budgets WHERE provider = \(bind: provider)
            AND period = \(bind: limit.period.rawValue) AND window_start = \(bind: interval.start)
          """
        ).first(decodingColumn: "consumed", as: Double.self) ?? 0
      windows.append(Window(limit: limit, interval: interval, consumed: consumed))
    }
    return windows
  }

  private struct Window {
    let limit: BudgetLimit
    let interval: DateInterval
    let consumed: Double
  }
}

extension SQLDatabase {
  func clock() async throws -> Date {
    guard
      let now = try await raw("SELECT clock_timestamp() AS instant")
        .first(decodingColumn: "instant", as: Date.self)
    else { throw StorageError.requiresPostgreSQL }
    return now
  }
}

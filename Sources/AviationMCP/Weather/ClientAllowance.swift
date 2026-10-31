import Foundation

/// The admitted client's network (one IPv4 address or IPv6 /64), bound for the duration of an
/// MCP tool call.
enum WeatherClient {
  @TaskLocal static var key: IPNetwork?
}

/// Caps each client's share of the upstream provider budgets within this process, so one client
/// cannot exhaust a provider for everyone else.
///
/// Shares apply to the minute, hour and day windows of a provider's limits; the shared
/// `ProviderBudgets` ledger still enforces every global window.
actor ClientAllowance {
  private static let periods: Set<BudgetPeriod> = [.minute, .hour, .day]

  /// The fraction of each global limit one client may consume.
  let fraction: Double
  private var usage: [UsageKey: Usage] = [:]

  init(fraction: Double = 0.2) {
    self.fraction = fraction
  }

  /// Reserves units against the client's share of every applicable limit, returning `nil` when
  /// they are reserved and otherwise the time the exhausted share resets.
  func reserve(
    provider: String, client: IPNetwork, units: Double, limits: [BudgetLimit], at now: Date = .now
  ) throws -> Date? {
    pruneExpired(at: now)
    let windows = try windows(provider: provider, client: client, limits: limits, at: now)
    let exhausted = windows.filter { $0.consumed + units > $0.limit.units * fraction }
    guard exhausted.isEmpty else { return exhausted.map(\.interval.end).max() }
    for window in windows {
      usage[window.key] = Usage(interval: window.interval, consumed: window.consumed + units)
    }
    return nil
  }

  /// Returns units reserved for a request the global budget then refused.
  func refund(
    provider: String, client: IPNetwork, units: Double, limits: [BudgetLimit], at now: Date = .now
  ) throws {
    for window in try windows(provider: provider, client: client, limits: limits, at: now) {
      usage[window.key] = Usage(
        interval: window.interval, consumed: max(0, window.consumed - units))
    }
  }

  private func windows(
    provider: String, client: IPNetwork, limits: [BudgetLimit], at now: Date
  ) throws -> [Window] {
    try limits.filter { Self.periods.contains($0.period) }.map { limit in
      let key = UsageKey(provider: provider, client: client, period: limit.period)
      let interval = try limit.period.interval(containing: now)
      let current = usage[key].flatMap { $0.interval == interval ? $0.consumed : nil }
      return Window(key: key, limit: limit, interval: interval, consumed: current ?? 0)
    }
  }

  private func pruneExpired(at now: Date) {
    usage = usage.filter { $0.value.interval.end > now }
  }

  private struct UsageKey: Hashable {
    let provider: String
    let client: IPNetwork
    let period: BudgetPeriod
  }

  private struct Usage {
    let interval: DateInterval
    let consumed: Double
  }

  private struct Window {
    let key: UsageKey
    let limit: BudgetLimit
    let interval: DateInterval
    let consumed: Double
  }
}

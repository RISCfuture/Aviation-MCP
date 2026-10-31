import Foundation

/// A value loaded on demand and reused until it is older than its lifetime.
actor ExpiringValue<Value: Sendable> {
  private let lifetime: Duration
  private let load: @Sendable () async throws -> Value
  private var cached: (value: Value, loaded: ContinuousClock.Instant)?

  init(lifetime: Duration, load: @escaping @Sendable () async throws -> Value) {
    self.lifetime = lifetime
    self.load = load
  }

  func current(now: ContinuousClock.Instant = .now) async throws -> Value {
    if let cached, cached.loaded.duration(to: now) < lifetime { return cached.value }
    let value = try await load()
    cached = (value, now)
    return value
  }
}

/**
 Database-backed metrics that refresh only after new tool calls, at most once per interval.

 Fly scrapes `/metrics` every 15 seconds over the private network. Tying refreshes to tool traffic
 lets the connection pool drain and the database machine stop while the server sits idle.
 */
actor TrafficGatedMetrics {
  private static let minimumRefreshInterval = Duration.seconds(60)

  private let load: @Sendable () async throws -> String
  private var rendered = ""
  private var renderedAfterCalls = 0
  private var refreshed: ContinuousClock.Instant?

  init(load: @escaping @Sendable () async throws -> String) {
    self.load = load
  }

  func render(afterCalls calls: Int, now: ContinuousClock.Instant = .now) async throws -> String {
    guard calls > renderedAfterCalls, isRefreshDue(at: now) else { return rendered }
    rendered = try await load()
    renderedAfterCalls = calls
    refreshed = now
    return rendered
  }

  private func isRefreshDue(at now: ContinuousClock.Instant) -> Bool {
    refreshed.map { $0.duration(to: now) >= Self.minimumRefreshInterval } ?? true
  }
}

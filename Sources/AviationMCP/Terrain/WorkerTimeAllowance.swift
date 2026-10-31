/// Each client's share of the single terrain worker: a client may start a job while its balance
/// of worker time is positive, and each job it starts draws its running time from that balance.
struct WorkerTimeAllowance {
  private static let burst = Duration.seconds(60)
  /// Worker time a client regains per second, so one client can hold the worker for at most a
  /// quarter of the time once its burst is spent.
  private static let regainedPerSecond = 0.25

  private var balances: [IPNetwork: Balance] = [:]

  /// Returns `nil` when the client may start a job, and otherwise how long until it may.
  mutating func wait(for client: IPNetwork, at now: ContinuousClock.Instant) -> Duration? {
    balances = balances.filter { balance(of: $0.key, at: now) < Self.burst }
    let available = balance(of: client, at: now)
    guard available <= .zero else { return nil }
    return (.zero - available) / Self.regainedPerSecond
  }

  mutating func charge(
    _ client: IPNetwork, for duration: Duration, at now: ContinuousClock.Instant
  ) {
    balances[client] = Balance(remaining: balance(of: client, at: now) - duration, updated: now)
  }

  private func balance(of client: IPNetwork, at now: ContinuousClock.Instant) -> Duration {
    guard let balance = balances[client] else { return Self.burst }
    let regained = max(.zero, balance.updated.duration(to: now)) * Self.regainedPerSecond
    return min(Self.burst, balance.remaining + regained)
  }

  private struct Balance {
    let remaining: Duration
    let updated: ContinuousClock.Instant
  }
}

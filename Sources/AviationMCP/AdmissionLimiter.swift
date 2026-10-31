import Foundation
import MCP
import Vapor

/// A token-bucket refill rate and capacity.
struct AdmissionRate: Sendable {
  let requestsPerMinute: Double
  let burst: Double

  var perSecond: Double { requestsPerMinute / 60 }
}

/// The budget one key receives: a token bucket plus a cap on in-flight tool calls.
struct AdmissionPolicy: Sendable {
  let rate: AdmissionRate
  let concurrency: Int
}

/// Budgets for individual clients, for hosted connectors' shared egress ranges, and for the
/// whole server.
struct AdmissionSettings: Sendable {
  var client = AdmissionPolicy(
    rate: AdmissionRate(requestsPerMinute: 60, burst: 20), concurrency: 2)
  var connector = AdmissionPolicy(
    rate: AdmissionRate(requestsPerMinute: 600, burst: 120), concurrency: 4)
  var connectorNetworks: [IPNetwork] = []
  var global = AdmissionRate(requestsPerMinute: 1200, burst: 200)
}

/// Proof of an admitted request, returned to the limiter when the request finishes.
struct AdmissionTicket: Sendable {
  fileprivate let key: IPNetwork?
}

enum AdmissionDecision: Sendable {
  case admitted(AdmissionTicket)
  case rateLimited(retryAfterSeconds: Int)
  case concurrencyLimited
}

/**
 Meters `tools/call` requests in memory on the single serving machine.

 Each client network (an IPv4 address or IPv6 /64) has its own bucket. Requests from a configured
 connector egress range share that range's larger bucket, and every admitted request also draws
 from one global bucket.
 */
actor AdmissionLimiter {
  private static let pruneInterval = Duration.seconds(60)

  private let settings: AdmissionSettings
  private var buckets: [IPNetwork?: TokenBucket] = [:]
  private var inFlight: [IPNetwork?: Int] = [:]
  private var global: TokenBucket
  private var lastPrune: ContinuousClock.Instant

  init(settings: AdmissionSettings, now: ContinuousClock.Instant = .now) {
    self.settings = settings
    global = TokenBucket(rate: settings.global, now: now)
    lastPrune = now
  }

  func admit(_ address: IPAddress?, cost: Int, now: ContinuousClock.Instant = .now)
    -> AdmissionDecision
  {
    let key = budgetKey(for: address)
    let policy = policy(for: key)
    var bucket = buckets[key] ?? TokenBucket(rate: policy.rate, now: now)
    bucket.refill(policy.rate, at: now)
    global.refill(settings.global, at: now)
    buckets[key] = bucket
    defer { prune(at: now) }
    guard inFlight[key, default: 0] < policy.concurrency else { return .concurrencyLimited }
    let demand = Double(cost)
    guard bucket.tokens >= demand else {
      return .rateLimited(retryAfterSeconds: bucket.secondsUntil(demand, rate: policy.rate))
    }
    guard global.tokens >= demand else {
      return .rateLimited(retryAfterSeconds: global.secondsUntil(demand, rate: settings.global))
    }
    buckets[key]?.tokens -= demand
    global.tokens -= demand
    inFlight[key, default: 0] += 1
    return .admitted(AdmissionTicket(key: key))
  }

  func release(_ ticket: AdmissionTicket) {
    inFlight[ticket.key, default: 1] -= 1
    if inFlight[ticket.key] == 0 { inFlight.removeValue(forKey: ticket.key) }
  }

  private func budgetKey(for address: IPAddress?) -> IPNetwork? {
    guard let address else { return nil }
    return settings.connectorNetworks.first { $0.contains(address) } ?? IPNetwork(client: address)
  }

  private func policy(for key: IPNetwork?) -> AdmissionPolicy {
    guard let key, settings.connectorNetworks.contains(key) else { return settings.client }
    return settings.connector
  }

  private func prune(at now: ContinuousClock.Instant) {
    guard lastPrune.duration(to: now) >= Self.pruneInterval else { return }
    lastPrune = now
    buckets = buckets.filter { key, bucket in
      var refilled = bucket
      refilled.refill(policy(for: key).rate, at: now)
      return inFlight[key] != nil || refilled.tokens < policy(for: key).rate.burst
    }
  }
}

private struct TokenBucket {
  var tokens: Double
  var updated: ContinuousClock.Instant

  init(rate: AdmissionRate, now: ContinuousClock.Instant) {
    tokens = rate.burst
    updated = now
  }

  mutating func refill(_ rate: AdmissionRate, at now: ContinuousClock.Instant) {
    let elapsed = max(.zero, updated.duration(to: now))
    tokens = min(rate.burst, tokens + elapsed / .seconds(1) * rate.perSecond)
    updated = max(updated, now)
  }

  func secondsUntil(_ demand: Double, rate: AdmissionRate) -> Int {
    max(1, Int(((demand - tokens) / rate.perSecond).rounded(.up)))
  }
}

/// Charges `tools/call` requests to `/mcp` against the admission limiter; every other request
/// passes free.
struct AdmissionMiddleware: AsyncMiddleware {
  let limiter: AdmissionLimiter
  let clients: ClientAddressResolver

  func respond(to request: Vapor.Request, chainingTo next: any AsyncResponder) async throws
    -> Vapor.Response
  {
    guard request.url.path == "/mcp", request.method == .POST else {
      return try await next.respond(to: request)
    }
    let body = try await request.body.collect(max: MCPGateway.maximumBodyBytes).get()
    let cost = JSONRPCPayload(body).toolCallCount
    guard cost > 0 else { return try await next.respond(to: request) }
    let address = clients.address(of: request)
    switch await limiter.admit(address, cost: cost) {
    case .admitted(let ticket):
      do {
        let response = try await WeatherClient.$key.withValue(address.map(IPNetwork.init(client:))) {
          try await next.respond(to: request)
        }
        await limiter.release(ticket)
        return response
      } catch {
        await limiter.release(ticket)
        throw error
      }
    case .rateLimited(let seconds):
      return Self.tooManyRequests(error: "server_rate_limit", retryAfterSeconds: seconds)
    case .concurrencyLimited:
      return Self.tooManyRequests(error: "client_concurrency_limit", retryAfterSeconds: 1)
    }
  }

  private static func tooManyRequests(error: String, retryAfterSeconds: Int) -> Vapor.Response {
    Vapor.Response(
      status: .tooManyRequests,
      headers: ["Retry-After": String(retryAfterSeconds), "Content-Type": "application/json"],
      body: .init(
        string: "{\"error\":\"\(error)\",\"retry_after_seconds\":\(retryAfterSeconds)}"))
  }
}

/// A JSON-RPC request body, classified only as far as admission needs.
struct JSONRPCPayload {
  let messages: [Value]

  init(_ body: ByteBuffer?) {
    let value = body.flatMap {
      try? JSONDecoder().decode(Value.self, from: Data($0.readableBytesView))
    }
    messages = value?.arrayValue ?? value.map { [$0] } ?? []
  }

  var toolCallCount: Int {
    messages.count { $0.objectValue?["method"]?.stringValue == "tools/call" }
  }
}

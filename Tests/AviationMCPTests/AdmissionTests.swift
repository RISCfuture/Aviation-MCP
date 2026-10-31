import Crypto
import Foundation
import MCP
import Testing
import Vapor
import VaporTesting

@testable import AviationMCP

@Suite
struct `Admission and edge controls` {
  private static let secret = "terrain-proxy-test-secret-32-bytes"

  @Test
  func `groups IPv6 clients by their /64 and parses addresses strictly`() throws {
    let client = try #require(IPAddress("2001:db8:1:2:aaaa::1"))
    let neighbor = try #require(IPAddress("2001:db8:1:2:ffff:ffff:ffff:ffff"))
    let stranger = try #require(IPAddress("2001:db8:1:3::1"))
    #expect(IPNetwork(client: client) == IPNetwork(client: neighbor))
    #expect(IPNetwork(client: client) != IPNetwork(client: stranger))
    #expect(IPAddress("::ffff:192.0.2.1") == IPAddress("192.0.2.1"))
    #expect(IPAddress("::") == .ipv6(0))
    for invalid in [
      "", "192.0.2", "192.0.2.256", "1::2::3", "1:2:3:4:5:6:7:8:9", "1:2:3:4:5:6:7:8::",
      "12345::", "fe80::1%en0", "::ffff:1.2.3", "1.2.3.4::"
    ] {
      #expect(IPAddress(invalid) == nil)
    }
    let range = try #require(IPNetwork(cidr: "160.79.104.0/21"))
    #expect(range.contains(try #require(IPAddress("160.79.111.255"))))
    #expect(!range.contains(try #require(IPAddress("160.79.112.0"))))
    #expect(IPNetwork(cidr: "160.79.104.0/33") == nil)
  }

  @Test
  func `meters clients, connector ranges and the global ceiling separately`() async throws {
    let start = ContinuousClock.now
    let limiter = AdmissionLimiter(
      settings: AdmissionSettings(
        client: AdmissionPolicy(
          rate: AdmissionRate(requestsPerMinute: 60, burst: 2), concurrency: 100),
        connector: AdmissionPolicy(
          rate: AdmissionRate(requestsPerMinute: 60, burst: 5), concurrency: 100),
        connectorNetworks: [try #require(IPNetwork(cidr: "160.79.104.0/21"))],
        global: AdmissionRate(requestsPerMinute: 60, burst: 8)),
      now: start)
    func admissions(_ address: String, attempts: Int, at now: ContinuousClock.Instant = start)
      async -> Int
    {
      var decisions: [AdmissionDecision] = []
      for _ in 0..<attempts {
        decisions.append(await limiter.admit(IPAddress(address), cost: 1, now: now))
      }
      return decisions.count { $0.ticket != nil }
    }
    #expect(await admissions("2001:db8::1", attempts: 3) == 2)
    #expect(await admissions("2001:db8::2", attempts: 1) == 0)
    #expect(await admissions("160.79.104.10", attempts: 3) == 3)
    #expect(await admissions("160.79.110.7", attempts: 3) == 2)
    #expect(await admissions("192.0.2.1", attempts: 2) == 1)
    let decision = await limiter.admit(IPAddress("192.0.2.9"), cost: 1, now: start)
    #expect(decision.retryAfterSeconds == 1)
    #expect(await admissions("192.0.2.9", attempts: 1, at: start + .seconds(1)) == 1)
  }

  @Test
  func `limits each client's in-flight requests and refuses unaffordable ones`() async throws {
    let limiter = AdmissionLimiter(settings: AdmissionSettings())
    let address = IPAddress("192.0.2.1")
    #expect(await limiter.admit(address, cost: 21).maximumCost == 20)
    let first = try #require(await limiter.admit(address, cost: 1).ticket)
    #expect(await limiter.admit(address, cost: 0).ticket != nil)
    #expect(await limiter.admit(address, cost: 0).ticket == nil)
    #expect(await limiter.admit(IPAddress("192.0.2.2"), cost: 1).ticket != nil)
    await limiter.release(first)
    #expect(await limiter.admit(address, cost: 1).ticket != nil)
  }

  @Test
  func `charges only tool calls against the client budget`() async throws {
    try await withApp { app in
      app.middleware.use(
        AdmissionMiddleware(
          limiter: AdmissionLimiter(
            settings: AdmissionSettings(
              client: AdmissionPolicy(
                rate: AdmissionRate(requestsPerMinute: 1, burst: 1), concurrency: 2))),
          clients: ClientAddressResolver(
            edgeIdentity: EdgeClientIdentity(secret: nil), trustFlyProxy: true)))
      `Isolated HTTP requests`.echoGateway().register(on: app)
      let toolCall = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo"}}"#
      let toolList = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
      let notification = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
      for (body, expected) in [
        (toolList, HTTPStatus.ok), (notification, .accepted), (toolCall, .ok), (toolList, .ok),
        (toolCall, .tooManyRequests)
      ] {
        try await app.testing().test(.POST, "/mcp") { request in
          request.headers = `Isolated HTTP requests`.headers
          request.headers.replaceOrAdd(name: "Fly-Client-IP", value: "2001:db8::1")
          request.body = ByteBuffer(string: body)
        } afterResponse: { response in
          #expect(response.status == expected)
        }
      }
    }
  }

  @Test
  func `rejects proxied requests that bypassed the edge`() async throws {
    try await withApp { app in
      app.middleware.use(
        EdgeGateMiddleware(
          identity: EdgeClientIdentity(secret: Self.secret), metrics: ServerMetrics()))
      app.get("health") { _ in "ok" }
      app.get("ready") { _ in "ready" }
      let unsigned = HTTPHeaders([("Fly-Client-IP", "192.0.2.1")])
      for (path, headers, expected) in [
        ("/ready", unsigned, HTTPStatus.forbidden), ("/health", unsigned, .ok),
        ("/ready", HTTPHeaders(), .ok), ("/ready", Self.signedHeaders(address: "192.0.2.1"), .ok)
      ] {
        try await app.testing().test(.GET, path, headers: headers) { response in
          #expect(response.status == expected)
        }
      }
    }
  }

  @Test
  func `refreshes database metrics after new tool calls and reports failures`() async throws {
    let loads = LoadCounter()
    let metrics = TrafficGatedMetrics { "loaded \(try await loads.increment())\n" }
    let start = ContinuousClock.now
    let reachable = "aviation_database_metrics_up 1\n"
    #expect(await metrics.render(afterCalls: 0, now: start).isEmpty)
    #expect(await metrics.render(afterCalls: 1, now: start) == "loaded 1\n" + reachable)
    #expect(
      await metrics.render(afterCalls: 2, now: start + .seconds(30)) == "loaded 1\n" + reachable)
    await loads.fail()
    let unreachable = "loaded 1\naviation_database_metrics_up 0\n"
    #expect(await metrics.render(afterCalls: 2, now: start + .seconds(61)) == unreachable)
    #expect(await metrics.render(afterCalls: 2, now: start + .seconds(90)) == unreachable)
    await loads.recover()
    #expect(
      await metrics.render(afterCalls: 2, now: start + .seconds(122)) == "loaded 2\n" + reachable)
    #expect(
      await metrics.render(afterCalls: 2, now: start + .seconds(600)) == "loaded 2\n" + reachable)
  }

  private static func signedHeaders(address: String) -> HTTPHeaders {
    let timestamp = String(Int(Date().timeIntervalSince1970))
    let signature = HMAC<SHA256>.authenticationCode(
      for: Data("\(timestamp)\n\(address)".utf8), using: SymmetricKey(data: Data(secret.utf8)))
    return HTTPHeaders([
      ("Fly-Client-IP", "198.51.100.1"), ("X-Aviation-Client-IP", address),
      ("X-Aviation-Client-Time", timestamp),
      ("X-Aviation-Client-Signature", Data(signature).base64EncodedString())
    ])
  }
}

private struct DatabaseUnreachable: Error {}

private actor LoadCounter {
  private var count = 0
  private var failing = false

  func increment() throws -> Int {
    guard !failing else { throw DatabaseUnreachable() }
    count += 1
    return count
  }

  func fail() { failing = true }
  func recover() { failing = false }
}

extension AdmissionDecision {
  fileprivate var ticket: AdmissionTicket? {
    guard case .admitted(let ticket) = self else { return nil }
    return ticket
  }

  fileprivate var maximumCost: Int? {
    guard case .exceedsCapacity(let cost) = self else { return nil }
    return cost
  }

  fileprivate var retryAfterSeconds: Int? {
    guard case .rateLimited(let seconds) = self else { return nil }
    return seconds
  }
}

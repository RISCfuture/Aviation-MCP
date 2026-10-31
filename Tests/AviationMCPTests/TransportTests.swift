import Crypto
import Foundation
import MCP
import Testing
import Vapor
import VaporTesting

@testable import AviationMCP

@Suite
struct `Isolated HTTP requests` {
  @Test
  func `trusts only fresh edge signatures bound to the client address`() {
    let identity = EdgeClientIdentity(secret: "terrain-proxy-test-secret-32-bytes")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var headers = HTTPHeaders([
      ("X-Aviation-Client-IP", "192.0.2.1"),
      ("X-Aviation-Client-Time", "1800000000"),
      ("X-Aviation-Client-Signature", "uLwsO1Ljka1wmuEc48hVEmpqDsxER7Yw67qSYGgsfss=")
    ])
    #expect(identity.verifiedIP(headers: headers, now: now) == "192.0.2.1")
    #expect(identity.verifiedIP(headers: headers, now: now.addingTimeInterval(61)) == nil)
    #expect(identity.verifiedIP(headers: headers, now: now.addingTimeInterval(-61)) == nil)
    #expect(EdgeClientIdentity(secret: nil).verifiedIP(headers: headers, now: now) == nil)
    headers.replaceOrAdd(name: "X-Aviation-Client-IP", value: "192.0.2.2")
    #expect(identity.verifiedIP(headers: headers, now: now) == nil)
    headers.replaceOrAdd(name: "X-Aviation-Client-Time", value: "nan")
    #expect(identity.verifiedIP(headers: headers, now: now) == nil)
  }

  @Test
  func `keeps concurrent calls with identical IDs isolated`() async throws {
    try await withApp { app in
      let gateway = MCPGateway(
        origins: ["https://aviation.example"],
        timeout: .seconds(2),
        tools: [
          Tool(name: "echo", description: "Echo an input", inputSchema: .object(["type": "object"]))
        ]
      ) { parameters in
        try await Task.sleep(for: .milliseconds(20))
        return CallTool.Result(content: [
          .text(
            text: parameters.arguments?["value"]?.stringValue ?? "missing",
            annotations: nil,
            _meta: nil
          )
        ])
      }
      gateway.register(on: app)
      try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<20 {
          group.addTask {
            try await app.testing().test(.POST, "/mcp") { request in
              request.headers = Self.headers
              request.body = ByteBuffer(
                string: """
                  {"jsonrpc":"2.0","id":1,"method":"tools/call",
                  "params":{"name":"echo","arguments":{"value":"client-\(index)"}}}
                  """
              )
            } afterResponse: { response in
              #expect(response.status == .ok)
              let payload = try JSONDecoder().decode(
                RPCReply.self,
                from: Data(response.body.readableBytesView)
              )
              #expect(payload.id == 1)
              #expect(payload.result.content.first?.text == "client-\(index)")
            }
          }
        }
        try await group.waitForAll()
      }
    }
  }

  @Test
  func `shows a tool error and the serialized result in text content`() async throws {
    let failure = ToolResult(
      results: [], completeness: "unavailable",
      error: .object([
        "code": "weather_unavailable", "reason": "No report covers the requested time.",
        "providers": [
          ["provider": "awc", "reason": "Budget exhausted.", "retryAt": "2026-10-31T09:00:00Z"]
        ]
      ]))
    try await withApp { app in
      MCPGateway(
        origins: ["https://aviation.example"], timeout: .seconds(2),
        tools: [Tool(name: "weather", description: "Weather", inputSchema: ["type": "object"])]
      ) { _ in try failure.response() }.register(on: app)
      try await app.testing().test(.POST, "/mcp") { request in
        request.headers = Self.headers
        request.body = ByteBuffer(
          string: """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"weather"}}
            """
        )
      } afterResponse: { response in
        let reply = try JSONDecoder().decode(
          RPCReply.self, from: Data(response.body.readableBytesView))
        let texts = reply.result.content.map(\.text)
        #expect(
          texts.first == """
            Error weather_unavailable: No report covers the requested time.
            awc: Budget exhausted. Retry after 2026-10-31T09:00:00Z.
            """)
        let serialized = try JSONDecoder().decode(Value.self, from: Data((texts.last ?? "").utf8))
        #expect(serialized.objectValue?["error"]?.objectValue?["code"] == "weather_unavailable")
      }
    }
  }

  @Test
  func `initializes without negotiating unsupported experimental capabilities`() async throws {
    try await withApp { app in
      MCPGateway(origins: [], timeout: .seconds(2), tools: []) { _ in
        CallTool.Result(content: [])
      }.register(on: app)
      try await app.testing().test(.POST, "/mcp") { request in
        request.headers = ["Content-Type": "application/json", "Accept": "application/json"]
        request.body = ByteBuffer(
          string: """
            {"jsonrpc":"2.0","id":"initialization","method":"initialize","params":{
              "protocolVersion":"2025-11-25","clientInfo":{"name":"review-client","version":"1"},
              "capabilities":{"experimental":{"example":{"enabled":true}},"roots":{"listChanged":true}}
            }}
            """
        )
      } afterResponse: { response in
        #expect(response.status == .ok)
        let reply = try JSONDecoder().decode(
          Value.self, from: Data(response.body.readableBytesView))
        #expect(reply.objectValue?["id"] == "initialization")
        #expect(reply.objectValue?["error"] == nil)
        let result = try #require(reply.objectValue?["result"]?.objectValue)
        #expect(result["protocolVersion"] == "2025-11-25")
        #expect(result["capabilities"]?.objectValue?["experimental"] == nil)
      }
    }
  }

  @Test
  func `validates origins protocol and request size`() async throws {
    try await withApp { app in
      MCPGateway(origins: ["https://aviation.example"], timeout: .seconds(2), tools: []) { _ in
        CallTool.Result(content: [])
      }.register(on: app)
      for (header, value, expected) in [
        ("Origin", "https://untrusted.example", HTTPStatus.forbidden),
        ("MCP-Protocol-Version", "invalid", HTTPStatus.badRequest)
      ] {
        try await app.testing().test(.POST, "/mcp") { request in
          request.headers = Self.headers
          request.headers.replaceOrAdd(name: header, value: value)
          request.body = ByteBuffer(
            string: """
              {"jsonrpc":"2.0","id":1,"method":"tools/list"}
              """
          )
        } afterResponse: { response in
          #expect(response.status == expected)
        }
      }
      try await app.testing().test(.POST, "/mcp") { request in
        request.headers = Self.headers
        request.body = ByteBuffer(string: String(repeating: "x", count: 1_048_577))
      } afterResponse: { response in
        #expect(response.status == .payloadTooLarge)
      }
    }
  }

  @Test
  func `answers JSON-RPC batches only in protocol versions that allow them`() async throws {
    try await withApp { app in
      Self.echoGateway().register(on: app)
      let batch = """
        [{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo",
          "arguments":{"value":"first"}}},
         {"jsonrpc":"2.0","method":"notifications/initialized"},
         {"jsonrpc":"2.0","id":2,"method":"tools/list"}]
        """
      try await app.testing().test(.POST, "/mcp") { request in
        request.headers = Self.headers
        request.headers.replaceOrAdd(name: "MCP-Protocol-Version", value: "2025-03-26")
        request.body = ByteBuffer(string: batch)
      } afterResponse: { response in
        #expect(response.status == .ok)
        let replies = try JSONDecoder().decode(
          [Value].self, from: Data(response.body.readableBytesView))
        #expect(replies.map { $0.objectValue?["id"] } == [1, 2])
        let content = replies.first?.objectValue?["result"]?.objectValue?["content"]?.arrayValue
        #expect(content?.first?.objectValue?["text"] == "first")
      }
      try await app.testing().test(.POST, "/mcp") { request in
        request.headers = Self.headers
        request.body = ByteBuffer(string: batch)
      } afterResponse: { response in
        #expect(response.status == .badRequest)
        let reply = try JSONDecoder().decode(
          Value.self, from: Data(response.body.readableBytesView))
        #expect(reply.objectValue?["error"]?.objectValue?["code"] == -32600)
      }
    }
  }

  @Test
  func `bounds a stalled tool call with a timeout`() async throws {
    try await withApp { app in
      MCPGateway(
        origins: ["https://aviation.example"],
        timeout: .milliseconds(50),
        tools: [
          Tool(name: "slow", description: "Slow tool", inputSchema: .object(["type": "object"]))
        ]
      ) { _ in
        try await Task.sleep(for: .seconds(60))
        return CallTool.Result(content: [])
      }.register(on: app)
      try await app.testing().test(.POST, "/mcp") { request in
        request.headers = Self.headers
        request.body = ByteBuffer(
          string: """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"slow"}}
            """
        )
      } afterResponse: { response in
        #expect(response.status == .gatewayTimeout)
      }
    }
  }

  static var headers: HTTPHeaders {
    [
      "Content-Type": "application/json", "Accept": "application/json",
      "MCP-Protocol-Version": "2025-06-18", "Origin": "https://aviation.example"
    ]
  }

  static func echoGateway() -> MCPGateway {
    MCPGateway(
      origins: ["https://aviation.example"],
      timeout: .seconds(2),
      tools: [
        Tool(name: "echo", description: "Echo an input", inputSchema: .object(["type": "object"]))
      ]
    ) { parameters in
      CallTool.Result(content: [
        .text(
          text: parameters.arguments?["value"]?.stringValue ?? "missing",
          annotations: nil,
          _meta: nil
        )
      ])
    }
  }

}

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
  func `limits each client's in-flight tool calls`() async throws {
    let limiter = AdmissionLimiter(settings: AdmissionSettings())
    let address = IPAddress("192.0.2.1")
    let first = try #require(await limiter.admit(address, cost: 1).ticket)
    #expect(await limiter.admit(address, cost: 1).ticket != nil)
    #expect(await limiter.admit(address, cost: 1).ticket == nil)
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
  func `refreshes database metrics only after new tool calls`() async throws {
    let loads = LoadCounter()
    let metrics = TrafficGatedMetrics { "loaded \(await loads.increment())" }
    let start = ContinuousClock.now
    #expect(try await metrics.render(afterCalls: 0, now: start).isEmpty)
    #expect(try await metrics.render(afterCalls: 1, now: start) == "loaded 1")
    #expect(try await metrics.render(afterCalls: 2, now: start + .seconds(30)) == "loaded 1")
    #expect(try await metrics.render(afterCalls: 2, now: start + .seconds(61)) == "loaded 2")
    #expect(try await metrics.render(afterCalls: 2, now: start + .seconds(600)) == "loaded 2")
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

private actor LoadCounter {
  private var count = 0

  func increment() -> Int {
    count += 1
    return count
  }
}

extension AdmissionDecision {
  fileprivate var ticket: AdmissionTicket? {
    guard case .admitted(let ticket) = self else { return nil }
    return ticket
  }

  fileprivate var retryAfterSeconds: Int? {
    guard case .rateLimited(let seconds) = self else { return nil }
    return seconds
  }
}

private struct RPCReply: Decodable {
  let id: Int
  let result: RPCResult

}

private struct RPCResult: Decodable {
  let content: [RPCText]
}

private struct RPCText: Decodable {
  let text: String
}

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

  private static var headers: HTTPHeaders {
    [
      "Content-Type": "application/json", "Accept": "application/json",
      "MCP-Protocol-Version": "2025-06-18", "Origin": "https://aviation.example"
    ]
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

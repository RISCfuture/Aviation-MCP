import Foundation
import MCP
import Vapor

/// Serves the stateless MCP Streamable HTTP endpoint, one isolated server per JSON-RPC message.
struct MCPGateway: Sendable {
  /// The largest request body accepted on `/mcp`.
  static let maximumBodyBytes = 1_048_576
  /// The most JSON-RPC messages one batch may hold.
  static let maximumBatchMessages = 10
  /// Protocol versions that permit JSON-RPC batches; a request without a version header uses
  /// 2025-03-26.
  private static let batchingProtocolVersions: Set<String> = ["2024-11-05", "2025-03-26"]
  private static let defaultProtocolVersion = "2025-03-26"
  /// Guidance sent to clients at initialization.
  private static let instructions = """
    U.S. aviation data from FAA sources. Airports take an FAA location identifier or ICAO code \
    (SFO or KSFO). Approaches use CIFP identifiers: I04R is ILS RWY 4R and R30-Y is RNAV (GPS) \
    Y RWY 30. Use find_* tools to list records and get_* tools for detail; when an identifier \
    is ambiguous, pass the record_id of one candidate. Every result names its source cycles \
    and completeness, and expired data is never returned: a source without an effective \
    release is reported as unavailable with the reason. Error text begins with the error code. \
    Not for operational navigation.
    """

  let origins: [String]
  let timeout: Duration
  let tools: [Tool]
  let call: @Sendable (CallTool.Parameters) async throws -> CallTool.Result

  func register(on app: Application) {
    let body = HTTPBodyStreamStrategy.collect(maxSize: ByteCount(value: Self.maximumBodyBytes))
    app.on(.POST, "mcp", body: body) { request async throws in try await respond(to: request) }
    for method in [HTTPMethod.GET, .DELETE] {
      app.on(method, "mcp") { _ async -> Vapor.Response in
        Vapor.Response(status: .methodNotAllowed, headers: ["Allow": "POST"])
      }
    }
  }

  private func respond(to request: Vapor.Request) async throws -> Vapor.Response {
    guard (request.body.data?.readableBytes ?? 0) <= Self.maximumBodyBytes else {
      throw Abort(.payloadTooLarge)
    }
    let envelope = Envelope(request)
    let deadline = ContinuousClock.now + timeout
    let body = request.body.data.map { Data($0.readableBytesView) }
    let response =
      if let body, let batch = try? JSONDecoder().decode([Value].self, from: body) {
        try await exchange(batch: batch, envelope: envelope, deadline: deadline)
      } else {
        try await exchange(body, envelope: envelope, deadline: deadline)
      }
    return Vapor.Response(
      status: .init(statusCode: response.statusCode),
      headers: HTTPHeaders(response.headers.map { ($0.key, $0.value) }),
      body: .init(data: response.bodyData ?? Data())
    )
  }

  private func exchange(batch items: [Value], envelope: Envelope, deadline: ContinuousClock.Instant)
    async throws -> MCP.HTTPResponse
  {
    if let rejection = batchRejection(items, envelope: envelope) { return rejection }
    var replies: [Value] = []
    for item in items {
      let response = try await exchange(
        try JSONEncoder().encode(item), envelope: envelope, deadline: deadline)
      switch response.statusCode {
      case 202: continue
      case 200, 400:
        guard let data = response.bodyData else { continue }
        replies.append(try JSONDecoder().decode(Value.self, from: data))
      default: return response
      }
    }
    guard !replies.isEmpty else { return .accepted() }
    return .data(
      try JSONEncoder().encode(replies), headers: [HTTPHeaderName.contentType: "application/json"])
  }

  private func batchRejection(_ items: [Value], envelope: Envelope) -> MCP.HTTPResponse? {
    let version = envelope.headers["mcp-protocol-version"] ?? Self.defaultProtocolVersion
    guard Self.batchingProtocolVersions.contains(version) else {
      return .error(
        statusCode: 400,
        .invalidRequest("JSON-RPC batches are not supported in protocol version \(version)"))
    }
    guard !items.isEmpty else {
      return .error(statusCode: 400, .invalidRequest("Batch array must not be empty"))
    }
    guard items.count <= Self.maximumBatchMessages else {
      return .error(
        statusCode: 400,
        .invalidRequest("A batch may hold at most \(Self.maximumBatchMessages) messages"))
    }
    guard !items.contains(where: { $0.objectValue?["method"] == "initialize" }) else {
      return .error(statusCode: 400, .invalidRequest("initialize must not be part of a batch"))
    }
    return nil
  }

  private func exchange(_ body: Data?, envelope: Envelope, deadline: ContinuousClock.Instant)
    async throws -> MCP.HTTPResponse
  {
    let remaining = ContinuousClock.now.duration(to: deadline)
    guard remaining > .zero else { throw Abort(.gatewayTimeout) }
    let transport = StatelessHTTPServerTransport(
      validationPipeline: StandardValidationPipeline(validators: [
        ExactOriginValidator(origins: origins),
        AcceptHeaderValidator(mode: .jsonOnly), ContentTypeValidator(), ProtocolVersionValidator()
      ])
    )
    let server = Server(
      name: "Aviation MCP",
      version: "0.1.0",
      instructions: Self.instructions,
      capabilities: .init(tools: .init())
    )
    let invocation = ToolInvocation(call: call)
    await server.withMethodHandler(ListTools.self) { _ in ListTools.Result(tools: tools) }
    await server.withMethodHandler(CallTool.self) { parameters in
      guard tools.contains(where: { $0.name == parameters.name }) else {
        throw MCPError.invalidParams("Unknown or disabled tool")
      }
      return try await invocation.execute(parameters)
    }
    try await server.start(transport: transport)
    let message = MCP.HTTPRequest(
      method: envelope.method, headers: envelope.headers,
      body: try body.map { try sdkRequestBody($0) }, path: envelope.path)
    do {
      let response = try await boundedResponse(
        message, transport: transport, invocation: invocation, timeout: remaining)
      await invocation.cancel()
      await server.stop()
      return response
    } catch {
      await invocation.cancel()
      await server.stop()
      throw error
    }
  }

  private func sdkRequestBody(_ data: Data) throws -> Data {
    guard var message = try? JSONDecoder().decode([String: Value].self, from: data),
      message["method"] == "initialize",
      var parameters = message["params"]?.objectValue,
      var capabilities = parameters["capabilities"]?.objectValue,
      capabilities["experimental"] != nil
    else { return data }
    // The SDK decodes experimental values as strings; this server implements no experimental features.
    capabilities.removeValue(forKey: "experimental")
    parameters["capabilities"] = .object(capabilities)
    message["params"] = .object(parameters)
    return try JSONEncoder().encode(message)
  }

  private func boundedResponse(
    _ request: MCP.HTTPRequest,
    transport: StatelessHTTPServerTransport,
    invocation: ToolInvocation,
    timeout: Duration
  ) async throws -> MCP.HTTPResponse {
    try await withTaskCancellationHandler {
      try await withThrowingTaskGroup(of: Outcome.self) { group in
        group.addTask { .response(await transport.handleRequest(request)) }
        group.addTask {
          try await Task.sleep(for: timeout)
          return .timedOut
        }
        let first = try await group.next()
        group.cancelAll()
        await invocation.cancel()
        await transport.disconnect()
        try Task.checkCancellation()
        guard case .response(let response) = first else { throw Abort(.gatewayTimeout) }
        return response
      }
    } onCancel: {
      Task {
        await invocation.cancel()
        await transport.disconnect()
      }
    }
  }

  private enum Outcome: Sendable {
    case response(MCP.HTTPResponse)
    case timedOut
  }

  /// The parts of the HTTP request every JSON-RPC message in it shares.
  private struct Envelope {
    let method: String
    let headers: [String: String]
    let path: String

    init(_ request: Vapor.Request) {
      method = request.method.rawValue
      headers = request.headers.reduce(into: [:]) { headers, field in
        headers[field.name.lowercased(), default: ""] +=
          (headers[field.name.lowercased()] == nil ? "" : ",") + field.value
      }
      path = request.url.path
    }
  }
}

private struct ExactOriginValidator: HTTPRequestValidator {
  let origins: [String]

  func validate(_ request: MCP.HTTPRequest, context: HTTPValidationContext) -> MCP.HTTPResponse? {
    guard let origin = request.header("Origin"), !origins.contains(origin) else { return nil }
    return .error(statusCode: 403, .invalidRequest("Origin is not allowed"))
  }
}

private actor ToolInvocation {
  let call: @Sendable (CallTool.Parameters) async throws -> CallTool.Result
  private var pending: Task<CallTool.Result, any Error>?
  private var cancelled = false

  init(call: @escaping @Sendable (CallTool.Parameters) async throws -> CallTool.Result) {
    self.call = call
  }

  func execute(_ parameters: CallTool.Parameters) async throws -> CallTool.Result {
    guard !cancelled else { throw CancellationError() }
    let task = Task { try await call(parameters) }
    pending = task
    return try await task.value
  }

  func cancel() {
    cancelled = true
    pending?.cancel()
    pending = nil
  }
}

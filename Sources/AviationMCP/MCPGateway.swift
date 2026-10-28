import Foundation
import MCP
import Vapor

struct MCPGateway: Sendable {
  let origins: [String]
  let timeout: Duration
  let tools: [Tool]
  let call: @Sendable (CallTool.Parameters) async throws -> CallTool.Result

  func register(on app: Application) {
    app.on(.POST, "mcp", body: .collect(maxSize: "1mb")) { request async throws in
      try await respond(to: request)
    }
    for method in [HTTPMethod.GET, .DELETE] {
      app.on(method, "mcp") { _ async -> Vapor.Response in
        Vapor.Response(status: .methodNotAllowed, headers: ["Allow": "POST"])
      }
    }
  }

  private func respond(to request: Vapor.Request) async throws -> Vapor.Response {
    guard (request.body.data?.readableBytes ?? 0) <= 1_048_576 else {
      throw Abort(.payloadTooLarge)
    }
    let transport = StatelessHTTPServerTransport(
      validationPipeline: StandardValidationPipeline(validators: [
        ExactOriginValidator(origins: origins),
        AcceptHeaderValidator(mode: .jsonOnly), ContentTypeValidator(), ProtocolVersionValidator()
      ])
    )
    let server = Server(
      name: "Aviation MCP",
      version: "0.1.0",
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
      method: request.method.rawValue,
      headers: request.headers.reduce(into: [:]) { headers, field in
        headers[field.name.lowercased(), default: ""] +=
          (headers[field.name.lowercased()] == nil ? "" : ",") + field.value
      },
      body: try request.body.data.map { try sdkRequestBody(Data($0.readableBytesView)) },
      path: request.url.path
    )
    do {
      let response = try await boundedResponse(
        message,
        transport: transport,
        invocation: invocation
      )
      await invocation.cancel()
      await server.stop()
      return Vapor.Response(
        status: .init(statusCode: response.statusCode),
        headers: HTTPHeaders(response.headers.map { ($0.key, $0.value) }),
        body: .init(data: response.bodyData ?? Data())
      )
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
    invocation: ToolInvocation
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

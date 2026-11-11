import Foundation
import MCP
import Vapor

/// The HTTP request and JSON-RPC message a tool call is running for, available to code the
/// gateway invokes.
struct ToolCallContext: Sendable {
  /// The context of the tool call running in the current task, if any.
  @TaskLocal static var current: ToolCallContext?

  /// The `Fly-Request-Id` header, which identifies the request in Fly's logs.
  let flyRequestID: String?
  /// The `id` of the JSON-RPC message being handled, if it has one.
  var jsonrpcID: String?
  /// The request's logger, carrying the Fly request ID as metadata.
  let logger: Logger
}

extension ToolCallContext {
  init(_ request: Vapor.Request) {
    let flyRequestID = request.headers.first(name: "Fly-Request-Id")
    var logger = request.logger
    flyRequestID.map { logger[metadataKey: "fly_request_id"] = .string($0) }
    self.init(flyRequestID: flyRequestID, logger: logger)
  }

  /// This context for the single JSON-RPC message `body`.
  func handling(_ body: Data?) -> ToolCallContext {
    var context = self
    context.jsonrpcID = body.flatMap(Self.messageID)
    return context
  }

  private static func messageID(_ body: Data) -> String? {
    switch (try? JSONDecoder().decode([String: Value].self, from: body))?["id"] {
    case .string(let id): id
    case .int(let id): String(id)
    default: nil
    }
  }
}

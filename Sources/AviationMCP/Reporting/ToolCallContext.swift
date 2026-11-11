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
  /// The most UTF-8 bytes of a JSON-RPC ID that logs and reports carry.
  static let jsonrpcIDLimit = 128

  /// The `id` of the JSON-RPC message being handled, without newlines or control characters and
  /// cut to ``jsonrpcIDLimit`` bytes; `nil` if nothing printable remains.
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
    context.jsonrpcID = body.flatMap(Self.messageID).flatMap(Self.printable)
    return context
  }

  private static func messageID(_ body: Data) -> String? {
    switch (try? JSONDecoder().decode([String: Value].self, from: body))?["id"] {
    case .string(let id): id
    case .int(let id): String(id)
    default: nil
    }
  }

  private static func printable(_ id: String) -> String? {
    let visible = id.filter { !$0.isNewline && !$0.unicodeScalars.contains(where: isControl) }
    guard !visible.isEmpty else { return nil }
    return ToolCallLog.truncated(visible, toBytes: jsonrpcIDLimit)
  }

  private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.generalCategory == .control
  }
}

import Vapor

/// The HTTP request a tool call is running for, available to code the gateway invokes.
struct ToolCallContext: Sendable {
  /// The context of the tool call running in the current task, if any.
  @TaskLocal static var current: ToolCallContext?

  /// The `Fly-Request-Id` header, which identifies the request in Fly's logs.
  let flyRequestID: String?
  /// The request's logger, carrying the Fly request ID as metadata.
  let logger: Logger

  init(_ request: Vapor.Request) {
    flyRequestID = request.headers.first(name: "Fly-Request-Id")
    var logger = request.logger
    flyRequestID.map { logger[metadataKey: "fly_request_id"] = .string($0) }
    self.logger = logger
  }
}

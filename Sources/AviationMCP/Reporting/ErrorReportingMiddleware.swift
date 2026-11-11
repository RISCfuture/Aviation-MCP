import Vapor

/// Reports defects that become HTTP 5xx responses and logs rejected requests.
struct ErrorReportingMiddleware: AsyncMiddleware {
  let reporter: any ErrorReporter

  func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
    let call = ToolCallContext(request)
    let response: Response
    do {
      response = try await next.respond(to: request)
    } catch {
      handle(error, for: request, call: call)
      throw error
    }
    if response.status.code >= 400 {
      call.logger.notice(
        "request rejected",
        metadata: ["status": "\(response.status.code)", "path": "\(request.url.path)"])
    }
    return response
  }

  private func handle(_ error: any Error, for request: Request, call: ToolCallContext) {
    let abort = error as? any AbortError
    let status = abort?.status ?? .internalServerError
    var metadata: Logger.Metadata = ["status": "\(status.code)", "path": "\(request.url.path)"]
    abort.map { metadata["reason"] = "\($0.reason)" }
    call.logger.notice("request rejected", metadata: metadata)
    if status.code >= 500 && DefectClassification.isDefect(error) {
      let context = ["path": request.url.path, "fly_request_id": call.flyRequestID]
      reporter.report(
        error, tags: ["status": "\(status.code)"], context: context.compactMapValues(\.self))
    }
  }
}

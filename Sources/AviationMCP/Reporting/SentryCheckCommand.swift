import Vapor

/// The error `sentry-check` reports to confirm delivery.
struct SentryCheckError: Error, CustomStringConvertible {
  var description: String { "Sentry check: deliberate handled event" }
}

/// Verifies error reporting by sending a handled event, or by crashing with `--trap`.
struct SentryCheckCommand: AsyncCommand {
  struct Signature: CommandSignature {
    @Flag(name: "trap", help: "Crash with a trap instead of reporting a handled error.")
    var trap: Bool
  }

  var help: String { "Send a deliberate test event to the error reporter." }

  func run(using context: CommandContext, signature: Signature) async throws {
    if signature.trap { Self.trap() }
    let reporter = context.application.errorReporter
    reporter.report(SentryCheckError(), tags: ["check": "sentry-check"], context: [:])
    reporter.close()
  }

  @inline(never)
  private static func trap() {
    let missing: Int? = nil
    _ = missing!
  }
}

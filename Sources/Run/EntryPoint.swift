import AviationMCP
import Dispatch
import Foundation
import Vapor

@main
struct EntryPoint {
  static func main() async throws {
    let app = try await Application.make(.detect())
    app.errorReporter = DisabledErrorReporter()
    let termination = terminateOnSIGTERM(app)
    do {
      try configure(app)
      try await app.execute()
    } catch let error as IncompleteReleaseError {
      app.logger.critical("\(error.failureReason ?? "Release withheld from publication.")")
      try await app.asyncShutdown()
      exit(IncompleteReleaseError.exitStatus)
    } catch {
      app.logger.critical("\(String(reflecting: error))")
      if DefectClassification.isDefect(error) {
        app.errorReporter.report(error, tags: ["fatal": "true"], context: [:])
      }
      app.errorReporter.close()
      try await app.asyncShutdown()
      exit(EXIT_FAILURE)
    }
    termination?.cancel()
    app.errorReporter.close()
    try await app.asyncShutdown()
  }

  /// Flushes the reporter and exits on SIGTERM; the `serve` command already shuts down gracefully.
  private static func terminateOnSIGTERM(_ app: Application) -> (any DispatchSourceSignal)? {
    guard Environment.appRole != "serve" else { return nil }
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    source.setEventHandler {
      app.errorReporter.close()
      exit(143)
    }
    source.resume()
    return source
  }
}

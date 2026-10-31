import AviationMCP
import Foundation
import Vapor

@main
struct EntryPoint {
  static func main() async throws {
    let app = try await Application.make(.detect())
    do {
      try configure(app)
      try await app.execute()
    } catch let error as IncompleteReleaseError {
      app.logger.critical("\(error.failureReason ?? "Release withheld from publication.")")
      try await app.asyncShutdown()
      exit(IncompleteReleaseError.exitStatus)
    } catch {
      try await app.asyncShutdown()
      throw error
    }
    try await app.asyncShutdown()
  }
}

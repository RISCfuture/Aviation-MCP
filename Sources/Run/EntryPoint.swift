import AviationMCP
import Vapor

@main
struct EntryPoint {
  static func main() async throws {
    let app = try await Application.make(.detect())
    do {
      try configure(app)
      try await app.execute()
    } catch {
      try await app.asyncShutdown()
      throw error
    }
    try await app.asyncShutdown()
  }
}

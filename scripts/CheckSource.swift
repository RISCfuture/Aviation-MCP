import Foundation

@main
enum CheckSource {
  static func main() async {
    do { try await run() } catch {
      FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
      exit(1)
    }
  }

  private static func run() async throws {
    guard CommandLine.arguments.count == 3 else {
      throw SourceDiscoveryError("Usage: check-source SOURCE OUTPUT.json")
    }
    let downloads = try await SourceChecks.check(CommandLine.arguments[1])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(downloads).write(
      to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
  }
}

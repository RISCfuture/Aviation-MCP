import Foundation
import MCP
import Vapor

/// The structured log line written for each tool call.
struct ToolCallLog {
  /// The most UTF-8 bytes of encoded arguments a log line carries.
  static let argumentLimit = 1024

  /// Metadata for one call: tool, outcome, completeness, duration_ms, result_count,
  /// fly_request_id and arguments (without any cursor).
  static func metadata(  // swiftlint:disable:this function_parameter_count
    tool: String, arguments: [String: Value]?, result: CallTool.Result?,
    error: (any Error)?, duration: Duration, requestID: String?
  ) -> Logger.Metadata {
    let content = result?.structuredContent?.objectValue
    let fields: [String: String?] = [
      "tool": tool,
      "outcome": outcome(result: content, error: error),
      "completeness": content?["completeness"]?.stringValue,
      "duration_ms": String(Int(duration / .milliseconds(1))),
      "result_count": content?["results"]?.arrayValue.map { String($0.count) },
      "fly_request_id": requestID,
      "arguments": loggedArguments(arguments)
    ]
    return fields.compactMapValues { $0.map { .string($0) } }
  }

  private static func outcome(result: [String: Value]?, error: (any Error)?) -> String {
    switch error {
    case is CancellationError: "cancelled"
    case .some: "protocol_error"
    case nil: result?["error"]?.objectValue?["code"]?.stringValue ?? "ok"
    }
  }

  private static func loggedArguments(_ arguments: [String: Value]?) -> String? {
    guard var arguments else { return nil }
    arguments.removeValue(forKey: "cursor")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let json = try? String(bytes: encoder.encode(arguments), encoding: .utf8) else {
      return nil
    }
    return truncated(json)
  }

  private static func truncated(_ text: String) -> String {
    guard text.utf8.count > argumentLimit else { return text }
    var kept = ""
    var bytes = 0
    for character in text {
      bytes += String(character).utf8.count
      guard bytes <= argumentLimit else { break }
      kept.append(character)
    }
    return kept + "…"
  }
}

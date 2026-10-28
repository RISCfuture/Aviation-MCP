import Foundation

actor ServerMetrics {
  private var calls: [String: Int] = [:]
  private var failures: [String: Int] = [:]
  private var durations: [String: Double] = [:]

  func record(tool: String, duration: Duration, failed: Bool) {
    calls[tool, default: 0] += 1
    failures[tool, default: 0] += failed ? 1 : 0
    durations[tool, default: 0] +=
      Double(duration.components.seconds)
      + Double(duration.components.attoseconds) / 1e18
  }

  func render() -> String {
    calls.keys.sorted().map { tool in
      """
      aviation_tool_calls_total{tool="\(tool)"} \(calls[tool, default: 0])
      aviation_tool_failures_total{tool="\(tool)"} \(failures[tool, default: 0])
      aviation_tool_duration_seconds_sum{tool="\(tool)"} \(durations[tool, default: 0])
      """
    }.joined(separator: "\n") + "\n"
  }
}

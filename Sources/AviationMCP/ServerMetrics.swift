import Foundation

/// In-process counters exported on `/metrics`.
actor ServerMetrics {
  private var calls: [String: Int] = [:]
  private var failures: [String: Int] = [:]
  private var durations: [String: Double] = [:]
  private var edgeRejections = 0

  /// The number of tool calls recorded since the process started.
  var totalCalls: Int { calls.values.reduce(0, +) }

  func record(tool: String, duration: Duration, failed: Bool) {
    calls[tool, default: 0] += 1
    failures[tool, default: 0] += failed ? 1 : 0
    durations[tool, default: 0] +=
      Double(duration.components.seconds)
      + Double(duration.components.attoseconds) / 1e18
  }

  func recordEdgeRejection() {
    edgeRejections += 1
  }

  func render() -> String {
    calls.keys.sorted().map { tool in
      """
      aviation_tool_calls_total{tool="\(tool)"} \(calls[tool, default: 0])
      aviation_tool_failures_total{tool="\(tool)"} \(failures[tool, default: 0])
      aviation_tool_duration_seconds_sum{tool="\(tool)"} \(durations[tool, default: 0])

      """
    }.joined() + "aviation_edge_rejections_total \(edgeRejections)\n"
  }
}

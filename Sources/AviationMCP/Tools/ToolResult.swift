import Foundation
import MCP

struct ToolResult: Codable, Sendable {
  var results: [Value]
  var sources: [SourceStamp] = []
  var completeness = "complete"
  var warnings: [String] = []
  var nextCursor: String?
  var retrievedAt = Date.now.ISO8601Format()
  var rateLimits: Value?
  var liveSources: [LiveSourceStamp] = []
  var error: Value?

  func response() throws -> CallTool.Result {
    var bounded = self
    bounded.results = try results.map(GeometryPayload.bounded)
    if bounded.results.contains(where: { $0.objectValue?["geometry_omitted"] == true }) {
      bounded.completeness = "partial"
      bounded.warnings.append(
        "Geometry exceeds the 32768-byte per-record limit; some geometry fields were omitted.")
    }
    return CallTool.Result(
      content: [
        .text(
          text: "\(bounded.results.count) result(s); completeness: \(bounded.completeness).",
          annotations: nil,
          _meta: nil)
      ],
      structuredContent: try .encoded(bounded), isError: error != nil
    )
  }
}

struct LiveSourceStamp: Codable, Sendable {
  let provider: String
  let retrievedAt: String
  var observationTime: String?
  var validFrom: String?
  var validUntil: String?
}

struct SourceStamp: Codable, Sendable {
  let source: String
  let cycle: String
  let effectiveFrom: String
  let effectiveUntil: String?
  let checksum: String
  let parserRevision: String
  let validation: [String: Value]?

  init(_ version: SourceVersion) {
    source = version.source.rawValue
    cycle = version.cycle
    effectiveFrom = version.effectiveFrom.ISO8601Format()
    effectiveUntil = version.effectiveUntil?.ISO8601Format()
    checksum = version.checksum
    parserRevision = version.parserRevision
    validation = version.validation
  }
}

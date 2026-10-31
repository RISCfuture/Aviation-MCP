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
    bounded.results = try results.map { try GeometryPayload.bounded($0.trimmingSinglePrecision) }
    if bounded.results.contains(where: { $0.objectValue?["geometry_omitted"] == true }) {
      bounded.completeness = "partial"
      bounded.warnings.append(
        "Geometry exceeds the 32768-byte per-record limit; some geometry fields were omitted.")
    }
    return CallTool.Result(
      content: try bounded.textContent(), structuredContent: try .encoded(bounded),
      isError: error != nil)
  }

  /// The result serialized as JSON text, preceded by a plain summary of any error, for clients
  /// that show the model only text content.
  private func textContent() throws -> [Tool.Content] {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    let json = String(bytes: try encoder.encode(self), encoding: .utf8)
    let summary = error.map(ToolErrorSummary.text)
    return [summary, json].compactMap { $0 }.map { .text(text: $0, annotations: nil, _meta: nil) }
  }
}

/// A one-line-per-cause description of a tool error: its code, message and any retry time.
enum ToolErrorSummary {
  static func text(_ error: Value) -> String {
    let fields = error.objectValue ?? [:]
    let code = fields["code"]?.stringValue ?? "error"
    let headline = "Error \(code): \(message(fields) ?? "The request could not be completed.")"
    let causes = (fields["providers"]?.arrayValue ?? []).compactMap(\.objectValue).map(cause)
    return ([headline + retry(fields)] + causes).joined(separator: "\n")
  }

  private static func message(_ fields: [String: Value]) -> String? {
    (fields["message"] ?? fields["reason"])?.stringValue
  }

  private static func cause(_ provider: [String: Value]) -> String {
    let name = provider["provider"]?.stringValue ?? "provider"
    return "\(name): \(message(provider) ?? "unavailable")" + retry(provider)
  }

  private static func retry(_ fields: [String: Value]) -> String {
    fields["retryAt"]?.stringValue.map { " Retry after \($0)." } ?? ""
  }
}

struct LiveSourceStamp: Codable, Sendable {
  let provider: String
  let retrievedAt: String
  var observationTime: String?
  var validFrom: String?
  var validUntil: String?
}

/// The source cycle a result was drawn from; get_data_status reports the full provenance.
struct SourceStamp: Codable, Sendable {
  let source: String
  let cycle: String
  let effectiveFrom: String
  let effectiveUntil: String?

  init(_ version: SourceVersion) {
    source = version.source.rawValue
    cycle = version.cycle
    effectiveFrom = version.effectiveFrom.ISO8601Format()
    effectiveUntil = version.effectiveUntil?.ISO8601Format()
  }
}

/// A source version's full provenance and validation detail.
struct SourceProvenance: Codable, Sendable {
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

extension Value {
  /// The value with every fractional double that is exactly a `Float` replaced by that
  /// `Float`'s shortest decimal, so single-precision source values read as published.
  var trimmingSinglePrecision: Self {
    switch self {
    case .double(let number): .double(Self.shortestSinglePrecision(number))
    case .array(let values): .array(values.map(\.trimmingSinglePrecision))
    case .object(let fields): .object(fields.mapValues(\.trimmingSinglePrecision))
    default: self
    }
  }

  private static func shortestSinglePrecision(_ number: Double) -> Double {
    guard number.isFinite, number != number.rounded(), let single = Float(exactly: number) else {
      return number
    }
    return Double(single.description) ?? number
  }
}

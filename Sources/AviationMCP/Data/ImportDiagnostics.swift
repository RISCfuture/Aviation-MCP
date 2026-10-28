import Foundation
import MCP

struct ImportDiagnostics: Sendable {
  private static let sampleLimit = 100
  private(set) var count = 0
  private var samples: [Value] = []

  var validation: [String: Value] {
    [
      "outcome": count == 0 ? "validated" : "partial",
      "parse_errors": .object([
        "count": .int(count), "samples": .array(samples),
        "samples_truncated": .bool(count > samples.count)
      ])
    ]
  }

  @discardableResult
  mutating func record(
    _ error: any Error, kind: String? = nil, recordID: String? = nil,
    line: Int? = nil, details: [String: Value] = [:]
  ) -> Value {
    let reason = (error as? any LocalizedError)?.failureReason ?? String(describing: error)
    var fields = details
    fields["message"] = .string(String(reason.prefix(2048)))
    fields["kind"] = kind.map(Value.string)
    fields["record_id"] = recordID.map(Value.string)
    fields["line"] = line.map(Value.int)
    let diagnostic = Value.object(fields)
    count += 1
    if samples.count < Self.sampleLimit { samples.append(diagnostic) }
    return diagnostic
  }

  mutating func recover<Input>(
    _ inputs: [Input], kind: String, identifier: KeyPath<Input, String>,
    transform: (Input) throws -> AviationRecord
  ) -> [AviationRecord] {
    inputs.compactMap { input in
      do { return try transform(input) } catch {
        record(
          error, kind: kind, recordID: input[keyPath: identifier],
          details: ["phase": "normalization"])
        return nil
      }
    }
  }
}

extension SourceVersion {
  var parseErrorCount: Int {
    validation?["parse_errors"]?.objectValue?["count"]?.intValue ?? 0
  }

  var coverageWarnings: [String] {
    guard parseErrorCount > 0 else { return [] }
    return [
      "\(source.rawValue) cycle \(cycle) has \(parseErrorCount) source parsing errors. "
        + "Records or fields may be missing; consult sources.validation.parse_errors for locations and diagnostics."
    ]
  }
}

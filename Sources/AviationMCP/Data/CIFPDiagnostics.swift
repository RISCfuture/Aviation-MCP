import Foundation
import MCP
import SwiftCIFP

struct CIFPDiagnostics {
  var errors = ImportDiagnostics()
  private var procedures: [String: [Value]] = [:]

  mutating func record(_ error: any Error, line: Int?, sourceLine: Substring?) {
    let bytes = sourceLine.map { Array($0.utf8) } ?? []
    let procedure =
      bytes.count >= 19 && bytes[4] == UInt8(ascii: "P")
      && "DEF".utf8.contains(bytes[12])
    let identity: String?
    if procedure {
      identity = Self.field(bytes[6..<10]) + "/" + Self.field(bytes[13..<19])
    } else if let error = error as? CIFPError,
      case .aggregationError(_, let identifier, _) = error
    {
      identity = identifier
    } else {
      identity = nil
    }
    let diagnostic = errors.record(
      error, kind: procedure ? "procedure" : nil, recordID: identity, line: line,
      details: [
        "phase": line == nil ? "aggregation" : "record",
        "source_excerpt": sourceLine.map { .string(String($0.prefix(160))) } ?? .null
      ])
    if procedure, let identity { procedures[identity, default: []].append(diagnostic) }
  }

  private static func field(_ bytes: ArraySlice<UInt8>) -> String {
    (String(bytes: bytes, encoding: .ascii) ?? "").trimmingCharacters(in: .whitespaces)
  }

  func applying(to records: [AviationRecord]) -> [AviationRecord] {
    records.map { original in
      guard original.kind == "procedure", let airport = original.airport,
        let issues = procedures[airport + "/" + original.identifier]
      else { return original }
      var record = original
      record.data["source_warnings"] = .array(issues)
      record.geometry = nil
      record.data["missed_approach_geometry"] = nil
      record.data["geometry_scope"] = "unavailable_due_to_parse_errors"
      record.data["geometry_gaps"] = .array(
        (record.data["geometry_gaps"]?.arrayValue ?? []) + issues)
      return record
    }
  }
}

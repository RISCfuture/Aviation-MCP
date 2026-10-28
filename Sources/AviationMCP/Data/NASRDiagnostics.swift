import Foundation
import MCP
import SwiftNASR

struct NASRDiagnostics: Sendable {
  private var failures: [String] = []
  private var warnings: [String: [Value]] = [:]

  mutating func record(_ error: RecordParseError) {
    if case .fieldError(let type, let id?, let field, let value, _) = error,
      let kind = Self.optionalClassification(type: type, field: field)
    {
      warnings[kind + "/" + id, default: []].append(
        Normalization.object([
          "field": .string(field), "source_value": value.map(Value.string),
          "reason": "Source value is not represented by the parser; no replacement was inferred."
        ]))
    } else if failures.count < 20 {
      failures.append(error.localizedDescription)
    }
  }

  private static func optionalClassification(type: RecordType, field: String) -> String? {
    if type == .airports,
      field == "agreements" || (field.hasPrefix("runway[") && field.hasSuffix("].materials"))
    {
      return "airport"
    }
    if type == .holds, field == "navaidFacilityType" { return "hold" }
    return nil
  }

  func applying(to records: [AviationRecord]) throws -> [AviationRecord] {
    guard failures.isEmpty else {
      throw StorageError.invalidImport(failures.joined(separator: "; "))
    }
    let recordIDs = Set(records.map(Self.sourceKey))
    guard Set(warnings.keys).isSubset(of: recordIDs) else {
      throw StorageError.invalidImport(
        "NASR diagnostics cannot be attached to their source records.")
    }
    return records.map { original in
      guard let issues = warnings[Self.sourceKey(original)] else { return original }
      var record = original
      record.data["source_warnings"] = .array(issues)
      record.supplemental["parser_diagnostics"] = .array(issues)
      if let runways = record.data["runways"]?.arrayValue {
        record.data["runways"] = .array(
          runways.map { runway in
            guard var fields = runway.objectValue,
              let identifier = fields["identifier"]?.stringValue,
              issues.contains(where: {
                $0.objectValue?["field"] == .string("runway[\(identifier)].materials")
              })
            else { return runway }
            fields["paved"] = .null
            return .object(fields)
          })
      }
      return record
    }
  }
  private static func sourceKey(_ record: AviationRecord) -> String {
    record.kind + "/" + (record.data["source_record_id"]?.stringValue ?? record.id)
  }
}

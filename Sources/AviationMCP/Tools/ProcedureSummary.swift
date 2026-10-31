import MCP

/// The compact form of a procedure segment that find_procedures returns; get_procedure returns
/// its legs and restrictions.
enum ProcedureSummary {
  private static let fields = [
    "id", "record_kind", "identifier", "name", "airport", "procedure_type", "approach_name",
    "approach_type", "runways", "transition", "route_type", "navigation_requirement", "landing",
    "source_warnings"
  ]

  static func summary(_ record: Value) -> Value {
    let source = record.objectValue ?? [:]
    var summary = source.filter { fields.contains($0.key) }
    summary["fixes"] = .array(
      (source["legs"]?.arrayValue ?? []).compactMap { $0.objectValue?["fix"] })
    return .object(summary)
  }
}

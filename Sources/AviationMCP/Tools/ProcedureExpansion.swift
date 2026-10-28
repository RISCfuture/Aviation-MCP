import MCP

enum ProcedureExpansion {
  static func apply(
    _ result: ToolResult, transition: String?, isContinuation: Bool = false
  ) throws -> ToolResult {
    if result.nextCursor != nil || isContinuation {
      var candidates = result
      candidates.completeness = "partial"
      candidates.warnings.append(
        "Procedure segments span multiple pages; expansion is unavailable on a partial page. "
          + "Narrow the airport, procedure type or transition, or increase the result limit.")
      return candidates
    }
    let groups = Dictionary(grouping: result.results) { value in
      ["airport", "identifier", "procedure_type"].map { value.objectValue?[$0]?.stringValue ?? "" }
        .joined(separator: "/")
    }
    var expanded = result
    expanded.results = []
    for key in groups.keys.sorted() {
      let records = groups[key] ?? []
      let common = records.filter {
        $0.objectValue?["transition"] == nil || $0.objectValue?["transition"] == .null
      }
      let transitions = records.filter {
        $0.objectValue?["transition"]?.stringValue?.uppercased() == transition?.uppercased()
          && transition != nil
      }
      if common.count > 1 || transitions.count > 1 {
        expanded.results += records
        expanded.warnings.append(
          "Multiple route variants match; the returned records are candidates, not an inferred expansion."
        )
        continue
      }
      if let transition, transitions.isEmpty {
        throw StorageError.invalidImport("Transition \(transition) was not found for \(key).")
      }
      guard let base = common.first ?? transitions.first else {
        expanded.results += records
        expanded.warnings.append(
          "No common route is published; select a transition from the candidates.")
        continue
      }
      expanded.results.append(
        merge(base: base, transition: transitions.first, commonExists: !common.isEmpty))
    }
    if !expanded.warnings.isEmpty { expanded.completeness = "partial" }
    return expanded
  }

  private static func merge(base: Value, transition: Value?, commonExists: Bool) -> Value {
    var fields = base.objectValue ?? [:]
    var segments = [base]
    if commonExists, let transition {
      let name = transition.objectValue?["transition"]?.stringValue ?? ""
      let runway = name.uppercased().hasPrefix("RW") || name.uppercased() == "ALL"
      let type = fields["procedure_type"]?.stringValue
      let transitionFirst = type == "departure" ? runway : type == "arrival" ? !runway : true
      segments = transitionFirst ? [transition, base] : [base, transition]
    }
    var legs: [Value] = []
    var boundaries: [Value] = []
    var gaps: [Value] = []
    for segment in segments {
      let source = segment.objectValue ?? [:]
      let id = source["id"] ?? .null
      boundaries.append(
        .object([
          "index": .int(legs.count), "source_id": id,
          "transition": source["transition"] ?? .null
        ]))
      legs += (source["legs"]?.arrayValue ?? []).map { leg in
        var value = leg.objectValue ?? [:]
        value["source_segment_id"] = id
        return .object(value)
      }
      gaps += source["geometry_gaps"]?.arrayValue ?? []
    }
    fields["expanded_legs"] = .array(legs)
    fields["transition_boundaries"] = .array(Array(boundaries.dropFirst()))
    fields["geometry_gaps"] = .array(gaps)
    fields["selected_transition"] = transition?.objectValue?["transition"]
    fields["source_segment_ids"] = .array(segments.compactMap { $0.objectValue?["id"] })
    fields.removeValue(forKey: "geometry")
    fields["geometry_status"] = "consult_each_source_segment"
    return .object(fields)
  }
}

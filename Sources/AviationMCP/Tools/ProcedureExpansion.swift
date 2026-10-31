import MCP

enum ProcedureExpansion {
  static func apply(
    _ result: ToolResult, transition: String?, includeGeometry: Bool = false
  ) throws -> ToolResult {
    if result.nextCursor != nil {
      var candidates = result
      candidates.completeness = "partial"
      candidates.warnings.append(
        "Procedure segments span multiple pages; expansion is unavailable on a partial page. "
          + "Narrow the airport or procedure type, or increase the result limit.")
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
      let common = records.filter { name(of: $0) == nil }
      let transitions = records.filter {
        transition != nil && name(of: $0)?.uppercased() == transition?.uppercased()
      }
      if common.count > 1 || transitions.count > 1 {
        expanded.results += records
        expanded.warnings.append(
          "Multiple route variants match; the returned records are candidates, not an inferred expansion."
        )
        continue
      }
      if let transition, transitions.isEmpty {
        throw ToolInputError(reason: missingTransition(transition, procedure: key, in: records))
      }
      guard let base = common.first ?? transitions.first else {
        expanded.results += records
        expanded.warnings.append(
          "No common route is published; select a transition from the candidates.")
        continue
      }
      var procedure = merge(
        base: base, transition: transitions.first, commonExists: !common.isEmpty,
        includeGeometry: includeGeometry)
      procedure["available_transitions"] = .array(available(records))
      expanded.results.append(.object(procedure))
    }
    if !expanded.warnings.isEmpty { expanded.completeness = "partial" }
    return expanded
  }

  private static func name(of record: Value) -> String? {
    record.objectValue?["transition"]?.stringValue
  }

  /// Each published transition with the fix it starts at and that fix's altitude restriction.
  private static func available(_ records: [Value]) -> [Value] {
    records.compactMap { record in name(of: record).map { (name: $0, record: record) } }
      .sorted { $0.name < $1.name }
      .map { name, record in
        let first = record.objectValue?["legs"]?.arrayValue?.first?.objectValue
        return Normalization.object([
          "name": .string(name), "initial_fix": first?["fix"],
          "initial_altitude_constraint": first?["altitude_constraint"]
        ])
      }
  }

  private static func missingTransition(
    _ transition: String, procedure: String, in records: [Value]
  ) -> String {
    let names = records.compactMap(name(of:)).sorted()
    let choices =
      names.isEmpty
      ? "This procedure publishes no transitions; omit transition."
      : "Available transitions: \(names.joined(separator: ", "))."
    return "Transition \(transition) was not found for \(procedure). \(choices)"
  }

  private static func merge(
    base: Value, transition: Value?, commonExists: Bool, includeGeometry: Bool
  ) -> [String: Value] {
    var fields = base.objectValue ?? [:]
    var segments = [base]
    if commonExists, let transition {
      let name = name(of: transition) ?? ""
      let runway = name.uppercased().hasPrefix("RW") || name.uppercased() == "ALL"
      let type = fields["procedure_type"]?.stringValue
      let transitionFirst = type == "departure" ? runway : type == "arrival" ? !runway : true
      segments = transitionFirst ? [transition, base] : [base, transition]
    }
    var legs: [Value] = []
    var boundaries: [Value] = []
    for segment in segments {
      let source = segment.objectValue ?? [:]
      let id = source["id"] ?? .null
      boundaries.append(
        .object([
          "index": .int(legs.count), "source_id": id, "transition": source["transition"] ?? .null
        ]))
      legs += (source["legs"]?.arrayValue ?? []).map { leg in
        var value = leg.objectValue ?? [:]
        value["source_segment_id"] = id
        return .object(value)
      }
    }
    fields["legs"] = .array(legs)
    fields["transition_boundaries"] = .array(Array(boundaries.dropFirst()))
    fields["selected_transition"] = transition.flatMap(name(of:)).map(Value.string)
    fields["source_segment_ids"] = .array(segments.compactMap { $0.objectValue?["id"] })
    fields.removeValue(forKey: "transition")
    fields.removeValue(forKey: "geometry")
    if includeGeometry { fields.merge(geometry(segments)) { _, merged in merged } }
    return fields
  }

  /// The segments' determinable paths combined into one MultiLineString, with their gaps.
  private static func geometry(_ segments: [Value]) -> [String: Value] {
    let records = segments.compactMap(\.objectValue)
    let lines = records.flatMap { $0["geometry"]?.objectValue?["coordinates"]?.arrayValue ?? [] }
    var fields: [String: Value] = [
      "geometry_gaps": .array(records.flatMap { $0["geometry_gaps"]?.arrayValue ?? [] })
    ]
    if !lines.isEmpty {
      fields["geometry"] = .object(["type": "MultiLineString", "coordinates": .array(lines)])
    }
    return fields
  }
}

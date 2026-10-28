import MCP

enum AirwayExpansion {
  static func apply(_ result: ToolResult, arguments: ToolArguments) throws -> ToolResult {
    let entry = try arguments.string("entry_fix")?.uppercased()
    let exit = try arguments.string("exit_fix")?.uppercased()
    guard (entry == nil) == (exit == nil) else {
      throw MCPError.invalidParams("Supply both entry_fix and exit_fix")
    }
    guard let entry, let exit else { return result }
    var expanded = result
    expanded.results = try result.results.compactMap { value -> Value? in
      guard var fields = value.objectValue, let segments = fields["segments"]?.arrayValue else {
        throw StorageError.invalidImport("Airway segment coverage is unavailable.")
      }
      let starts = segments.indices.filter {
        segments[$0].objectValue?["identifier"]?.stringValue?.uppercased() == entry
      }
      let ends = segments.indices.filter {
        segments[$0].objectValue?["identifier"]?.stringValue?.uppercased() == exit
      }
      guard !starts.isEmpty, !ends.isEmpty else {
        return nil
      }
      if starts.count > 1 || ends.count > 1 {
        fields["entry_candidates"] = .array(starts.map { segments[$0] })
        fields["exit_candidates"] = .array(ends.map { segments[$0] })
        expanded.warnings.append(
          "An airway fix identifier is ambiguous; inspect its candidate positions and sequences.")
      } else {
        let start = starts[0]
        let end = ends[0]
        let portion = Array(segments[min(start, end)...max(start, end)])
        fields["segments"] = .array(start > end ? portion.reversed() : portion)
        fields["reversed"] = .bool(start > end)
        fields["segment_field_reference"] = .string(
          "Fields describe the next segment in published order; "
            + "in reverse traversal this is the previous result point.")
        let path = AirwayGeometry.path(portion)
        fields["geometry"] =
          fields["geometry_scope"] == "unavailable_due_to_parse_errors" ? nil : path.geometry
        fields["geometry_gap_sequences"] = .array(path.gaps)
        expanded.warnings += warnings(for: portion, gaps: path.gaps)
      }
      return .object(fields)
    }
    guard !expanded.results.isEmpty else {
      throw StorageError.invalidImport(
        "No airway candidate contains both requested endpoint fixes.")
    }
    if !expanded.warnings.isEmpty { expanded.completeness = "partial" }
    return expanded
  }

  private static func warnings(for portion: [Value], gaps: [Value]) -> [String] {
    var warnings = gaps.isEmpty ? [] : ["Geometry is incomplete for this airway portion."]
    if portion.dropLast().contains(where: {
      $0.objectValue?["airway_gap"] == true || $0.objectValue?["mea_unusable"] == true
    }) {
      warnings.append(
        "This airway portion includes a published gap or unusable segment; it is not a continuous usable route."
      )
    }
    return warnings
  }
}

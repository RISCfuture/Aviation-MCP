import MCP

extension SourceVersion {
  /// Warnings for parse errors that may have dropped records of the requested kinds.
  ///
  /// Field-level errors leave their record in place and mark it with `source_warnings`, so
  /// they don't affect results that don't include that record. Errors for other kinds don't
  /// affect these results at all. Errors without a kind, and those beyond the stored samples,
  /// can't be attributed and are reported as possibly affecting any kind.
  func omissionWarnings(for kinds: [String]) -> [String] {
    guard parseErrorCount > 0 else { return [] }
    let omissions = parseErrorSamples.filter { $0["field"] == nil }
    var warnings = kinds.compactMap { kind -> String? in
      let count = omissions.count { $0["kind"]?.stringValue == kind }
      guard count > 0 else { return nil }
      return "\(source.rawValue) cycle \(cycle): \(count) \(kind) source record(s) could not be "
        + "parsed and may be missing from these results; get_data_status lists the parse errors."
    }
    let unattributed =
      parseErrorCount - parseErrorSamples.count + omissions.count { $0["kind"] == nil }
    if unattributed > 0 {
      warnings.append(
        "\(source.rawValue) cycle \(cycle) has \(unattributed) parse error(s) not attributed to a "
          + "record kind; matching records may be missing. get_data_status lists the parse errors.")
    }
    return warnings
  }

  private var parseErrorSamples: [[String: Value]] {
    validation?["parse_errors"]?.objectValue?["samples"]?.arrayValue?.compactMap(\.objectValue)
      ?? []
  }
}

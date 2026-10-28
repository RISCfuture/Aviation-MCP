import MCP

struct AirwayGeometry {
  private let navigation: [String: [AviationRecord]]

  init(navigation: [AviationRecord]) {
    self.navigation = Dictionary(grouping: navigation, by: \.identifier)
  }

  func resolve(_ record: AviationRecord) -> AviationRecord {
    var result = record
    let segments = (record.data["segments"]?.arrayValue ?? []).map(resolvePoint)
    let path = Self.path(segments)
    result.geometry = path.geometry
    result.data["segments"] = .array(segments)
    result.data["geometry_gap_sequences"] = .array(path.gaps)
    return result
  }

  static func path(_ segments: [Value]) -> (geometry: Value?, gaps: [Value]) {
    var lines: [Value] = []
    var gaps: [Value] = []
    for (start, end) in zip(segments, segments.dropFirst()) {
      let fields = start.objectValue ?? [:]
      if fields["airway_gap"] != true,
        let first = fields["position"]?.objectValue?["coordinates"],
        let last = end.objectValue?["position"]?.objectValue?["coordinates"]
      {
        lines.append(.array([first, last]))
      } else {
        gaps.append(fields["sequence"] ?? .null)
      }
    }
    return (
      lines.isEmpty ? nil : .object(["type": "MultiLineString", "coordinates": .array(lines)]),
      gaps
    )
  }

  private func resolvePoint(_ value: Value) -> Value {
    guard var fields = value.objectValue, fields["position"] == nil,
      let identifier = fields["identifier"]?.stringValue
    else { return value }
    let candidates = (navigation[identifier] ?? []).filter { candidate in
      if let type = fields["point_type"]?.stringValue,
        ["VOR/DME", "VORTAC", "NDB/DME", "NDB", "VOR", "DME", "TACAN"].contains(type)
      {
        return candidate.kind == "navaid" && candidate.data["facility_type"]?.stringValue == type
      }
      guard candidate.kind == "fix" else { return false }
      if let region = fields["icao_region"] {
        return candidate.data["icao_region"] == region
      }
      return true
    }
    let positions = candidates.compactMap(\.geometry).reduce(into: [Value]()) { values, point in
      if !values.contains(point) { values.append(point) }
    }
    if positions.count == 1 {
      fields["position"] = positions[0]
      fields["position_source_ids"] = .array(candidates.map { .string($0.id) })
    } else if positions.count > 1 {
      fields["position_candidates"] = .array(
        candidates.map {
          Normalization.object(["id": .string($0.id), "position": $0.geometry])
        })
    }
    return .object(fields)
  }
}

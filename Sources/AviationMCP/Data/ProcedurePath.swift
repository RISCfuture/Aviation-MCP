import MCP
import SwiftCIFP

struct ProcedurePath {
  private(set) var segments: [Value] = []
  private(set) var gaps: [Value] = []
  private var previous: Coordinate?

  var geometry: Value? {
    segments.isEmpty ? nil : .object(["type": "MultiLineString", "coordinates": .array(segments)])
  }

  mutating func append(sequence: Int, terminator: String?, coordinate: Coordinate?) {
    defer { previous = ["IF", "TF"].contains(terminator) ? coordinate : nil }
    if terminator == "IF", coordinate != nil { return }
    if terminator == "TF", let previous, let coordinate {
      segments.append(.array([Self.position(previous), Self.position(coordinate)]))
      return
    }
    let reason =
      coordinate == nil
      ? "unresolved_fix_or_endpoint"
      : terminator == "TF" ? "unresolved_previous_endpoint" : "unsupported_or_conditional_path"
    gaps.append(
      .object([
        "sequence": .int(sequence), "path_terminator": terminator.map(Value.string) ?? .null,
        "reason": .string(reason)
      ]))
  }

  private static func position(_ coordinate: Coordinate) -> Value {
    .array([.double(coordinate.longitudeDeg), .double(coordinate.latitudeDeg)])
  }
}

import Foundation
import MCP

struct GeometryPayload {
  private var remainingBytes = 32_768
  private var omitted = false

  static func bounded(_ record: Value) throws -> Value {
    var budget = Self()
    let result = try budget.visit(record)
    guard budget.omitted, var fields = result?.objectValue else { return result ?? .null }
    fields["geometry_omitted"] = true
    return .object(fields)
  }

  private mutating func visit(_ value: Value) throws -> Value? {
    switch value {
    case .object(let fields):
      if fields["type"]?.stringValue != nil,
        fields["coordinates"] != nil || fields["geometries"] != nil
      {
        let bytes = try JSONEncoder().encode(value).count
        guard bytes <= remainingBytes else {
          omitted = true
          return nil
        }
        remainingBytes -= bytes
        return value
      }
      var bounded: [String: Value] = [:]
      for key in fields.keys.sorted() {
        bounded[key] = try fields[key].flatMap { try visit($0) }
      }
      return .object(bounded)
    case .array(let values):
      return try .array(values.map { try visit($0) ?? .null })
    default:
      return value
    }
  }
}

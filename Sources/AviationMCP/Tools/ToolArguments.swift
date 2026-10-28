import Foundation
import MCP

struct ToolArguments: Sendable {
  let values: [String: Value]

  init(_ values: [String: Value]? = nil) {
    self.values = values ?? [:]
  }

  func string(_ name: String, required: Bool = false) throws -> String? {
    guard let value = values[name] else {
      if required { throw MCPError.invalidParams("Missing \(name)") }
      return nil
    }
    guard let text = value.stringValue, !text.isEmpty, text.utf8.count <= 16_384 else {
      throw MCPError.invalidParams("\(name) must be a nonempty bounded string")
    }
    return text
  }

  func number(_ name: String, default fallback: Double? = nil, range: ClosedRange<Double>) throws
    -> Double?
  {
    guard let value = values[name] else { return fallback }
    let number = value.doubleValue ?? value.intValue.map(Double.init)
    guard let number, number.isFinite, range.contains(number) else {
      throw MCPError.invalidParams("\(name) is outside its supported range")
    }
    return number
  }

  func instant(_ name: String, default fallback: Date? = nil) throws -> Date? {
    guard let text = try string(name) else { return fallback }
    guard let date = ISO8601DateFormatter().date(from: text) else {
      throw MCPError.invalidParams("\(name) must be an ISO 8601 date with a timezone")
    }
    return date
  }

  func limit() throws -> Int {
    let value = try number("limit", default: 50, range: 1...200) ?? 50
    guard value.rounded() == value else { throw MCPError.invalidParams("limit must be an integer") }
    return Int(value)
  }

  func boolean(_ name: String) throws -> Bool? {
    guard let raw = values[name] else { return nil }
    guard let value = raw.boolValue else {
      throw MCPError.invalidParams("\(name) must be a boolean")
    }
    return value
  }

  func coordinate() throws -> (latitude: Double, longitude: Double)? {
    let latitude = try number("latitude", range: -90...90)
    let longitude = try number("longitude", range: -180...180)
    if latitude == nil && longitude == nil { return nil }
    guard let latitude, let longitude else {
      throw MCPError.invalidParams("Both latitude and longitude are required")
    }
    return (latitude, longitude)
  }

  func strings(_ name: String) throws -> [String]? {
    guard let raw = values[name] else { return nil }
    guard let array = raw.arrayValue, array.count <= 20 else {
      throw MCPError.invalidParams("\(name) must be a bounded array")
    }
    return try array.map {
      guard let value = $0.stringValue else {
        throw MCPError.invalidParams("\(name) must contain strings")
      }
      return value
    }
  }
}

extension Value {
  static func encoded(_ value: some Encodable) throws -> Self {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try JSONDecoder().decode(Self.self, from: encoder.encode(value))
  }
}

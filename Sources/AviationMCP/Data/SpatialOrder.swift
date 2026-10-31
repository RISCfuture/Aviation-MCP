import MCP

/// Orders records by kind and then along a Z-order curve through their first coordinate, so a
/// published version is stored with nearby features of a kind on nearby heap pages.
enum SpatialOrder {
  private static let bitsPerAxis = 32
  private static let longitudeRange = -180.0...180.0
  private static let latitudeRange = -90.0...90.0

  static func sorted(_ records: [AviationRecord]) -> [AviationRecord] {
    records.map { (record: $0, key: key($0.geometry)) }
      .sorted { ($0.record.kind, $0.key) < ($1.record.kind, $1.key) }
      .map(\.record)
  }

  /// Sorts records without a position after every positioned record of their kind.
  static func key(_ geometry: Value?) -> UInt64 {
    guard let (longitude, latitude) = geometry.flatMap(firstCoordinate) else { return .max }
    return interleave(
      quantize(longitude, in: longitudeRange), quantize(latitude, in: latitudeRange))
  }

  private static func firstCoordinate(_ geometry: Value) -> (Double, Double)? {
    let object = geometry.objectValue
    if let collection = object?["geometries"]?.arrayValue {
      return collection.lazy.compactMap(firstCoordinate).first
    }
    return object?["coordinates"].flatMap(firstPosition)
  }

  private static func firstPosition(_ coordinates: Value) -> (Double, Double)? {
    guard let elements = coordinates.arrayValue, let first = elements.first else { return nil }
    if let longitude = number(first), elements.count >= 2, let latitude = number(elements[1]) {
      return (longitude, latitude)
    }
    return elements.lazy.compactMap(firstPosition).first
  }

  private static func number(_ value: Value) -> Double? {
    value.doubleValue ?? value.intValue.map(Double.init)
  }

  private static func quantize(_ value: Double, in range: ClosedRange<Double>) -> UInt32 {
    let clamped = min(max(value, range.lowerBound), range.upperBound)
    let fraction = (clamped - range.lowerBound) / (range.upperBound - range.lowerBound)
    return UInt32((fraction * Double(UInt32.max)).rounded(.down))
  }

  private static func interleave(_ longitude: UInt32, _ latitude: UInt32) -> UInt64 {
    (0..<bitsPerAxis).reduce(0) { key, bit in
      key | UInt64(longitude >> bit & 1) << (2 * bit)
        | UInt64(latitude >> bit & 1) << (2 * bit + 1)
    }
  }
}

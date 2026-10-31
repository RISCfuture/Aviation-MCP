import Foundation
import MCP

/// A bounded search for reporting stations around a position.
///
/// The bounding box snaps outward to a fixed grid, so requests for nearby positions share one
/// cached upstream response while distances are still measured from the exact position.
struct StationSearchArea: Sendable {
  /// The farthest a station may be from the position to supply its reports.
  static let radiusNM = 10.0
  private static let gridCellsPerDegree = 10.0
  private static let earthRadiusNM = 3440.065
  private static let minimumLongitudeScale = 0.05

  let latitude: Double
  let longitude: Double

  /// The `minLat,minLon,maxLat,maxLon` box enclosing the search radius.
  var boundingBox: String {
    let latitudeSpan = Self.radiusNM / 60
    let south = max(-90, Self.snap(latitude - latitudeSpan, rounding: .down))
    let north = min(90, Self.snap(latitude + latitudeSpan, rounding: .up))
    let scale = max(
      Self.minimumLongitudeScale, cos(max(abs(south), abs(north)) * .pi / 180))
    let west = max(-180, Self.snap(longitude - latitudeSpan / scale, rounding: .down))
    let east = min(180, Self.snap(longitude + latitudeSpan / scale, rounding: .up))
    return [south, west, north, east].map { String($0) }.joined(separator: ",")
  }

  init(latitude: Double, longitude: Double) {
    self.latitude = latitude
    self.longitude = longitude
  }

  init?(_ query: WeatherQuery) {
    guard let latitude = query.latitude, let longitude = query.longitude else { return nil }
    self.init(latitude: latitude, longitude: longitude)
  }

  /// The great-circle distance in nautical miles to a station that reported its position.
  func distanceNM(to entry: [String: Value]) -> Double? {
    guard let stationLatitude = Self.number(entry["lat"]),
      let stationLongitude = Self.number(entry["lon"])
    else { return nil }
    return distanceNM(latitude: stationLatitude, longitude: stationLongitude)
  }

  func distanceNM(latitude other: Double, longitude otherLongitude: Double) -> Double {
    let radians = Double.pi / 180
    let deltaLatitude = (other - latitude) * radians
    let deltaLongitude = (otherLongitude - longitude) * radians
    let haversine =
      pow(sin(deltaLatitude / 2), 2)
      + cos(latitude * radians) * cos(other * radians) * pow(sin(deltaLongitude / 2), 2)
    return 2 * Self.earthRadiusNM * asin(min(1, sqrt(haversine)))
  }

  private static func snap(_ degrees: Double, rounding: FloatingPointRoundingRule) -> Double {
    (degrees * gridCellsPerDegree).rounded(rounding) / gridCellsPerDegree
  }

  private static func number(_ value: Value?) -> Double? {
    value?.doubleValue ?? value?.intValue.map(Double.init)
  }
}

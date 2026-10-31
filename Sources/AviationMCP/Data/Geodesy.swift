import Foundation
import MCP

/// A WGS84 latitude/longitude in decimal degrees.
struct GeoPoint: Equatable, Sendable {
  let latitude: Double
  let longitude: Double

  /// The GeoJSON `[longitude, latitude]` position.
  var position: Value { .array([.double(longitude), .double(latitude)]) }
}

/// Geodesic calculations on the WGS84 ellipsoid.
enum Geodesy {
  private static let semiMajorAxisMeters = 6_378_137.0
  private static let flattening = 1 / 298.257_223_563
  private static let metersPerNauticalMile = 1852.0
  private static let convergence = 1e-12
  private static let maximumIterations = 200

  private static var semiMinorAxisMeters: Double { semiMajorAxisMeters * (1 - flattening) }

  /// The point reached by following a geodesic from `origin` along an initial true course
  /// (Vincenty's direct solution).
  static func destination(
    from origin: GeoPoint, courseDeg: Double, distanceNM: Double
  ) -> GeoPoint {
    let (major, minor) = (semiMajorAxisMeters, semiMinorAxisMeters)
    let course = radians(courseDeg)
    let distance = distanceNM * metersPerNauticalMile
    let tanU1 = (1 - flattening) * tan(radians(origin.latitude))
    let cosU1 = 1 / (1 + tanU1 * tanU1).squareRoot()
    let sinU1 = tanU1 * cosU1
    let sigma1 = atan2(tanU1, cos(course))
    let sinAlpha = cosU1 * sin(course)
    let cosSquaredAlpha = 1 - sinAlpha * sinAlpha
    let uSquared = cosSquaredAlpha * (major * major - minor * minor) / (minor * minor)
    let coefficientA =
      1 + uSquared / 16384 * (4096 + uSquared * (-768 + uSquared * (320 - 175 * uSquared)))
    let coefficientB = uSquared / 1024 * (256 + uSquared * (-128 + uSquared * (74 - 47 * uSquared)))
    var sigma = distance / (minor * coefficientA)
    var cos2SigmaM = 0.0
    for _ in 0..<maximumIterations {
      cos2SigmaM = cos(2 * sigma1 + sigma)
      let deltaSigma =
        coefficientB * sin(sigma)
        * (cos2SigmaM + coefficientB / 4
          * (cos(sigma) * (-1 + 2 * cos2SigmaM * cos2SigmaM) - coefficientB / 6 * cos2SigmaM
            * (-3 + 4 * sin(sigma) * sin(sigma)) * (-3 + 4 * cos2SigmaM * cos2SigmaM)))
      let previous = sigma
      sigma = distance / (minor * coefficientA) + deltaSigma
      if abs(sigma - previous) < convergence { break }
    }
    let term = sinU1 * sin(sigma) - cosU1 * cos(sigma) * cos(course)
    let latitude = atan2(
      sinU1 * cos(sigma) + cosU1 * sin(sigma) * cos(course),
      (1 - flattening) * (sinAlpha * sinAlpha + term * term).squareRoot())
    let lambda = atan2(
      sin(sigma) * sin(course), cosU1 * cos(sigma) - sinU1 * sin(sigma) * cos(course))
    let correction =
      flattening / 16 * cosSquaredAlpha * (4 + flattening * (4 - 3 * cosSquaredAlpha))
    let longitudeOffset =
      lambda - (1 - correction) * flattening * sinAlpha
      * (sigma + correction * sin(sigma)
        * (cos2SigmaM + correction * cos(sigma) * (-1 + 2 * cos2SigmaM * cos2SigmaM)))
    return GeoPoint(
      latitude: degrees(latitude),
      longitude: normalizedLongitude(origin.longitude + degrees(longitudeOffset)))
  }

  /// The initial true course from one point toward another, in degrees from 0 up to 360,
  /// measured on a sphere.
  static func initialCourse(from start: GeoPoint, to end: GeoPoint) -> Double {
    let startLatitude = radians(start.latitude)
    let endLatitude = radians(end.latitude)
    let longitudeDelta = radians(end.longitude - start.longitude)
    let course = atan2(
      sin(longitudeDelta) * cos(endLatitude),
      cos(startLatitude) * sin(endLatitude) - sin(startLatitude) * cos(endLatitude)
        * cos(longitudeDelta))
    return normalizedCourse(degrees(course))
  }

  /// A course expressed in degrees from 0 up to 360.
  static func normalizedCourse(_ course: Double) -> Double {
    let remainder = course.truncatingRemainder(dividingBy: 360)
    return remainder < 0 ? remainder + 360 : remainder
  }

  /// A longitude expressed in degrees from -180 through 180.
  static func normalizedLongitude(_ longitude: Double) -> Double {
    let shifted = normalizedCourse(longitude + 180) - 180
    return shifted == -180 && longitude > 0 ? 180 : shifted
  }

  private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
  private static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
}

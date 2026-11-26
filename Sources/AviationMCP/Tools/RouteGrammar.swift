import Foundation

/// One element of a route string, classified by its form alone.
enum RouteToken: Equatable, Sendable {
  /// A cruising speed and level group, such as `N0450F350`.
  case speedLevel
  /// `DCT`.
  case direct
  case coordinate(GeoPoint)
  /// A point at a magnetic bearing and distance from a place, such as `SNS090020`.
  case placeBearingDistance(place: String, bearingMagneticDeg: Double, distanceNM: Double)
  /// An airport, fix, navaid, airway, departure or arrival; the data decides which.
  case name(String)
}

struct RouteWord: Equatable, Sendable {
  /// The element as written, uppercased.
  let text: String
  let token: RouteToken
  /// A speed and level change written after a point, such as the `N0450F350` of
  /// `GOSHI/N0450F350`.
  var speedLevel: String?
}

/// Splits a route string into elements and classifies each by its form.
enum RouteGrammar {
  static let maximumElements = 60

  static func parse(_ route: String) throws -> [RouteWord] {
    let texts = route.uppercased().split { $0.isWhitespace || $0 == "." }.map(String.init)
    guard !texts.isEmpty else { throw ToolInputError(reason: "route_string has no elements.") }
    guard texts.count <= maximumElements else {
      throw ToolInputError(
        reason: "route_string has \(texts.count) elements; at most \(maximumElements) are accepted."
      )
    }
    return try texts.enumerated().map { index, text in try word(text, index: index) }
  }

  private static func word(_ text: String, index: Int) throws -> RouteWord {
    let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard parts.count <= 2, let body = parts.first, let token = token(body) else {
      throw unrecognized(text, index: index)
    }
    guard parts.count == 2 else { return RouteWord(text: text, token: token) }
    switch token {
    case .name, .coordinate, .placeBearingDistance:
      guard isSpeedLevel(parts[1]) else { throw unrecognized(text, index: index) }
      return RouteWord(text: text, token: token, speedLevel: parts[1])
    case .speedLevel, .direct: throw unrecognized(text, index: index)
    }
  }

  private static func unrecognized(_ text: String, index: Int) -> ToolInputError {
    ToolInputError(reason: "Element \(index) (\(text)) is not a recognized route element.")
  }

  private static func token(_ text: String) -> RouteToken? {
    if isSpeedLevel(text) { return .speedLevel }
    if text == "DCT" { return .direct }
    if let point = coordinate(text) { return .coordinate(point) }
    if let match = text.wholeMatch(of: /([A-Z]{2,5})(\d{3})(\d{3})/),
      let bearing = Double(match.2), let distance = Double(match.3), bearing <= 360
    {
      return .placeBearingDistance(
        place: String(match.1), bearingMagneticDeg: bearing, distanceNM: distance)
    }
    guard text.wholeMatch(of: /[A-Z0-9]{1,8}/) != nil else { return nil }
    return .name(text)
  }

  /// An ICAO speed group followed by a level group, such as `N0450F350` or `M082F350`.
  private static func isSpeedLevel(_ text: String) -> Bool {
    text.wholeMatch(of: /(N\d{4}|K\d{4}|M\d{3})(F\d{3}|A\d{3}|S\d{4}|M\d{4}|VFR)/) != nil
  }

  /// An ICAO coordinate in whole degrees (`37N122W`) or degrees and minutes (`3730N12200W`).
  private static func coordinate(_ text: String) -> GeoPoint? {
    guard let match = text.wholeMatch(of: /(\d{2})(\d{2})?([NS])(\d{3})(\d{2})?([EW])/),
      (match.2 == nil) == (match.5 == nil),
      let latitudeDegrees = Double(match.1), let longitudeDegrees = Double(match.4)
    else { return nil }
    let latitudeMinutes = match.2.flatMap { Double($0) } ?? 0
    let longitudeMinutes = match.5.flatMap { Double($0) } ?? 0
    let latitude = latitudeDegrees + latitudeMinutes / 60
    let longitude = longitudeDegrees + longitudeMinutes / 60
    guard latitudeMinutes < 60, longitudeMinutes < 60, latitude <= 90, longitude <= 180 else {
      return nil
    }
    return GeoPoint(
      latitude: match.3 == "S" ? -latitude : latitude,
      longitude: match.6 == "W" ? -longitude : longitude)
  }
}

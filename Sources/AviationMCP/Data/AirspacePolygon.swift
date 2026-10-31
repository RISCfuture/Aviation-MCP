import MCP
import SwiftCIFP

/// Builds GeoJSON polygons from airspace boundary descriptions.
enum AirspacePolygon {
  private static let maximumArcStepDeg = 3.0
  private static let maximumRhumbStepDeg = 0.1
  private static let minimumRingVertices = 3

  /// A polygon (or multipolygon) for ARINC 424 boundary records, or `nil` when a segment
  /// cannot be resolved.
  ///
  /// Each end-of-description record closes a ring. Arcs and circles are densified along
  /// geodesics from their published origin and radius; rhumb lines are densified so that
  /// the geodesic edges stored in PostGIS follow them.
  static func geometry(_ boundaries: [AirspaceBoundary]) -> Value? {
    let rings = descriptions(boundaries.sorted()).map(ring)
    guard !rings.isEmpty, rings.allSatisfy({ $0 != nil }) else { return nil }
    return geometry(rings: rings.compactMap(\.self))
  }

  /// A polygon for one ring, or a multipolygon for several disjoint rings, closing each ring.
  static func geometry(rings: [[GeoPoint]]) -> Value? {
    guard !rings.isEmpty, rings.allSatisfy({ $0.count >= minimumRingVertices }) else {
      return nil
    }
    let polygons: [Value] = rings.map { ring in
      .array([.array((ring + [ring[0]]).map(\.position))])
    }
    return polygons.count == 1
      ? .object(["type": "Polygon", "coordinates": polygons[0]])
      : .object(["type": "MultiPolygon", "coordinates": .array(polygons)])
  }

  private static func descriptions(_ boundaries: [AirspaceBoundary]) -> [[AirspaceBoundary]] {
    var descriptions: [[AirspaceBoundary]] = []
    var current: [AirspaceBoundary] = []
    for boundary in boundaries {
      current.append(boundary)
      if boundary.isEndOfDescription {
        descriptions.append(current)
        current = []
      }
    }
    if !current.isEmpty { descriptions.append(current) }
    return descriptions
  }

  private static func ring(_ boundaries: [AirspaceBoundary]) -> [GeoPoint]? {
    if boundaries.count == 1, boundaries[0].boundaryVia == .circle {
      return circle(boundaries[0])
    }
    var points: [GeoPoint] = []
    for (index, boundary) in boundaries.enumerated() {
      let next = boundaries[(index + 1) % boundaries.count]
      guard let segment = segment(from: boundary, to: next) else { return nil }
      points += segment
    }
    return points.count >= minimumRingVertices ? points : nil
  }

  private static func segment(
    from boundary: AirspaceBoundary, to next: AirspaceBoundary
  ) -> [GeoPoint]? {
    guard let via = boundary.boundaryVia, let start = boundary.coordinate.map(point) else {
      return nil
    }
    switch via {
    case .greatCircle: return [start]
    case .rhumbLine:
      return next.coordinate.map { rhumbLine(from: start, to: point($0)) }
    case .arcClockwise, .arcCounterClockwise:
      guard let end = next.coordinate.map(point), let center = boundary.arcOrigin.map(point),
        let radius = boundary.arcDistanceNM
      else { return nil }
      return arc(
        center: center, radiusNM: radius, from: start, to: end, clockwise: via == .arcClockwise)
    case .circle, .arcByEdge: return nil
    }
  }

  private static func circle(_ boundary: AirspaceBoundary) -> [GeoPoint]? {
    guard let center = boundary.arcOrigin.map(point), let radius = boundary.arcDistanceNM else {
      return nil
    }
    let steps = Int((360 / maximumArcStepDeg).rounded(.up))
    return (0..<steps).map {
      Geodesy.destination(
        from: center, courseDeg: Double($0) * 360 / Double(steps), distanceNM: radius)
    }
  }

  private static func arc(
    center: GeoPoint, radiusNM: Double, from start: GeoPoint, to end: GeoPoint, clockwise: Bool
  ) -> [GeoPoint] {
    let startCourse = Geodesy.initialCourse(from: center, to: start)
    let endCourse = Geodesy.initialCourse(from: center, to: end)
    var sweep =
      clockwise
      ? Geodesy.normalizedCourse(endCourse - startCourse)
      : -Geodesy.normalizedCourse(startCourse - endCourse)
    if sweep == 0 { sweep = clockwise ? 360 : -360 }
    let steps = max(1, Int((abs(sweep) / maximumArcStepDeg).rounded(.up)))
    return [start]
      + (1..<steps).map {
        Geodesy.destination(
          from: center, courseDeg: startCourse + sweep * Double($0) / Double(steps),
          distanceNM: radiusNM)
      }
  }

  private static func rhumbLine(from start: GeoPoint, to end: GeoPoint) -> [GeoPoint] {
    let latitudeDelta = end.latitude - start.latitude
    let longitudeDelta = Geodesy.normalizedLongitude(end.longitude - start.longitude)
    let span = max(abs(latitudeDelta), abs(longitudeDelta))
    let steps = max(1, Int((span / maximumRhumbStepDeg).rounded(.up)))
    return (0..<steps).map {
      let fraction = Double($0) / Double(steps)
      return GeoPoint(
        latitude: start.latitude + latitudeDelta * fraction,
        longitude: Geodesy.normalizedLongitude(start.longitude + longitudeDelta * fraction))
    }
  }

  private static func point(_ coordinate: Coordinate) -> GeoPoint {
    GeoPoint(latitude: coordinate.latitudeDeg, longitude: coordinate.longitudeDeg)
  }
}

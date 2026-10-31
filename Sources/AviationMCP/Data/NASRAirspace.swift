import Foundation
import MCP
import SwiftNASR

enum NASRAirspace {
  private static let pointOfBeginning = "POINT OF BEGINNING"

  static func artcc(_ center: ARTCC, versionID: UUID) throws -> AviationRecord {
    var record = NASRNormalization.base(
      version: versionID, kind: "artcc",
      identity: .init(id: center.id, identifier: center.code, name: center.name),
      position: center.location)
    record.data = NASRNormalization.fields([
      "icao_identifier": center.ICAOID.map(Value.string),
      "facility_type": .string(center.type.rawValue),
      "location_name": .string(center.locationName), "state": center.stateCode.map(Value.string),
      "frequencies": .array(
        center.frequencies.compactMap { NASRNormalization.frequency(kilohertz: $0.frequencyKHz) }),
      "geometry_scope": "facility_location",
      "geometry_limitations": .array([
        "ARTCC spatial matches use facility locations, not the airspace controlled by those facilities."
      ])
    ])
    return record
  }

  static func boundary(_ boundary: ARTCCBoundarySegment, versionID: UUID) throws -> AviationRecord {
    var record = NASRNormalization.base(
      version: versionID, kind: "artcc_boundary",
      identity: .init(
        id: boundary.id, identifier: boundary.ARTCCIdentifier, name: boundary.centerName),
      position: boundary.position)
    record.sequence = Int(boundary.sequenceNumber)
    record.data = NASRNormalization.fields([
      "altitude_structure": .string(boundary.altitudeStructureName),
      "boundary_description": .string(boundary.boundaryDescription),
      "point_designator": .string(boundary.pointDesignator),
      "nas_description_only": boundary.NASDescriptionOnly.map(Value.bool),
      "geometry_scope": "boundary_point",
      "geometry_limitations": .array([
        "ARTCC boundary points do not define coverage polygons; proximity cannot establish airspace containment."
      ])
    ])
    return record
  }

  /// One polygon record per ARTCC and altitude structure, joining the published boundary points
  /// in sequence and closing a ring at each return to the point of beginning.
  static func centerAirspaces(_ segments: [ARTCCBoundarySegment], versionID: UUID)
    -> [AviationRecord]
  {
    Dictionary(grouping: segments) { [$0.ARTCCIdentifier, $0.altitudeStructureName] }
      .sorted { $0.key.lexicographicallyPrecedes($1.key) }
      .map { _, points in
        centerAirspace(
          points.sorted { $0.sequenceNumber < $1.sequenceNumber }, versionID: versionID)
      }
  }

  private static func centerAirspace(_ points: [ARTCCBoundarySegment], versionID: UUID)
    -> AviationRecord
  {
    let first = points[0]
    var record = AviationRecord(
      versionID: versionID, kind: "artcc_airspace",
      id: first.ARTCCIdentifier + "/" + first.altitudeStructureName,
      identifier: first.ARTCCIdentifier,
      name: first.centerName + " " + first.altitudeStructureName)
    record.geometry = AirspacePolygon.geometry(rings: rings(points))
    let limits = verticalLimits(first.altitudeStructure)
    record.data = NASRNormalization.fields([
      "altitude_structure": .string(first.altitudeStructureName),
      "lower_limit": limits?.lower, "upper_limit": limits?.upper,
      "boundary_point_count": .int(points.count),
      "geometry_scope": "boundary_polygon"
    ])
    return record
  }

  private static func rings(_ points: [ARTCCBoundarySegment]) -> [[GeoPoint]] {
    var rings: [[GeoPoint]] = []
    var current: [GeoPoint] = []
    for point in points {
      current.append(
        GeoPoint(
          latitude: Double(point.position.latitudeArcsec) / 3600,
          longitude: Double(point.position.longitudeArcsec) / 3600))
      if point.boundaryDescription.uppercased().contains(pointOfBeginning) {
        rings.append(current)
        current = []
      }
    }
    if !current.isEmpty { rings.append(current) }
    return rings
  }

  private static func verticalLimits(_ structure: ARTCCBoundarySegment.AltitudeStructure?)
    -> (lower: Value, upper: Value)?
  {
    let flightLevel180: Value = .object([
      "value": 180, "unit": "flight_level", "datum": "standard_pressure"
    ])
    switch structure {
    case .low: return (.object(["reference": "ground"]), flightLevel180)
    case .high: return (flightLevel180, .object(["reference": "unlimited"]))
    default: return nil
    }
  }

  static func parachute(_ area: ParachuteJumpArea, versionID: UUID) throws -> AviationRecord {
    var record = NASRNormalization.base(
      version: versionID, kind: "parachute_area",
      identity: .init(
        id: area.PJAId, identifier: area.PJAId,
        name: area.dropZoneName ?? area.airportName ?? area.PJAId), position: area.position)
    record.data = NASRNormalization.fields([
      "radius_nm": area.radiusNM.map(Value.double),
      "maximum_altitude": area.maxAltitude.map(NASRNormalization.altitude),
      "times_of_use": .array(area.timesOfUse.map(Value.string)),
      "description": area.additionalDescription.map(Value.string),
      "city": area.city.map(Value.string), "state": area.stateCode.map(Value.string),
      "geometry_scope": "center_point",
      "geometry_limitations": .array([
        .string(
          "Parachute area spatial matches use center points; "
            + "published radii are preserved but not included in the geometry.")
      ])
    ])
    return record
  }

  static func military(_ route: MilitaryTrainingRoute, versionID: UUID) throws -> AviationRecord {
    var record = NASRNormalization.base(
      version: versionID, kind: "military_route",
      identity: .init(id: route.id, identifier: route.id, name: route.id), position: nil)
    let points = militaryPoints(route)
    let path = AirwayGeometry.path(points)
    record.geometry = path.geometry
    record.data = NASRNormalization.fields([
      "route_type": .string(route.routeType.rawValue),
      "times_of_use": route.timesOfUse.map(Value.string),
      "operating_procedures": .array(route.operatingProcedures.map(Value.string)),
      "width_descriptions": .array(route.routeWidthDescriptions.map(Value.string)),
      "terrain_following_operations": .array(route.terrainFollowingOperations.map(Value.string)),
      "points": .array(points),
      "geometry_gap_sequences": .array(path.gaps),
      "geometry_scope": "centerline_only",
      "geometry_limitations": .array([
        "Route widths and textual segment instructions are not represented."
      ])
    ])
    return record
  }

  private static func militaryPoints(_ route: MilitaryTrainingRoute) -> [Value] {
    let sequences = route.routePoints.compactMap(\.sequenceNumber)
    let ordered =
      sequences.count == route.routePoints.count
      && Set(sequences).count == sequences.count
    let points = route.routePoints.sorted { ($0.sequenceNumber ?? 0) < ($1.sequenceNumber ?? 0) }
    return points.map { point in
      Normalization.object([
        "identifier": .string(point.pointId),
        "sequence": NASRNormalization.uint(point.sequenceNumber),
        "position": point.position.map(NASRNormalization.point),
        "airway_gap": ordered ? nil : true,
        "segment_leading": point.segmentDescriptionLeading.map(Value.string),
        "segment_leaving": point.segmentDescriptionLeaving.map(Value.string)
      ])
    }
  }
}

import Foundation
import MCP
import SwiftNASR

enum NASRAirspace {
  static func artcc(_ center: ARTCC, versionID: UUID) throws -> AviationRecord {
    var record = try NASRNormalization.base(
      center, version: versionID, kind: "artcc",
      identity: .init(id: center.id, identifier: center.code, name: center.name),
      position: center.location)
    record.data = NASRNormalization.fields([
      "icao_identifier": center.ICAOID.map(Value.string),
      "facility_type": .string(center.type.rawValue),
      "location_name": .string(center.locationName), "state": center.stateCode.map(Value.string),
      "frequencies_khz": .array(center.frequencies.map { .int(Int($0.frequencyKHz)) }),
      "geometry_scope": "facility_location",
      "geometry_limitations": .array([
        "ARTCC spatial matches use facility locations, not the airspace controlled by those facilities."
      ])
    ])
    return record
  }

  static func boundary(_ boundary: ARTCCBoundarySegment, versionID: UUID) throws -> AviationRecord {
    var record = try NASRNormalization.base(
      boundary, version: versionID, kind: "artcc_boundary",
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

  static func parachute(_ area: ParachuteJumpArea, versionID: UUID) throws -> AviationRecord {
    var record = try NASRNormalization.base(
      area, version: versionID, kind: "parachute_area",
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
    var record = try NASRNormalization.base(
      route, version: versionID, kind: "military_route",
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

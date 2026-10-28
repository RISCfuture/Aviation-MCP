import Foundation
import MCP
import SwiftCIFP

enum CIFPAirspace {
  static func records(_ cifp: CIFP, versionID: UUID) throws -> [AviationRecord] {
    var records: [AviationRecord] = []
    for airspace in cifp.controlledAirspaces {
      var record = AirspaceDefinition(
        identifier: airspace.airspaceCenter, name: airspace.name, region: airspace.icaoRegion,
        multiple: airspace.multipleCode, type: "controlled", boundaries: airspace.boundaries,
        lower: airspace.lowerLimit, upper: airspace.upperLimit
      ).record(versionID: versionID)
      record.data["class"] = airspace.airspaceClass.map { .string(String($0.rawValue)) }
      record.supplemental = try Normalization.supplemental(airspace)
      records.append(record)
    }
    for airspace in cifp.specialUseAirspaces {
      var record = AirspaceDefinition(
        identifier: airspace.fullDesignation, name: airspace.name, region: airspace.icaoRegion,
        multiple: airspace.multipleCode, type: "special_use", boundaries: airspace.boundaries,
        lower: airspace.lowerLimit, upper: airspace.upperLimit
      ).record(versionID: versionID)
      record.data["restrictive_type"] = .string(String(airspace.kind.rawValue))
      record.supplemental = try Normalization.supplemental(airspace)
      records.append(record)
    }
    return records
  }

}

private struct AirspaceDefinition {
  let identifier: String
  let name: String
  let region: String
  let multiple: String?
  let type: String
  let boundaries: [AirspaceBoundary]
  let lower: Altitude?
  let upper: Altitude?

  func record(versionID: UUID) -> AviationRecord {
    var record = AviationRecord(
      versionID: versionID, kind: "airspace",
      id: [type, region, identifier, multiple ?? "", name].joined(separator: "/"),
      identifier: identifier, name: name)
    record.data = [
      "airspace_type": .string(type), "icao_region": .string(region),
      "boundaries": .array(
        boundaries.sorted { $0.sequenceNumber < $1.sequenceNumber }.map { boundary in
          Normalization.object([
            "sequence": .int(boundary.sequenceNumber),
            "is_end_of_description": .bool(boundary.isEndOfDescription),
            "via": boundary.boundaryVia.map { .string(String($0.rawValue)) },
            "position": boundary.coordinate.map {
              Normalization.point(latitude: $0.latitudeDeg, longitude: $0.longitudeDeg)
            },
            "arc_origin": boundary.arcOrigin.map {
              Normalization.point(latitude: $0.latitudeDeg, longitude: $0.longitudeDeg)
            },
            "arc_bearing_deg": boundary.arcBearingDeg.map(Value.double),
            "arc_distance_nm": boundary.arcDistanceNM.map(Value.double)
          ])
        }),
      "geometry_status": "boundary_definition_only"
    ]
    record.data["lower_limit"] = lower.map(CIFPRestrictions.altitude)
    record.data["upper_limit"] = upper.map(CIFPRestrictions.altitude)
    return record
  }
}

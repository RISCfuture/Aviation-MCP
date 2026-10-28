import Foundation
import MCP
import SwiftNASR

enum NASRAirways {
  static func record(_ airway: Airway, versionID: UUID) throws -> AviationRecord {
    var record = try NASRNormalization.base(
      airway, version: versionID, kind: "airway",
      identity: .init(id: airway.id, identifier: airway.designation, name: airway.designation),
      position: nil)
    let segments = airway.segments.sorted { $0.sequenceNumber < $1.sequenceNumber }
    record.data = [
      "airway_type": .string(airway.type.rawValue), "segments": .array(segments.map(segment))
    ]
    let path = AirwayGeometry.path(segments.map(segment))
    record.geometry = path.geometry
    record.data["geometry_gap_sequences"] = .array(path.gaps)
    return record
  }

  private static func segment(_ segment: Airway.Segment) -> Value {
    Normalization.object([
      "sequence": .int(Int(segment.sequenceNumber)),
      "identifier": (segment.point.navaidId ?? segment.point.name).map(Value.string),
      "name": segment.point.name.map(Value.string),
      "point_type": segment.point.pointType.map { .string($0.rawValue) },
      "state_code": segment.point.stateCode.map(Value.string),
      "position": segment.point.position.map(NASRNormalization.point),
      "icao_region": segment.point.ICAORegionCode.map(Value.string),
      "distance_to_next_nm": NASRNormalization.float(segment.distanceToNextNM),
      "course_magnetic_deg": NASRNormalization.float(segment.magneticCourseDeg),
      "opposite_course_magnetic_deg": NASRNormalization.float(segment.magneticCourseOppositeDeg),
      "airway_gap": segment.isAirwayGap.map(Value.bool),
      "signal_coverage_gap": segment.hasSignalCoverageGap.map(Value.bool),
      "mea_unusable": segment.isMEAUnusable.map(Value.bool),
      "rnp_nm": NASRNormalization.float(segment.requiredNavigationPerformanceNM),
      "altitudes": altitudes(segment.altitudes)
    ])
  }

  private static func altitudes(_ value: Airway.SegmentAltitudes) -> Value {
    Normalization.object([
      "unit": "ft", "datum": "MSL",
      "mea": NASRNormalization.uint(value.MEAFt),
      "mea_opposite": NASRNormalization.uint(value.MEAOppositeFt),
      "mea_direction": value.MEADirection.map { .string($0.rawValue) },
      "mea_opposite_direction": value.MEAOppositeDirection.map { .string($0.rawValue) },
      "maa": NASRNormalization.uint(value.MAAFt), "moca": NASRNormalization.uint(value.MOCAFt),
      "mca": NASRNormalization.uint(value.MCAFt),
      "mca_opposite": NASRNormalization.uint(value.MCAOppositeFt),
      "mca_direction": value.MCADirection.map { .string($0.rawValue) },
      "mca_opposite_direction": value.MCAOppositeDirection.map { .string($0.rawValue) },
      "gnss_mea": NASRNormalization.uint(value.GNSS_MEAFt),
      "gnss_mea_opposite": NASRNormalization.uint(value.GNSS_MEAOppositeFt),
      "gnss_mea_direction": value.GNSS_MEADirection.map { .string($0.rawValue) },
      "gnss_mea_opposite_direction": value.GNSS_MEAOppositeDirection.map { .string($0.rawValue) },
      "dme_mea": NASRNormalization.uint(value.DME_MEAFt),
      "dme_mea_opposite": NASRNormalization.uint(value.DME_MEAOppositeFt),
      "dme_mea_direction": value.DME_MEADirection.map { .string($0.rawValue) },
      "dme_mea_opposite_direction": value.DME_MEAOppositeDirection.map { .string($0.rawValue) }
    ])
  }
}

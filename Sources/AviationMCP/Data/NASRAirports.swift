import Foundation
import MCP
import SwiftNASR

enum NASRAirports {
  static func record(_ airport: Airport, versionID: UUID) throws -> AviationRecord {
    var record = try NASRNormalization.base(
      airport, version: versionID, kind: "airport",
      identity: .init(
        id: airport.id + "/" + airport.LID, identifier: airport.ICAOIdentifier ?? airport.LID,
        name: airport.name),
      position: airport.referencePoint)
    record.airport = record.identifier
    record.data = NASRNormalization.fields([
      "source_record_id": .string(airport.id),
      "faa_lid": .string(airport.LID), "icao_identifier": airport.ICAOIdentifier.map(Value.string),
      "city": .string(airport.city), "state": airport.stateCode.map(Value.string),
      "public_use": .bool(airport.publicUse),
      "facility_type": .string(airport.facilityType.rawValue),
      "status": .string(airport.status.rawValue), "control_tower": .bool(airport.controlTower),
      "ctaf_khz": NASRNormalization.uint(airport.CTAFKHz),
      "unicom_khz": NASRNormalization.uint(airport.UNICOMFrequencyKHz),
      "magnetic_variation_deg": airport.magneticVariationDeg.map(Value.int),
      "traffic_pattern_altitude_agl_ft": airport.trafficPatternAltitudeFtAGL.map(Value.int),
      "maximum_runway_length_ft": NASRNormalization.uint(
        airport.runways.compactMap(\.lengthFt).max()),
      "runways": .array(airport.runways.map(runway))
    ])
    return record
  }

  static func runway(_ runway: Runway) -> Value {
    Normalization.object([
      "identifier": .string(runway.identification),
      "length_ft": NASRNormalization.uint(runway.lengthFt),
      "width_ft": NASRNormalization.uint(runway.widthFt),
      "paved": runway.isPaved.map(Value.bool) ?? .null,
      "materials": .array(runway.materials.map(\.rawValue).sorted().map(Value.string)),
      "ends": .array(
        [end(runway.baseEnd, opposite: runway.reciprocalEnd)]
          + (runway.reciprocalEnd.map { [end($0, opposite: runway.baseEnd)] } ?? []))
    ])
  }

  private static func end(_ end: RunwayEnd, opposite: RunwayEnd?) -> Value {
    Normalization.object([
      "identifier": .string(end.id), "threshold": end.threshold.map(NASRNormalization.point),
      "displaced_threshold": end.displacedThreshold.map(NASRNormalization.point),
      "threshold_displacement_ft": NASRNormalization.uint(end.thresholdDisplacementFt),
      "departure_end": opposite?.threshold.map(NASRNormalization.point),
      "threshold_elevation_msl_ft": NASRNormalization.float(end.threshold?.elevationFtMSL),
      "heading_true_deg": end.heading.map { .int(Int($0.asTrueBearing().value)) },
      "heading_magnetic_deg": end.heading.map { .int(Int($0.asMagneticBearing().value)) },
      "right_traffic": end.rightTraffic.map(Value.bool),
      "tora_ft": NASRNormalization.uint(end.TORAFt), "toda_ft": NASRNormalization.uint(end.TODAFt),
      "asda_ft": NASRNormalization.uint(end.ASDAFt), "lda_ft": NASRNormalization.uint(end.LDAFt),
      "gradient_percent": NASRNormalization.float(end.gradientPct),
      "threshold_crossing_height_agl_ft": NASRNormalization.uint(end.thresholdCrossingHeightFtAGL)
    ])
  }
}

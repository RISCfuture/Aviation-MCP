import Foundation
import MCP
import SwiftNASR

enum NASRAirports {
  static func record(
    _ airport: Airport, versionID: UUID, frequencies: NASRFrequencies
  ) throws -> AviationRecord {
    var record = NASRNormalization.base(
      version: versionID, kind: "airport",
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
    record.data.merge(services(airport)) { current, _ in current }
    record.data.merge(frequencies.fields(forAirport: airport.LID)) { current, _ in current }
    return record
  }

  private static func services(_ airport: Airport) -> [String: Value] {
    NASRNormalization.fields([
      "fuel_types": list(airport.fuelsAvailable.map(\.rawValue)),
      "lighting_schedule": airport.airportLightingSchedule.map(Value.string),
      "beacon_lighting_schedule": airport.beaconLightingSchedule.map(Value.string),
      "attendance": airport.attendanceSchedule.isEmpty
        ? nil : .array(airport.attendanceSchedule.map(attendance)),
      "remarks": remarks(airport.remarks)
    ])
  }

  private static func attendance(_ schedule: AttendanceSchedule) -> Value {
    switch schedule {
    case .components(let monthly, let daily, let hourly):
      ["months": .string(monthly), "days": .string(daily), "hours": .string(hourly)]
    case .custom(let schedule):
      ["schedule": .string(schedule)]
    }
  }

  private static func remarks<Field>(_ remarks: Remarks<Field>) -> Value? {
    list(
      remarks.remarks.map { remark in
        switch remark {
        case .general(let content), .field(_, let content): content
        case .fuel(_, let fuel, let content): "\(fuel.rawValue): \(content)"
        }
      })
  }

  private static func list(_ strings: [String]) -> Value? {
    strings.isEmpty ? nil : .array(strings.map(Value.string))
  }

  static func runway(_ runway: Runway) -> Value {
    Normalization.object([
      "identifier": .string(runway.identification),
      "length_ft": NASRNormalization.uint(runway.lengthFt),
      "width_ft": NASRNormalization.uint(runway.widthFt),
      "paved": runway.isPaved.map(Value.bool) ?? .null,
      "materials": .array(runway.materials.map(\.rawValue).sorted().map(Value.string)),
      "edge_lights": runway.edgeLightsIntensity.map { .string($0.rawValue) },
      "remarks": remarks(runway.remarks),
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
      "threshold_crossing_height_agl_ft": NASRNormalization.uint(end.thresholdCrossingHeightFtAGL),
      "approach_lighting": end.approachLighting.map { .string($0.rawValue) },
      "visual_glideslope": end.visualGlideslopeIndicator.map(visualGlideslope),
      "visual_glidepath_deg": NASRNormalization.float(end.visualGlidepathDeg),
      "reil": end.hasREIL.map(Value.bool),
      "centerline_lights": end.hasCenterlineLighting.map(Value.bool),
      "touchdown_zone_lights": end.hasEndTouchdownLighting.map(Value.bool),
      "remarks": remarks(end.remarks)
    ])
  }

  private static func visualGlideslope(_ indicator: RunwayEnd.VisualGlideslopeIndicator) -> Value {
    Normalization.object([
      "type": .string(indicator.type.rawValue), "units": NASRNormalization.uint(indicator.number),
      "side": indicator.side.map { .string($0.rawValue) }
    ])
  }
}

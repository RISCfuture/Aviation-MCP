import Foundation
import MCP
import SwiftNASR

enum NASRFacilities {
  static func ils(_ facility: ILS, versionID: UUID) throws -> AviationRecord {
    var record = NASRNormalization.base(
      version: versionID, kind: "ils",
      identity: .init(id: facility.id, identifier: facility.ILSId, name: facility.airportName),
      position: facility.localizer?.position)
    record.airport = facility.airportId
    record.data = NASRNormalization.fields([
      "airport": .string(facility.airportId), "runway": .string(facility.runwayEndId),
      "system_type": .string(facility.systemType.rawValue),
      "localizer_frequency": NASRNormalization.frequency(
        kilohertz: facility.localizer?.frequencyKHz),
      "glideslope_frequency": NASRNormalization.frequency(
        kilohertz: facility.glideSlope?.frequencyKHz),
      "glideslope_angle_deg": NASRNormalization.float(facility.glideSlope?.angleDeg),
      "magnetic_variation_deg": facility.magneticVariationDeg.map(Value.int),
      "remarks": .array(facility.remarks.map(Value.string))
    ])
    return record
  }

  static func fss(_ facility: FSS, versionID: UUID) throws -> AviationRecord {
    var record = NASRNormalization.base(
      version: versionID, kind: "fss",
      identity: .init(id: facility.id, identifier: facility.id, name: facility.name),
      position: facility.location)
    record.airport = facility.airportId
    record.data = NASRNormalization.fields([
      "hours": .string(facility.hoursOfOperation),
      "radio_identifier": facility.radioIdentifier.map(Value.string),
      "phone": facility.phoneNumber.map(Value.string), "city": facility.city.map(Value.string),
      "frequencies": .array(
        try facility.frequencies.map { frequency in
          let fields = try Normalization.encodedFields(frequency)
          return Normalization.object([
            "frequency": NASRNormalization.frequency(
              kilohertz: fields["frequencyKHz"]?.intValue.flatMap(UInt.init(exactly:))),
            "name": fields["name"],
            "single_sideband": fields["singleSideband"], "use": fields["use"]
          ])
        })
    ])
    return record
  }

  static func hold(_ hold: Hold, versionID: UUID) throws -> AviationRecord {
    var record = NASRNormalization.base(
      version: versionID, kind: "hold",
      identity: .init(id: hold.id, identifier: hold.name, name: hold.name),
      position: hold.fixPosition ?? hold.navaidPosition)
    record.data = NASRNormalization.fields([
      "fix": hold.fixIdentifier.map(Value.string),
      "navaid": hold.navaidIdentifier.map(Value.string),
      "inbound_course_deg": NASRNormalization.uint(hold.inboundCourseDeg),
      "azimuth_type": hold.azimuthType.map { .string($0.rawValue) },
      "turn_direction": hold.turnDirection.map { .string($0.rawValue) },
      "leg_time_minutes": hold.legTimeMin.map(Value.double),
      "leg_distance_nm": hold.legDistanceNM.map(Value.double),
      "all_aircraft_altitude_ft": hold.altitudes.allAircraftAltitude.map(range),
      "speed_altitude_restrictions": .array(
        hold.altitudes.entries().sorted { $0.airspeed.lowerBound < $1.airspeed.lowerBound }.map {
          .object(["speed_knots": range($0.airspeed), "altitude_ft": range($0.altitude)])
        }),
      "other_altitude_speed_restrictions": .array(hold.otherAltitudeSpeed.map(Value.string))
    ])
    return record
  }

  private static func range(_ range: ClosedRange<UInt>) -> Value {
    .object(["minimum": .int(Int(range.lowerBound)), "maximum": .int(Int(range.upperBound))])
  }
}

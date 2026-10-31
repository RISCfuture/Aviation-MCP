import Foundation
import MCP
import SwiftNASR

struct NASRIdentity {
  let id: String
  let identifier: String
  let name: String
}

enum NASRNormalization {
  private static let highFrequencyFloorHertz = 30_000_000.0

  static func point(_ location: Location) -> Value {
    Normalization.point(
      latitude: Double(location.latitudeArcsec) / 3600,
      longitude: Double(location.longitudeArcsec) / 3600)
  }

  static func altitude(_ altitude: Altitude) -> Value {
    .object([
      "value": .int(Int(altitude.value)), "unit": "ft", "datum": .string(altitude.datum.rawValue)
    ])
  }

  static func fields(_ fields: [String: Value?]) -> [String: Value] {
    fields.compactMapValues { $0 }
  }

  static func uint(_ value: UInt?) -> Value? { value.map { .int(Int($0)) } }

  /// A radio frequency in the unit charted for its band: kHz below 30 MHz, MHz above.
  static func frequency(hertz: UInt?) -> Value? {
    hertz.map { hertz in
      let value = Double(hertz)
      return value < highFrequencyFloorHertz
        ? .object(["value": .double(value / 1_000), "unit": "kHz"])
        : .object(["value": .double(value / 1_000_000), "unit": "MHz"])
    }
  }

  static func frequency(kilohertz: UInt?) -> Value? {
    frequency(hertz: kilohertz.map { $0 * 1_000 })
  }
  static func float(_ value: Float?) -> Value? { value.map { .double(Double($0)) } }

  static func base(
    version: UUID, kind: String, identity: NASRIdentity, position: Location?
  ) -> AviationRecord {
    var record = AviationRecord(
      versionID: version, kind: kind, id: identity.id,
      identifier: identity.identifier, name: identity.name)
    record.geometry = position.map(point)
    record.elevationMSLFeet = position?.elevationFtMSL.map(Double.init)
    return record
  }
}

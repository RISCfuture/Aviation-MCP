import Foundation
import MCP
import SwiftNASR

struct NASRIdentity {
  let id: String
  let identifier: String
  let name: String
}

enum NASRNormalization {
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
  static func float(_ value: Float?) -> Value? { value.map { .double(Double($0)) } }

  static func base(
    _ source: some Encodable, version: UUID, kind: String,
    identity: NASRIdentity, position: Location?
  ) throws -> AviationRecord {
    var record = AviationRecord(
      versionID: version, kind: kind, id: identity.id,
      identifier: identity.identifier, name: identity.name)
    record.geometry = position.map(point)
    record.elevationMSLFeet = position?.elevationFtMSL.map(Double.init)
    record.supplemental = try Normalization.supplemental(source)
    return record
  }
}

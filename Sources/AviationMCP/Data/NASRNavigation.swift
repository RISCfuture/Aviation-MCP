import Foundation
import MCP
import SwiftNASR

enum NASRNavigation {
  static func navaid(_ navaid: Navaid, versionID: UUID) throws -> AviationRecord {
    var record = NASRNormalization.base(
      version: versionID, kind: "navaid",
      identity: .init(
        id: [
          navaid.id, navaid.type.rawValue, navaid.stateName ?? "", navaid.country ?? "", navaid.name
        ].joined(separator: "/"),
        identifier: navaid.id, name: navaid.name),
      position: navaid.position)
    record.data = NASRNormalization.fields([
      "source_record_id": .string(navaid.id),
      "facility_type": .string(navaid.type.rawValue),
      "frequency": NASRNormalization.frequency(hertz: navaid.frequencyHz),
      "city": .string(navaid.city), "state": navaid.stateName.map(Value.string),
      "public_use": .bool(navaid.publicUse), "operational": .bool(navaid.isOperational),
      "magnetic_variation_deg": navaid.magneticVariationDeg.map(Value.int)
    ])
    return record
  }

  static func fix(_ fix: Fix, versionID: UUID) throws -> AviationRecord {
    var record = NASRNormalization.base(
      version: versionID, kind: "fix",
      identity: .init(
        id: [fix.id, fix.ICAORegion ?? "", fix.stateName].joined(separator: "/"),
        identifier: fix.id, name: fix.id),
      position: fix.position)
    record.data = NASRNormalization.fields([
      "source_record_id": .string(fix.id),
      "icao_region": fix.ICAORegion.map(Value.string), "state": .string(fix.stateName),
      "category": .string(fix.category.rawValue), "published": .bool(fix.isPublished),
      "navaid_description": fix.navaidDescription.map(Value.string),
      "radar_description": fix.radarDescription.map(Value.string)
    ])
    return record
  }

  static func weather(_ station: WeatherStation, versionID: UUID) throws -> AviationRecord {
    var record = NASRNormalization.base(
      version: versionID, kind: "awos",
      identity: .init(id: station.id, identifier: station.id, name: station.city ?? station.id),
      position: station.position)
    record.data = NASRNormalization.fields([
      "station_type": .string(station.type.rawValue), "commissioned": .bool(station.isCommissioned),
      "frequency": NASRNormalization.frequency(kilohertz: station.frequencyKHz),
      "secondary_frequency": NASRNormalization.frequency(kilohertz: station.secondaryFrequencyKHz),
      "phone": station.phoneNumber.map(Value.string),
      "airport_site_number": station.airportSiteNumber.map(Value.string)
    ])
    return record
  }
}

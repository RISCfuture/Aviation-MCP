import Foundation
import MCP
import SwiftNASR

enum NASRRoutes {
  static func coded(_ route: CodedDepartureRoute, versionID: UUID) throws -> AviationRecord {
    var record = try NASRNormalization.base(
      route, version: versionID, kind: "coded_departure_route",
      identity: .init(id: route.id, identifier: route.routeCode, name: route.routeString),
      position: nil)
    record.airport = route.origin
    record.data = NASRNormalization.fields([
      "origin": .string(route.origin), "destination": .string(route.destination),
      "departure_fix": .string(route.departureFix), "route": .string(route.routeString),
      "departure_artcc": .string(route.departureCenterIdentifier),
      "arrival_artcc": route.arrivalCenterIdentifier.map(Value.string),
      "coordination_required": route.coordinationRequired.map(Value.bool),
      "navigation_equipment": route.navigationEquipment.map(Value.string),
      "length_nm": NASRNormalization.uint(route.lengthNM)
    ])
    return record
  }

  static func preferred(_ route: PreferredRoute, versionID: UUID) throws -> AviationRecord {
    var record = try NASRNormalization.base(
      route, version: versionID, kind: "preferred_route",
      identity: .init(
        id: route.id, identifier: route.designator ?? route.id,
        name: route.originIdentifier + " to " + route.destinationIdentifier), position: nil)
    record.airport = route.originIdentifier
    record.data = NASRNormalization.fields([
      "origin": .string(route.originIdentifier),
      "destination": .string(route.destinationIdentifier),
      "route_type": route.routeType.map { .string($0.rawValue) },
      "altitude_restrictions": route.altitudeDescription.map(Value.string),
      "aircraft_restrictions": route.aircraftDescription.map(Value.string),
      "direction_restrictions": route.directionLimitations.map(Value.string),
      "effective_hours": .array(route.effectiveHours.map(Value.string)),
      "segments": .array(
        route.segments.sorted { $0.sequenceNumber < $1.sequenceNumber }.map { segment in
          Normalization.object([
            "sequence": .int(Int(segment.sequenceNumber)),
            "identifier": segment.identifier.map(Value.string),
            "type": segment.segmentType.map { .string($0.rawValue) },
            "icao_region": segment.ICAORegionCode.map(Value.string)
          ])
        })
    ])
    return record
  }
}

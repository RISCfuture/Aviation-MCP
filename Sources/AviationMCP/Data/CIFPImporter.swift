import Foundation
import MCP
import SwiftCIFP

enum CIFPImporter {
  static let revision = "cifp-adapter-2/d57301f98db1b850b9c57d823c7f7dcf996fc730"

  static func parse(_ bytes: Data) async throws -> StagedImport {
    var failures = 0
    var diagnostics: [String] = []
    let cifp = try CIFP(
      data: bytes,
      errorCallback: { error, line in
        failures += 1
        if diagnostics.count < 10 {
          diagnostics.append("Line \(line.map(String.init) ?? "unknown"): \(error)")
        }
      })
    guard failures == 0, !cifp.airports.isEmpty,
      let start = cifp.cycle.effectiveDate, let end = cifp.cycle.expirationDate
    else {
      throw StorageError.invalidImport(
        "CIFP is empty, has invalid dates or contains \(failures) rejected records. "
          + diagnostics.joined(separator: "; "))
    }
    let version = SourceVersion(
      id: UUID(), source: .cifp, cycle: String(start.ISO8601Format().prefix(10)),
      effectiveFrom: start, effectiveUntil: end, checksum: Normalization.checksum(bytes),
      parserRevision: revision, validated: false,
      validation: [
        "outcome": "blocked",
        "reason":
          "The updated CIFP adapter is pending full-distribution acceptance."
      ])
    let linked = await cifp.linked()
    var records: [AviationRecord] = []
    for airport in await linked.airports.values.sorted(by: { $0.id < $1.id }) {
      records += try await procedures(airport, versionID: version.id)
    }
    records += try CIFPAirspace.records(cifp, versionID: version.id)
    return StagedImport(versions: [version], records: records)
  }

  private static func procedures(_ airport: Airport, versionID: UUID) async throws
    -> [AviationRecord]
  {
    var records: [AviationRecord] = []
    for approach in airport.approaches {
      var record = try await ProcedureDefinition(
        identifier: approach.identifier, airport: airport.id, type: "approach",
        routeType: CIFPRestrictions.routeType(approach.routeType),
        transition: approach.transitionId,
        runways: approach.runwayId.map { [$0] } ?? [], legs: approach.legs,
        missed: approach.missedApproachLegs
      ).record(versionID: versionID)
      record.data["approach_type"] = .string(String(approach.approachType.rawValue))
      record.data["navigation_requirement"] = approach.navigationRequirement.map {
        .string(String($0.rawValue))
      }
      record.data["landing"] = approach.landing.map { .string(String($0.rawValue)) }
      record.data["levels_of_service"] = approach.levelsOfService.map(CIFPRestrictions.levels)
      record.supplemental = try Normalization.supplemental(approach)
      records.append(record)
    }
    for sid in airport.sids {
      var record = try await ProcedureDefinition(
        identifier: sid.identifier, airport: airport.id, type: "departure",
        routeType: String(sid.routeType.rawValue), transition: sid.transitionId,
        runways: sid.runwayNames.sorted(), legs: sid.legs, missed: []
      ).record(versionID: versionID)
      record.supplemental = try Normalization.supplemental(sid)
      records.append(record)
    }
    for star in airport.stars {
      var record = try await ProcedureDefinition(
        identifier: star.identifier, airport: airport.id, type: "arrival",
        routeType: String(star.routeType.rawValue), transition: star.transitionId,
        runways: star.runwayNames.sorted(), legs: star.legs, missed: []
      ).record(versionID: versionID)
      record.supplemental = try Normalization.supplemental(star)
      records.append(record)
    }
    return records
  }

}

private struct ProcedureDefinition {
  let identifier: String
  let airport: String
  let type: String
  let routeType: String?
  let transition: String?
  let runways: [String]
  let legs: [ProcedureLeg]
  let missed: [ProcedureLeg]

  func record(versionID: UUID) async throws -> AviationRecord {
    let identity = [airport, type, identifier, routeType ?? "", transition ?? ""].joined(
      separator: "/")
    var record = AviationRecord(
      versionID: versionID, kind: "procedure", id: identity, identifier: identifier,
      name: "\(airport) \(identifier) \(transition ?? "")", airport: airport)
    let main = await Self.normalizedPath(legs)
    let missedPath = await Self.normalizedPath(missed)
    record.data = [
      "airport": .string(airport), "procedure_type": .string(type),
      "runways": .array(runways.map(Value.string)), "legs": .array(main.legs),
      "missed_approach_legs": .array(missedPath.legs),
      "geometry_gaps": .array(main.path.gaps),
      "missed_approach_geometry_gaps": .array(missedPath.path.gaps),
      "geometry_scope": "determinable_IF_TF_segments",
      "obstacle_clearance_assessed": false
    ]
    record.data["transition"] = transition.map(Value.string)
    record.data["route_type"] = routeType.map(Value.string)
    record.data["missed_approach_geometry"] = missedPath.path.geometry
    record.geometry = main.path.geometry
    return record
  }

  private static func normalizedPath(_ legs: [ProcedureLeg]) async -> (
    legs: [Value], path: ProcedurePath
  ) {
    var path = ProcedurePath()
    var normalized: [Value] = []
    for leg in legs.sorted() {
      let coordinate = await leg.fix?.coordinate
      normalized.append(CIFPRestrictions.leg(leg, coordinate: coordinate))
      path.append(
        sequence: leg.sequenceNumber, terminator: leg.pathTerminator?.rawValue,
        coordinate: coordinate)
    }
    return (normalized, path)
  }
}

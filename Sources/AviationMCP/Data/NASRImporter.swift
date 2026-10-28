import Foundation
import SwiftNASR
import Synchronization

enum NASRImporter {
  static let revision = "nasr-adapter-4/2391caf97a98bce449c105db7ac75250f7ef5476"

  static func parse(_ archive: URL) async throws -> StagedImport {
    let cycle = try await NASRCycle.read(archive)
    let nasr = NASR.fromLocalArchive(archive, format: .csv)
    try await nasr.load()
    let diagnostics = try await load(nasr)
    let data = await nasr.data
    guard let start = cycle.effectiveDate,
      let end = cycle.expirationDate, let airports = await data.airports, !airports.isEmpty
    else {
      throw StorageError.invalidImport("NASR has no airports or valid cycle dates.")
    }
    let version = SourceVersion(
      id: UUID(), source: .nasr, cycle: String(start.ISO8601Format().prefix(10)),
      effectiveFrom: start, effectiveUntil: end,
      checksum: Normalization.checksum(try Data(contentsOf: archive)), parserRevision: revision,
      validated: true)
    let records = try await normalize(data, version: version)
    return StagedImport(versions: [version], records: try diagnostics.applying(to: records))
  }

  private static func load(_ nasr: NASR) async throws -> NASRDiagnostics {
    let diagnostics = Mutex(NASRDiagnostics())
    for type in [
      RecordType.airports, .navaids, .reportingPoints, .airways,
      .weatherReportingStations, .preferredRoutes, .codedDepartureRoutes,
      .ILSes, .flightServiceStations, .holds, .ARTCCFacilities, .ARTCCBoundarySegments,
      .militaryTrainingRoutes, .parachuteJumpAreas
    ] {
      let complete = try await nasr.parse(type) { error in
        diagnostics.withLock { $0.record(error) }
        return .proceed
      }
      guard complete else { throw StorageError.invalidImport("NASR parsing was interrupted.") }

    }
    return diagnostics.withLock { $0 }
  }

  private static func normalize(_ data: NASRData, version: SourceVersion) async throws
    -> [AviationRecord]
  {
    var records = try await (data.airports ?? []).map {
      try NASRAirports.record($0, versionID: version.id)
    }
    records += try await (data.navaids ?? []).map {
      try NASRNavigation.navaid($0, versionID: version.id)
    }
    records += try await (data.fixes ?? []).map {
      try NASRNavigation.fix($0, versionID: version.id)
    }
    records += try await (data.weatherStations ?? []).map {
      try NASRNavigation.weather($0, versionID: version.id)
    }
    let airwayGeometry = AirwayGeometry(
      navigation: records.filter { ["fix", "navaid"].contains($0.kind) })
    records += try await (data.airways ?? []).map {
      try airwayGeometry.resolve(NASRAirways.record($0, versionID: version.id))
    }
    records += try await (data.preferredRoutes ?? []).map {
      try NASRRoutes.preferred($0, versionID: version.id)
    }
    records += try await (data.codedDepartureRoutes ?? []).map {
      try NASRRoutes.coded($0, versionID: version.id)
    }
    records += try await (data.ILSFacilities ?? []).map {
      try NASRFacilities.ils($0, versionID: version.id)
    }
    records += try await (data.FSSes ?? []).map {
      try NASRFacilities.fss($0, versionID: version.id)
    }
    records += try await (data.holds ?? []).map {
      try NASRFacilities.hold($0, versionID: version.id)
    }
    records += try await (data.ARTCCs ?? []).map {
      try NASRAirspace.artcc($0, versionID: version.id)
    }
    records += try await (data.ARTCCBoundarySegments ?? []).map {
      try NASRAirspace.boundary($0, versionID: version.id)
    }
    records += try await (data.parachuteJumpAreas ?? []).map {
      try NASRAirspace.parachute($0, versionID: version.id)
    }
    records += try await (data.militaryTrainingRoutes ?? []).map {
      try NASRAirspace.military($0, versionID: version.id)
    }
    return records
  }

}

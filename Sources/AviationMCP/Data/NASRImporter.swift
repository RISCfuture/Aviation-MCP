import Foundation
import MCP
import SwiftNASR
import Synchronization

enum NASRImporter {
  static let revision = "nasr-adapter-8/a4d56cc686e148460a200eeff5751c2beed36847"

  static func parse(_ archive: URL) async throws -> StagedImport {
    let cycle = try await NASRCycle.read(archive)
    let nasr = NASR.fromLocalArchive(archive, format: .csv)
    try await nasr.load()
    var diagnostics = try await load(nasr)
    let frequencies = try await NASRFrequencies.read(archive)
    let data = await nasr.data
    guard let start = cycle.effectiveDate?.addingTimeInterval(SourceDiscovery.changeover),
      let end = cycle.expirationDate?.addingTimeInterval(SourceDiscovery.changeover)
    else {
      throw StorageError.invalidImport("NASR has invalid cycle dates.")
    }
    var version = SourceVersion(
      id: UUID(), source: .nasr, cycle: String(start.ISO8601Format().prefix(10)),
      effectiveFrom: start, effectiveUntil: end,
      checksum: Normalization.checksum(try Data(contentsOf: archive)), parserRevision: revision,
      validated: true)
    let records = await normalize(
      data, version: version, frequencies: frequencies, diagnostics: &diagnostics)
    guard !records.isEmpty else {
      throw StorageError.invalidImport("NASR contains no usable records.")
    }
    version.validation = diagnostics.validation
    return StagedImport(versions: [version], records: diagnostics.applying(to: records))
  }

  private static func load(_ nasr: NASR) async throws -> NASRDiagnostics {
    let diagnostics = Mutex(NASRDiagnostics())
    for type in [
      RecordType.airports, .navaids, .reportingPoints, .airways,
      .weatherReportingStations, .preferredRoutes, .codedDepartureRoutes,
      .ILSes, .flightServiceStations, .holds, .ARTCCFacilities, .ARTCCBoundarySegments,
      .militaryTrainingRoutes, .parachuteJumpAreas
    ] {
      try Task.checkCancellation()
      do {
        let complete = try await nasr.parse(type) { error in
          diagnostics.withLock { $0.record(error) }
          return .proceed
        }
        guard complete else { throw CancellationError() }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        diagnostics.withLock {
          $0.recordFamily(error, type: type)
        }
      }

    }
    return diagnostics.withLock { $0 }
  }

  private static func normalize(
    _ data: NASRData, version: SourceVersion, frequencies: NASRFrequencies,
    diagnostics: inout NASRDiagnostics
  ) async
    -> [AviationRecord]
  {
    var records = diagnostics.errors.recover(
      await data.airports ?? [], kind: "airport", identifier: \.id
    ) {
      try NASRAirports.record($0, versionID: version.id, frequencies: frequencies)
    }
    records += diagnostics.errors.recover(
      await data.navaids ?? [], kind: "navaid", identifier: \.id
    ) {
      try NASRNavigation.navaid($0, versionID: version.id)
    }
    records += diagnostics.errors.recover(
      await data.fixes ?? [], kind: "fix", identifier: \.id
    ) {
      try NASRNavigation.fix($0, versionID: version.id)
    }
    records += diagnostics.errors.recover(
      await data.weatherStations ?? [], kind: "awos", identifier: \.id
    ) {
      try NASRNavigation.weather($0, versionID: version.id)
    }
    let airwayGeometry = AirwayGeometry(
      navigation: records.filter { ["fix", "navaid"].contains($0.kind) })
    records += diagnostics.errors.recover(
      await data.airways ?? [], kind: "airway", identifier: \.id
    ) {
      try airwayGeometry.resolve(NASRAirways.record($0, versionID: version.id))
    }
    records += diagnostics.errors.recover(
      await data.preferredRoutes ?? [], kind: "preferred_route",
      identifier: \.id
    ) {
      try NASRRoutes.preferred($0, versionID: version.id)
    }
    records += diagnostics.errors.recover(
      await data.codedDepartureRoutes ?? [], kind: "coded_departure_route",
      identifier: \.id
    ) {
      try NASRRoutes.coded($0, versionID: version.id)
    }
    records += await normalizeFacilities(data, version: version, diagnostics: &diagnostics)
    return records
  }

  private static func normalizeFacilities(
    _ data: NASRData, version: SourceVersion, diagnostics: inout NASRDiagnostics
  ) async -> [AviationRecord] {
    var records = diagnostics.errors.recover(
      await data.ILSFacilities ?? [], kind: "ils", identifier: \.id
    ) {
      try NASRFacilities.ils($0, versionID: version.id)
    }
    records += diagnostics.errors.recover(
      await data.FSSes ?? [], kind: "fss", identifier: \.id
    ) {
      try NASRFacilities.fss($0, versionID: version.id)
    }
    records += diagnostics.errors.recover(
      await data.holds ?? [], kind: "hold", identifier: \.id
    ) {
      try NASRFacilities.hold($0, versionID: version.id)
    }
    records += diagnostics.errors.recover(
      await data.ARTCCs ?? [], kind: "artcc", identifier: \.id
    ) {
      try NASRAirspace.artcc($0, versionID: version.id)
    }
    records += diagnostics.errors.recover(
      await data.ARTCCBoundarySegments ?? [], kind: "artcc_boundary",
      identifier: \.id
    ) {
      try NASRAirspace.boundary($0, versionID: version.id)
    }
    records += diagnostics.errors.recover(
      await data.parachuteJumpAreas ?? [], kind: "parachute_area",
      identifier: \.id
    ) {
      try NASRAirspace.parachute($0, versionID: version.id)
    }
    records += diagnostics.errors.recover(
      await data.militaryTrainingRoutes ?? [], kind: "military_route",
      identifier: \.id
    ) {
      try NASRAirspace.military($0, versionID: version.id)
    }
    return records
  }

}

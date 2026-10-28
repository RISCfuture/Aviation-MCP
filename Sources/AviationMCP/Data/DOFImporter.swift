import Foundation
import MCP
import SwiftDOF

enum DOFImporter {
  static let revision = "dof-adapter-2/5630d134e371347c5302f0d0b17440103dbacbf8"

  static func parse(
    _ data: Data, effectiveFrom: Date, effectiveUntil: Date
  ) throws -> StagedImport {
    var failures = 0
    let dof = try DOF(data: data, errorCallback: { _, _ in failures += 1 })
    guard failures == 0, !dof.all.isEmpty,
      let currency = dof.cycle.firstDate,
      effectiveFrom >= currency, effectiveUntil > effectiveFrom
    else {
      throw StorageError.invalidImport(
        "DOF import is empty, has invalid dates or contains \(failures) rejected records.")
    }
    let version = SourceVersion(
      id: UUID(), source: .dof, cycle: dof.cycle.id,
      effectiveFrom: effectiveFrom, effectiveUntil: effectiveUntil,
      checksum: Normalization.checksum(data),
      parserRevision: revision, validated: true)
    return StagedImport(
      versions: [version],
      records: try dof.all.map {
        var result = try record($0, versionID: version.id)
        result.data["currency_date"] = .string(String(currency.ISO8601Format().prefix(10)))
        return result
      })
  }

  private static func record(_ obstacle: Obstacle, versionID: UUID) throws -> AviationRecord {
    var record = AviationRecord(
      versionID: versionID, kind: "obstacle", id: obstacle.oasNumber,
      identifier: obstacle.oasNumber, name: obstacle.type + " – " + obstacle.city)
    record.elevationMSLFeet = Double(obstacle.heightFtMSL)
    record.heightAGLFeet = Double(obstacle.heightFtAGL)
    record.geometry = Normalization.point(
      latitude: obstacle.latitudeDeg, longitude: obstacle.longitudeDeg)
    record.data = [
      "obstacle_type": .string(obstacle.type), "city": .string(obstacle.city),
      "country": .string(obstacle.country), "quantity": .int(Int(obstacle.quantity)),
      "lighting_code": .string(String(obstacle.lighting.rawValue)),
      "marking_code": .string(String(obstacle.marking.rawValue)),
      "verification_code": .string(String(obstacle.verificationStatus.rawValue)),
      "horizontal_accuracy_code": .string(String(obstacle.horizontalAccuracy.rawValue)),
      "vertical_accuracy_code": .string(String(obstacle.verticalAccuracy.rawValue)),
      "action_code": .string(String(obstacle.action.rawValue))
    ]
    record.data["state"] = obstacle.state.map(Value.string)
    record.data["source_updated_at"] = obstacle.lastUpdatedDate.map { .string($0.ISO8601Format()) }
    record.supplemental = try Normalization.supplemental(obstacle)
    return record
  }
}

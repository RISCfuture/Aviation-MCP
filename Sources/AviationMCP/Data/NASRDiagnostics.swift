import Foundation
import MCP
import SwiftNASR

struct NASRDiagnostics: Sendable {
  var errors = ImportDiagnostics()
  private var warnings: [String: [Value]] = [:]

  mutating func record(_ error: RecordParseError) {
    switch error {
    case .fieldError(let type, let id, let field, let value, _):
      let diagnostic = errors.record(
        error, kind: Self.kind(type), recordID: id,
        details: ["field": .string(field), "source_value": value.map(Value.string) ?? .null])
      store(diagnostic, kind: Self.kind(type), id: id)
    case .recordError(let type, let id, _):
      let diagnostic = errors.record(error, kind: Self.kind(type), recordID: id)
      store(diagnostic, kind: Self.kind(type), id: id)
    }
  }

  mutating func recordFamily(_ error: any Swift.Error, type: RecordType) {
    let diagnostic = errors.record(
      error, kind: Self.kind(type), details: ["phase": "record_family"])
    store(diagnostic, kind: Self.kind(type), id: nil)
  }

  private mutating func store(_ diagnostic: Value, kind: String, id: String?) {
    let key = kind == "airway" ? id?.split(separator: "/").first.map(String.init) : id
    warnings[kind + "/" + (key ?? "*"), default: []].append(diagnostic)
  }

  private static let kinds: [RecordType: String] = [
    .airports: "airport", .navaids: "navaid", .reportingPoints: "fix", .airways: "airway",
    .weatherReportingStations: "awos", .preferredRoutes: "preferred_route",
    .codedDepartureRoutes: "coded_departure_route", .ILSes: "ils", .flightServiceStations: "fss",
    .holds: "hold", .ARTCCFacilities: "artcc", .ARTCCBoundarySegments: "artcc_boundary",
    .militaryTrainingRoutes: "military_route", .parachuteJumpAreas: "parachute_area"
  ]

  static func kind(_ type: RecordType) -> String { kinds[type] ?? type.rawValue }

  func applying(to records: [AviationRecord]) -> [AviationRecord] {
    return records.map { original in
      let keys = Set([
        Self.sourceKey(original), original.kind + "/" + original.identifier, original.kind + "/*"
      ])
      let issues = keys.sorted().flatMap { warnings[$0] ?? [] }
      guard !issues.isEmpty else { return original }
      var record = original
      record.data["source_warnings"] = .array(issues)
      if ["airway", "military_route", "artcc_boundary"].contains(record.kind) {
        record.geometry = nil
        record.data["geometry_scope"] = "unavailable_due_to_parse_errors"
        record.data["geometry_limitations"] = .array([
          "Geometry is unavailable because source parsing errors may have omitted route or boundary elements."
        ])
      }
      if let runways = record.data["runways"]?.arrayValue {
        record.data["runways"] = .array(
          runways.map { runway in
            guard var fields = runway.objectValue,
              let identifier = fields["identifier"]?.stringValue,
              issues.contains(where: {
                $0.objectValue?["field"] == .string("runway[\(identifier)].materials")
              })
            else { return runway }
            fields["paved"] = .null
            return .object(fields)
          })
      }
      return record
    }
  }
  private static func sourceKey(_ record: AviationRecord) -> String {
    record.kind + "/" + (record.data["source_record_id"]?.stringValue ?? record.id)
  }
}

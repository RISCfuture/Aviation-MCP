import Foundation
import MCP
import SwiftACD
import Synchronization

enum AircraftImporter {
  static let revision = "aircraft-adapter-1/9c70df543447d3c886211aa3669fead87ce41258"

  static func parse(
    directory: URL, release: String, publishedAt: Date
  ) async throws -> StagedImport {
    let failures = Mutex(0)
    let profiles = try await Parser(directory: directory).parse { _ in failures.withLock { $0 += 1 }
    }
    guard failures.withLock({ $0 }) == 0, !profiles.isEmpty else {
      throw StorageError.invalidImport(
        "Aircraft distribution is empty or contains rejected records.")
    }
    let version = SourceVersion(
      id: UUID(), source: .aircraft, cycle: release,
      effectiveFrom: publishedAt, effectiveUntil: nil, checksum: try checksum(directory),
      parserRevision: revision, validated: true)
    return StagedImport(
      versions: [version],
      records: try profiles.values.map { try record($0, versionID: version.id) })
  }

  static func record(_ profile: AircraftProfile, versionID: UUID) throws -> AviationRecord {
    var record = AviationRecord(
      versionID: versionID, kind: "aircraft", id: profile.id,
      identifier: profile.id,
      name: [profile.identity.manufacturer, profile.identity.model].compactMap { $0 }.joined(
        separator: " "))
    record.data = categories(profile.categories)
    record.data["manufacturer"] = profile.identity.manufacturer.map(Value.string)
    record.data["model"] = profile.identity.model.map(Value.string)
    record.data["iata_codes"] = .array(profile.identity.IATACodes.map(Value.string))
    record.data["alternative_names"] = .array(profile.identity.alternativeNames.map(Value.string))
    record.data["aircraft_class"] = profile.identity.aircraftClass.map { .string($0.rawValue) }
    record.data["engine_type"] = profile.identity.engineType.map { .string($0.rawValue) }
    record.data["engine_count_code"] = profile.identity.engineCount.map { .string($0.ICAOCode) }
    record.data["dimensions"] = profile.dimensions.map(dimensions)
    record.data["weights"] = profile.weights.map(weights)
    record.data["performance"] = profile.performance.map(AircraftPerformance.normalize)
    record.data["variants"] = .array(profile.variants.map(variant))
    record.data["category_requires_variant_selection"] = .bool(
      Set(profile.variants.compactMap(\.categories.approach)).count > 1)
    record.data["contributing_sources"] = .array(
      [
        profile.sources.contains(.ACD) ? Value.string("FAA ACD") : nil,
        profile.sources.contains(.APD) ? Value.string("EUROCONTROL APD") : nil
      ].compactMap { $0 })
    record.data["approach_category_source"] = profile.categories.approach.map { _ in
      .string(profile.variants.first?.categories.approach == nil ? "EUROCONTROL APD" : "FAA ACD")
    }
    record.supplemental = try Normalization.supplemental(profile)
    return record
  }

  private static func variant(_ variant: Variant) -> Value {
    var fields = categories(variant.categories)
    fields["id"] = .string(variant.id)
    fields["manufacturer"] = variant.manufacturer.map(Value.string)
    fields["model"] = variant.model.map(Value.string)
    fields["approach_speed_kt"] = variant.approachSpeedKt.map(Value.double)
    fields["dimensions"] = variant.dimensions.map(dimensions)
    fields["weights"] = variant.weights.map(weights)
    fields["source"] = "FAA ACD"
    return .object(fields)
  }

  private static func categories(_ categories: Categories) -> [String: Value] {
    [
      "approach_category": categories.approach.map { .string($0.rawValue) },
      "airplane_design_group": categories.designGroup.map { .string($0.rawValue) },
      "taxiway_design_group": categories.taxiwayDesignGroup.map { .string($0.rawValue) },
      "wake_turbulence_category": categories.wakeTurbulence.map { .string($0.rawValue) },
      "recat_eu": categories.RECAT_EU.map { .string($0.rawValue) }
    ].compactMapValues { $0 }
  }

  private static func dimensions(_ dimensions: Dimensions) -> Value {
    Normalization.object([
      "wingspan_ft": .double(dimensions.wingspanFt),
      "length_ft": .double(dimensions.lengthFt), "tail_height_ft": .double(dimensions.tailHeightFt),
      "wingspan_with_winglets_ft": dimensions.wingspanWithWingletsFt.map(Value.double)
    ])
  }

  private static func weights(_ weights: Weights) -> Value {
    Normalization.object([
      "maximum_takeoff_weight_lb": .double(weights.MTOWLb),
      "main_gear_width_ft": weights.mainGearWidthFt.map(Value.double),
      "cockpit_to_main_gear_ft": weights.cockpitToMainGearFt.map(Value.double)
    ])
  }

  private static func checksum(_ directory: URL) throws -> String {
    guard
      let files = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    else {
      throw StorageError.invalidImport("Cannot read the aircraft distribution directory.")
    }
    let urls = files.compactMap { $0 as? URL }.filter {
      ["xlsx", "html"].contains($0.pathExtension.lowercased())
    }
    .sorted { $0.path < $1.path }
    var digests = Data()
    for url in urls {
      let metadata = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard metadata.isRegularFile == true, metadata.isSymbolicLink != true else { continue }
      digests.append(Data(url.path.replacingOccurrences(of: directory.path, with: "").utf8))
      digests.append(0)
      digests.append(Data(Normalization.checksum(try Data(contentsOf: url)).utf8))
    }
    return Normalization.checksum(digests)
  }
}

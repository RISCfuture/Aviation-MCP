import Fluent
import Foundation
import Vapor

struct PublishCommand: AsyncCommand {
  struct Signature: CommandSignature {
    @Argument(name: "bundle", help: "Validated normalized JSON bundle.") var bundle: String
  }

  var help: String { "Publish a validated source bundle atomically and purge expired data." }

  func run(using context: CommandContext, signature: Signature) async throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: signature.bundle))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let batch = try decoder.decode(StagedImport.self, from: data)
    let service = IngestionService(store: AviationStore(database: context.application.db))
    try await service.ingest(
      source: batch.versions.map(\.source.rawValue).joined(separator: "+"),
      checksum: Normalization.checksum(data), parserRevision: "normalized-bundle-1"
    ) { batch }
    context.console.info("Published \(batch.records.count) records.")
  }
}

struct PurgeCommand: AsyncCommand {
  struct Signature: CommandSignature {}
  var help: String {
    "Purge expired source versions, derived records, obsolete manifests and caches."
  }

  func run(using context: CommandContext, signature: Signature) async throws {
    try await AviationStore(database: context.application.db).purge()
    context.console.info("Expired data purged.")
  }
}

struct StageDOFCommand: AsyncCommand {
  struct Signature: CommandSignature {
    @Argument(name: "input", help: "Extracted FAA DOF data file.") var input: String
    @Argument(name: "effective-from", help: "Published release time in ISO 8601 format.")
    var effectiveFrom: String
    @Argument(name: "effective-until", help: "Next published release time in ISO 8601 format.")
    var effectiveUntil: String
    @Argument(name: "output", help: "Normalized staging bundle path.") var output: String
  }

  var help: String { "Validate and normalize a DOF distribution without a database connection." }

  func run(using context: CommandContext, signature: Signature) async throws {
    guard let start = ISO8601DateFormatter().date(from: signature.effectiveFrom),
      let end = ISO8601DateFormatter().date(from: signature.effectiveUntil)
    else {
      throw StorageError.invalidImport("Published DOF boundaries must be ISO 8601 with a timezone.")
    }
    let batch = try DOFImporter.parse(
      Data(contentsOf: URL(fileURLWithPath: signature.input)),
      effectiveFrom: start, effectiveUntil: end)
    try writeStagingBundle(batch, to: signature.output)
    context.console.info("Staged \(batch.records.count) obstacles.")
  }
}

struct StageAircraftCommand: AsyncCommand {
  struct Signature: CommandSignature {
    @Argument(name: "directory", help: "FAA workbook and optional apd HTML directory.")
    var directory: String
    @Argument(name: "release", help: "Published release identifier.") var release: String
    @Argument(name: "published-at", help: "Published effective time in ISO 8601 format.")
    var publishedAt: String
    @Argument(name: "output", help: "Normalized staging bundle path.") var output: String
  }

  var help: String {
    "Validate and normalize an aircraft release without inventing an expiration date."
  }

  func run(using context: CommandContext, signature: Signature) async throws {
    guard let publishedAt = ISO8601DateFormatter().date(from: signature.publishedAt) else {
      throw StorageError.invalidImport(
        "The published effective time must be ISO 8601 with a timezone.")
    }
    let batch = try await AircraftImporter.parse(
      directory: URL(fileURLWithPath: signature.directory),
      release: signature.release, publishedAt: publishedAt)
    try writeStagingBundle(batch, to: signature.output)
    context.console.info("Staged \(batch.records.count) aircraft profiles.")
  }
}

struct StageCIFPCommand: AsyncCommand {
  struct Signature: CommandSignature {
    @Argument(name: "input", help: "Extracted FAA CIFP file.") var input: String
    @Argument(name: "output", help: "Normalized staging bundle path.") var output: String
  }
  var help: String { "Validate and normalize CIFP procedures and airspace boundaries." }

  func run(using context: CommandContext, signature: Signature) async throws {
    let batch = try await CIFPImporter.parse(
      Data(contentsOf: URL(fileURLWithPath: signature.input)))
    try writeStagingBundle(batch, to: signature.output)
    context.console.info("Staged \(batch.records.count) CIFP records.")
  }
}

struct StageNASRCommand: AsyncCommand {
  struct Signature: CommandSignature {
    @Argument(name: "input", help: "FAA NASR CSV ZIP archive.") var input: String
    @Argument(name: "output", help: "Normalized staging bundle path.") var output: String
  }
  var help: String { "Validate and normalize a NASR CSV distribution." }

  func run(using context: CommandContext, signature: Signature) async throws {
    let batch = try await NASRImporter.parse(URL(fileURLWithPath: signature.input))
    try writeStagingBundle(batch, to: signature.output)
    context.console.info("Staged \(batch.records.count) NASR records.")
  }
}

func writeStagingBundle(_ bundle: StagedImport, to path: String) throws {
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  encoder.outputFormatting = [.sortedKeys]
  try encoder.encode(bundle).write(to: URL(fileURLWithPath: path), options: .atomic)
}

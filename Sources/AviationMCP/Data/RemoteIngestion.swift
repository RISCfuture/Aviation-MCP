import Fluent
import Foundation
import MCP
import Vapor
import ZIPFoundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct RemoteIngestionCommand: AsyncCommand {
  struct Signature: CommandSignature {
    @Argument(name: "plan", help: "Base64-encoded SourceDownload array for one publication.")
    var plan: String
  }

  var help: String { "Download, validate and publish source releases in a private ingestion job." }

  func run(using context: CommandContext, signature: Signature) async throws {
    guard let data = Data(base64Encoded: signature.plan), data.count < 32_768 else {
      throw StorageError.invalidImport("Invalid ingestion plan.")
    }
    let downloads = try JSONDecoder().decode([SourceDownload].self, from: data)
    try RemoteIngestion.validate(downloads)
    let store = AviationStore(database: context.application.db)
    let snapshot = try await store.snapshot()
    let published = Array(snapshot.versions.values) + Array(snapshot.next.values)
    if downloads.allSatisfy({ RemoteIngestion.isPublished($0, in: published) }) {
      context.console.info("The checked releases are already published.")
      return
    }
    let service = IngestionService(store: store)
    let logger = context.application.logger
    let changed = try await service.ingest(
      source: downloads.map(\.source).joined(separator: "+"),
      checksum: Normalization.checksum(data), parserRevision: "source-download-1"
    ) {
      var batch = StagedImport(versions: [], records: [])
      for download in downloads {
        logger.info(
          "Downloading and normalizing source",
          metadata: [
            "source": "\(download.source)", "cycle": "\(download.cycle)"
          ])
        let source = try await RemoteIngestion.stage(download)
        logger.info(
          "Source normalization completed",
          metadata: [
            "source": "\(download.source)", "records": "\(source.records.count)"
          ])
        batch = StagedImport(
          versions: batch.versions + source.versions, records: batch.records + source.records)
      }
      logger.info(
        "Normalized source batch", metadata: ["records": "\(batch.records.count)"])
      return batch
    }
    context.console.info(
      changed
        ? "Source publication completed."
        : "The release repeats published content; nothing changed.")
  }
}

enum RemoteIngestion {
  static func validate(_ downloads: [SourceDownload]) throws {
    let sources = Set(downloads.map(\.source))
    let allowed: [Set<String>] = [["nasr", "cifp"], ["nasr"], ["cifp"], ["dof"], ["aircraft"]]
    guard allowed.contains(sources),
      sources.count == downloads.count
    else { throw StorageError.invalidImport("Publish one source or a NASR/CIFP cycle.") }
    for download in downloads {
      guard let url = URL(string: download.url), url.scheme == "https", url.user == nil,
        url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
        allowedURL(download.url, source: download.source),
        ISO8601DateFormatter().date(from: download.effectiveFrom) != nil,
        download.effectiveUntil.map({ $0 > Date.now.ISO8601Format() }) != false,
        download.source == "aircraft" || download.effectiveUntil != nil
      else { throw StorageError.sourceRejected("Invalid or expired source download metadata.") }
    }
  }

  static func isPublished(_ download: SourceDownload, in versions: [SourceVersion]) -> Bool {
    guard download.etag != nil || download.lastModified != nil,
      let metadata = try? Value.encoded(download)
    else { return false }
    return versions.contains {
      $0.source.rawValue == download.source && $0.parserRevision == revision(download.source)
        && $0.validation?["download"] == metadata
    }
  }

  static func stage(_ download: SourceDownload) async throws -> StagedImport {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (archive, received) = try await fetch(download, to: directory)
    let batch: StagedImport
    switch download.source {
    case "nasr": batch = try await NASRImporter.parse(archive)
    case "cifp":
      batch = try await CIFPImporter.parse(extract(archive, named: "FAACIFP18", to: directory))
    case "dof":
      guard let start = ISO8601DateFormatter().date(from: download.effectiveFrom),
        let endText = download.effectiveUntil,
        let end = ISO8601DateFormatter().date(from: endText)
      else { throw StorageError.sourceRejected("DOF release boundaries are invalid.") }
      batch = try await DOFImporter.parse(
        extract(archive, named: "DOF.DAT", to: directory),
        effectiveFrom: start, effectiveUntil: end)
    case "aircraft":
      guard let start = ISO8601DateFormatter().date(from: download.effectiveFrom) else {
        throw StorageError.sourceRejected("Aircraft snapshot date is invalid.")
      }
      batch = try await AircraftImporter.parse(
        directory: directory, release: download.cycle, publishedAt: start)
    default: throw StorageError.invalidImport("Unknown source.")
    }
    let versions = try batch.versions.map { version in
      guard version.effectiveFrom.ISO8601Format() == download.effectiveFrom,
        version.effectiveUntil?.ISO8601Format() == download.effectiveUntil
      else {
        throw StorageError.sourceRejected("Parsed source dates disagree with the checked release.")
      }
      var version = version
      version.validation = (version.validation ?? [:]).merging(
        ["download": try .encoded(received)], uniquingKeysWith: { _, new in new })
      return version
    }
    return StagedImport(versions: versions, records: batch.records)
  }

  /// Downloads the release and returns it with the validators of the copy received. The FAA's CDN
  /// serves identical copies with different validators, so only an aircraft snapshot, whose
  /// release time is its Last-Modified time, must match the checked validators; the other sources
  /// are checked against the dates parsed from their content.
  private static func fetch(
    _ download: SourceDownload, to directory: URL
  ) async throws -> (URL, SourceDownload) {
    guard let url = URL(string: download.url) else {
      throw StorageError.invalidImport("Invalid URL.")
    }
    let (temporary, response) = try await StorageError.rejectingSource(
      "The source download failed"
    ) { try await URLSession.shared.download(for: URLRequest(url: url, timeoutInterval: 240)) }
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
      throw StorageError.sourceRejected("The source download failed; check it again.")
    }
    var received = download
    received.etag = response.value(forHTTPHeaderField: "ETag")
    received.lastModified = response.value(forHTTPHeaderField: "Last-Modified")
    guard download.source != "aircraft" || received.lastModified == download.lastModified else {
      throw StorageError.sourceRejected("The aircraft snapshot changed; check it again.")
    }
    let destination = directory.appendingPathComponent(
      download.source == "aircraft" ? "FAA.xlsx" : "source.zip")
    try FileManager.default.moveItem(at: temporary, to: destination)
    return (destination, received)
  }

  private static func extract(
    _ archive: URL, named name: String, to directory: URL
  ) async throws -> Data {
    let contents = directory.appendingPathComponent("extracted")
    try await StorageError.rejectingSource("The distribution could not be extracted") {
      try FileManager.default.unzipItem(at: archive, to: contents)
    }
    let files = FileManager.default.enumerator(at: contents, includingPropertiesForKeys: nil)
    let matches =
      files?.compactMap { $0 as? URL }.filter {
        $0.lastPathComponent.uppercased() == name
      } ?? []
    guard matches.count == 1, let file = matches.first else {
      throw StorageError.sourceRejected("Distribution must contain exactly one \(name) file.")
    }
    return try Data(contentsOf: file)
  }

  private static func revision(_ source: String) -> String {
    switch source {
    case "nasr": NASRImporter.revision
    case "cifp": CIFPImporter.revision
    case "dof": DOFImporter.revision
    default: AircraftImporter.revision
    }
  }

  private static func allowedURL(_ url: String, source: String) -> Bool {
    let pattern: String
    switch source {
    case "nasr":
      pattern =
        #"^https://nfdc\.faa\.gov/webContent/28DaySub/extra/\d{2}_[A-Z][a-z]{2}_\d{4}_CSV\.zip$"#
    case "cifp": pattern = #"^https://aeronav\.faa\.gov/Upload_313-d/cifp/CIFP_\d{6}\.zip$"#
    case "dof": pattern = #"^https://aeronav\.faa\.gov/Obst_Data/DOF_\d{6}\.zip$"#
    default: return url == SourceDiscovery.aircraftWorkbook && source == "aircraft"
    }
    return url.range(of: pattern, options: .regularExpression) != nil
  }
}

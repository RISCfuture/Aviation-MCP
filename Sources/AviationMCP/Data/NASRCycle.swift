import Foundation
import StreamingCSV
import SwiftNASR

enum NASRCycle {
  static func read(_ archive: URL) async throws -> Cycle {
    let distribution = try ArchiveFileDistribution(location: archive, format: .csv)
    guard let path = try distribution.findFile(prefix: "APT_BASE.csv") else {
      throw StorageError.invalidImport("NASR archive is missing APT_BASE.csv.")
    }
    return try await parse(distribution.readFileRaw(path: path, progress: nil))
  }

  static func parse(_ chunks: AsyncThrowingStream<Data, any Swift.Error>) async throws -> Cycle {
    var column: Int?
    var effectiveDate: String?
    for try await row in StreamingCSVReader.stream(from: chunks) {
      let fields = row.stringFields
      guard let index = column else {
        guard let index = fields.firstIndex(of: "EFF_DATE") else {
          throw StorageError.invalidImport("NASR airport data has no EFF_DATE column.")
        }
        column = index
        continue
      }
      guard fields.indices.contains(index), !fields[index].isEmpty,
        effectiveDate == nil || effectiveDate == fields[index]
      else {
        throw StorageError.invalidImport(
          "NASR airport rows have missing or inconsistent effective dates.")
      }
      effectiveDate = fields[index]
    }
    guard let effectiveDate,
      let cycle = Cycle(effectiveDate.replacingOccurrences(of: "/", with: "-")),
      let instant = cycle.effectiveDate, String(instant.ISO8601Format().prefix(10)) == cycle.id,
      Cycle.effectiveCycle(for: instant) == cycle
    else {
      throw StorageError.invalidImport("NASR effective date is not a valid cycle boundary.")
    }
    return cycle
  }
}

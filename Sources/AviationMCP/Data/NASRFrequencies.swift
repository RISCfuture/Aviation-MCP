import Foundation
import MCP
import StreamingCSV
import SwiftNASR

/// Airport communications from the NASR frequency file, of which SwiftNASR keeps only CTAF and
/// UNICOM.
struct NASRFrequencies: Sendable {
  private static let file = "FRQ.csv"

  private var airports: [String: AirportCommunications] = [:]

  static func read(_ archive: URL) async throws -> Self {
    let distribution = try ArchiveFileDistribution(location: archive, format: .csv)
    guard let path = try distribution.findFile(prefix: file) else {
      throw StorageError.invalidImport("NASR archive is missing \(file).")
    }
    return try await parse(distribution.readFileRaw(path: path, progress: nil))
  }

  static func parse(_ chunks: AsyncThrowingStream<Data, any Swift.Error>) async throws -> Self {
    var header: [String: Int]?
    var frequencies = Self()
    for try await row in StreamingCSVReader.stream(from: chunks) {
      let fields = row.stringFields
      guard let header else {
        header = Dictionary(fields.enumerated().map { ($1, $0) }) { first, _ in first }
        continue
      }
      frequencies.add(FrequencyRow(fields: fields, header: header))
    }
    return frequencies
  }

  /// The airport fields for an FAA location identifier, empty when the file lists none.
  func fields(forAirport identifier: String) -> [String: Value] {
    airports[identifier]?.fields ?? [:]
  }

  private mutating func add(_ row: FrequencyRow) {
    guard let airport = row["SERVICED_FACILITY"],
      row["SERVICED_SITE_TYPE"].flatMap(Airport.FacilityType.init) != nil
    else { return }
    airports[airport, default: .init()].add(row)
  }
}

private struct FrequencyRow {
  let fields: [String]
  let header: [String: Int]

  /// The frequency's use, qualified by the sector it serves.
  var use: String? {
    guard let use = self["FREQ_USE"] else { return nil }
    return self["SECTORIZATION"].map { "\(use) (\($0))" } ?? use
  }

  subscript(column: String) -> String? {
    guard let index = header[column], fields.indices.contains(index) else { return nil }
    let value = fields[index].trimmingCharacters(in: .whitespaces)
    return value.isEmpty ? nil : value
  }
}

private struct AirportCommunications: Sendable {
  private static let kilohertzPerMegahertz = 1000.0
  private static let towerFacilityPrefix = "ATCT"

  private var towerHours: String?
  private var towerCall: String?
  private var approachCall: String?
  private var groups: [FrequencyGroup] = []
  private var groupIndices: [String: Int] = [:]

  var fields: [String: Value] {
    NASRNormalization.fields([
      "tower_hours": towerHours.map(Value.string), "tower_call": towerCall.map(Value.string),
      "approach_call": approachCall.map(Value.string),
      "frequencies": .array(groups.map(\.value))
    ])
  }

  mutating func add(_ row: FrequencyRow) {
    if let frequency = row["FREQ"] {
      add(frequency: frequency, facility: row["FACILITY"], use: row.use, remark: row["REMARK"])
    }
    towerHours = towerHours ?? row["TOWER_HRS"]
    approachCall = approachCall ?? row["PRIMARY_APPROACH_RADIO_CALL"]
    if row["FACILITY_TYPE"]?.hasPrefix(Self.towerFacilityPrefix) == true {
      towerCall = towerCall ?? row["TOWER_OR_COMM_CALL"]
    }
  }

  private mutating func add(frequency: String, facility: String?, use: String?, remark: String?) {
    let key = (facility ?? "") + "/" + frequency
    let index = groupIndices[key] ?? groups.count
    if index == groups.count {
      groupIndices[key] = index
      groups.append(FrequencyGroup(facility: facility, frequency: frequency))
    }
    groups[index].add(use: use, remark: remark)
  }

  private struct FrequencyGroup: Sendable {
    let facility: String?
    let frequency: String
    private var uses: [String] = []
    private var remarks: [String] = []

    var value: Value {
      let kilohertz = Double(frequency).flatMap {
        UInt(exactly: ($0 * kilohertzPerMegahertz).rounded())
      }
      return Normalization.object([
        "facility": facility.map(Value.string),
        "frequency": NASRNormalization.frequency(kilohertz: kilohertz),
        "frequency_text": kilohertz == nil ? .string(frequency) : nil,
        "uses": .array(uses.map(Value.string)),
        "remarks": remarks.isEmpty ? nil : .array(remarks.map(Value.string))
      ])
    }

    init(facility: String?, frequency: String) {
      self.facility = facility
      self.frequency = frequency
    }

    mutating func add(use: String?, remark: String?) {
      if let use, !uses.contains(use) { uses.append(use) }
      if let remark, !remarks.contains(remark) { remarks.append(remark) }
    }
  }
}

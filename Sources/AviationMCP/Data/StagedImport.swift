import Crypto
import Foundation
import MCP

struct StagedImport: Codable, Sendable {
  let versions: [SourceVersion]
  let records: [AviationRecord]

  /// Whether each version repeats the cycle, content and parser of a published version.
  func isPublished(in published: [SourceVersion]) -> Bool {
    !versions.isEmpty
      && versions.allSatisfy { version in
        published.contains {
          $0.source == version.source && $0.cycle == version.cycle
            && $0.checksum == version.checksum && $0.parserRevision == version.parserRevision
        }
      }
  }
}

enum Normalization {
  static func jsonText(_ value: Value) throws -> String {
    guard let text = String(data: try JSONEncoder().encode(value), encoding: .utf8) else {
      throw StorageError.invalidImport("Normalized JSON is not UTF-8.")
    }
    return text
  }

  static func checksum(_ data: Data) -> String {
    SHA256.hash(data: data).map { byte in
      let hex = String(byte, radix: 16)
      return hex.count == 1 ? "0" + hex : hex
    }.joined()
  }

  static func point(latitude: Double, longitude: Double) -> Value {
    .object(["type": "Point", "coordinates": .array([.double(longitude), .double(latitude)])])
  }

  static func object(_ fields: [String: Value?]) -> Value {
    .object(fields.compactMapValues { $0 })
  }

  static func encodedFields(_ record: some Encodable) throws -> [String: Value] {
    try Value.encoded(record).objectValue ?? [:]
  }
}

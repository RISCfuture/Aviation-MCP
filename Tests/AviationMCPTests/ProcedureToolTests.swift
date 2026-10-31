import Foundation
import MCP
import Testing

@testable import AviationMCP

extension `Transactional publication` {
  @Test
  func `summarizes procedures and expands a named transition through the catalog`() async throws {
    try await withDatabase { store in
      let catalog = ToolCatalog(
        store: store, groups: [.procedures],
        weather: WeatherService(awc: nil, openMeteo: nil), notams: nil)
      try await Self.publishApproach(store)
      let summaries = try await catalog.call(
        .init(name: "find_procedures", arguments: ["airport": "KBOS"]))
      let summary = try #require(Self.results(summaries).first?.objectValue)
      #expect(summary["legs"] == nil)
      #expect(summary["fixes"] != nil)
      let sources = try #require(
        summaries.structuredContent?.objectValue?["sources"]?.arrayValue?.first?.objectValue)
      #expect(Set(sources.keys) == ["source", "cycle", "effectiveFrom", "effectiveUntil"])
      let expanded = try await catalog.call(
        .init(
          name: "get_procedure",
          arguments: ["identifier": "I04R", "airport": "KBOS", "transition": "GOSHI"]))
      let procedure = try #require(Self.results(expanded).first?.objectValue)
      #expect(
        procedure["legs"]?.arrayValue?.map { $0.objectValue?["fix"] } == [
          "GOSHI", "WINNI", "WINNI", "RW04R"
        ])
      #expect(procedure["available_transitions"]?.arrayValue?.count == 1)
      let misspelled = try await catalog.call(
        .init(
          name: "get_procedure",
          arguments: ["identifier": "I04R", "airport": "KBOS", "transition": "GOSHY"]))
      #expect(
        misspelled.structuredContent?.objectValue?["error"]?.objectValue?["code"]
          == "invalid_argument")
      let unsupported = try await catalog.call(
        .init(name: "get_procedure", arguments: ["identifier": "I04R", "query": "ILS"]))
      #expect(unsupported.isError == true)
    }
  }

  static func publishApproach(_ store: AviationStore) async throws {
    let nasr = Self.version(.nasr)
    let cifp = Self.version(.cifp)
    let segments: [(transition: String?, fixes: [String])] = [
      (nil, ["WINNI", "RW04R"]), ("GOSHI", ["GOSHI", "WINNI"])
    ]
    let procedures = segments.map { transition, fixes in
      var record = AviationRecord(
        versionID: cifp.id, kind: "procedure", id: "KBOS/I04R/\(transition ?? "")",
        identifier: "I04R", name: "KBOS I04R", airport: "KBOS")
      record.data = [
        "airport": "KBOS", "procedure_type": "approach",
        "legs": .array(fixes.map { .object(["fix": .string($0)]) })
      ]
      record.data["transition"] = transition.map(Value.string)
      return record
    }
    try await store.publish([nasr, cifp], records: [.fixture(nasr)] + procedures)
  }

  static func results(_ result: CallTool.Result) -> [Value] {
    result.structuredContent?.objectValue?["results"]?.arrayValue ?? []
  }
}

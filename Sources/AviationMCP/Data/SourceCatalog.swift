import Foundation
import MCP

enum SourceName: String, Codable, CaseIterable, Sendable {
  case nasr, cifp, dof, aircraft
}

struct SourceVersion: Codable, Sendable {
  let id: UUID
  let source: SourceName
  let cycle: String
  let effectiveFrom: Date
  let effectiveUntil: Date?
  let checksum: String
  let parserRevision: String
  var validated: Bool
  var importedAt: Date = .now
  var validation: [String: Value]?
}

struct SourceSnapshot: Sendable {
  let versions: [SourceName: SourceVersion]
  var next: [SourceName: SourceVersion] = [:]

  var token: String {
    versions.values.map { $0.id.uuidString }.sorted().joined(separator: ",")
  }
}

struct SourceCatalog: Sendable {
  let versions: [SourceVersion]

  func snapshot(at instant: Date) -> SourceSnapshot {
    let eligible = versions.filter { $0.isEffective(at: instant) }.sorted(by: newestFirst)
    var selected: [SourceName: SourceVersion] = [:]
    for source in [SourceName.dof, .aircraft] {
      selected[source] = eligible.first { $0.source == source }
    }
    for nasr in eligible where nasr.source == .nasr {
      if let cifp = eligible.first(where: {
        $0.source == .cifp && $0.cycle == nasr.cycle
          && $0.effectiveFrom == nasr.effectiveFrom && $0.effectiveUntil == nasr.effectiveUntil
      }) {
        selected[.nasr] = nasr
        selected[.cifp] = cifp
        break
      }
    }
    let next = Dictionary(
      uniqueKeysWithValues: retained(at: instant).filter {
        $0.effectiveFrom > instant
      }.map { ($0.source, $0) })
    return SourceSnapshot(versions: selected, next: next)
  }

  func retained(at instant: Date) -> [SourceVersion] {
    SourceName.allCases.flatMap { source in
      let candidates = versions.filter { $0.source == source && $0.validated }
      let current = candidates.filter { $0.isEffective(at: instant) }.sorted(by: newestFirst).first
      let next = candidates.filter { $0.effectiveFrom > instant }.sorted {
        $0.effectiveFrom == $1.effectiveFrom
          ? $0.importedAt > $1.importedAt : $0.effectiveFrom < $1.effectiveFrom
      }.first
      return [current, next].compactMap { $0 }
    }
  }
}

extension SourceVersion {
  func isEffective(at instant: Date) -> Bool {
    validated && effectiveFrom <= instant && effectiveUntil.map { instant < $0 } != false
  }
}

private func newestFirst(_ left: SourceVersion, _ right: SourceVersion) -> Bool {
  left.effectiveFrom == right.effectiveFrom
    ? left.importedAt > right.importedAt : left.effectiveFrom > right.effectiveFrom
}

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
  private static let awaitingReplacement =
    "The replacement release scheduled for that time has not been published yet; "
    + "it is published as soon as the FAA posts it and it passes validation."

  let versions: [SourceName: SourceVersion]
  var next: [SourceName: SourceVersion] = [:]
  /// The most recently expired version of each source that has no effective version.
  var lapsed: [SourceName: SourceVersion] = [:]

  var token: String {
    versions.values.map { $0.id.uuidString }.sorted().joined(separator: ",")
  }

  /// Returns the effective version of a source, or throws an error explaining its absence.
  func require(_ source: SourceName) throws -> SourceVersion {
    guard let version = versions[source] else {
      throw StorageError.unavailable(source, reason: unavailability(of: source))
    }
    return version
  }

  /// Explains why a source has no effective version and when one is expected.
  func unavailability(of source: SourceName) -> String? {
    guard versions[source] == nil else { return nil }
    let expired = lapsed[source].flatMap { version in
      version.effectiveUntil.map {
        "\(source.rawValue) release \(version.cycle) expired at \($0.ISO8601Format())."
      }
    }
    let expected =
      next[source].map {
        "Release \($0.cycle) becomes effective at \($0.effectiveFrom.ISO8601Format())."
      } ?? expired.map { _ in Self.awaitingReplacement }
    let explanation = [expired, expected].compactMap(\.self)
    return explanation.isEmpty ? nil : explanation.joined(separator: " ")
  }

  /// The newest published version of a source, against which a replacement is compared.
  func baseline(for source: SourceName) -> SourceVersion? {
    next[source] ?? versions[source] ?? lapsed[source]
  }
}

struct SourceCatalog: Sendable {
  let versions: [SourceVersion]

  /// Validated versions, keeping only the latest import of each source cycle.
  private var imports: [SourceVersion] {
    Dictionary(grouping: versions.filter(\.validated)) { "\($0.source.rawValue)/\($0.cycle)" }
      .values.compactMap { $0.max { $0.importedAt < $1.importedAt } }
  }

  func snapshot(at instant: Date) -> SourceSnapshot {
    let eligible = imports.filter { $0.isEffective(at: instant) }.sorted(by: newestFirst)
    var selected = Dictionary(eligible.map { ($0.source, $0) }) { newest, _ in newest }
    if let nasr = selected[.nasr], let cifp = selected[.cifp], nasr.cycle != cifp.cycle {
      selected[.cifp] = nil
    }
    let retained = retained(at: instant)
    return SourceSnapshot(
      versions: selected,
      next: Dictionary(
        uniqueKeysWithValues: retained.filter { $0.effectiveFrom > instant }.map { ($0.source, $0) }
      ),
      lapsed: Dictionary(
        uniqueKeysWithValues: retained.filter { $0.isExpired(at: instant) }.map { ($0.source, $0) })
    )
  }

  /// The current and nearest next version of each source, or the most recently expired version
  /// of a source with no current version, which explains that source's unavailability.
  func retained(at instant: Date) -> [SourceVersion] {
    let imports = imports
    return SourceName.allCases.flatMap { source in
      let candidates = imports.filter { $0.source == source }
      let current = candidates.filter { $0.isEffective(at: instant) }.max(by: olderFirst)
      let next = candidates.filter { $0.effectiveFrom > instant }.min(by: earlierFirst)
      let lapsed =
        current == nil
        ? candidates.filter { $0.isExpired(at: instant) }.max {
          ($0.effectiveUntil ?? .distantPast) < ($1.effectiveUntil ?? .distantPast)
        } : nil
      return [current, next, lapsed].compactMap(\.self)
    }
  }
}

extension SourceVersion {
  func isEffective(at instant: Date) -> Bool {
    validated && effectiveFrom <= instant && effectiveUntil.map { instant < $0 } != false
  }

  func isExpired(at instant: Date) -> Bool {
    effectiveUntil.map { $0 <= instant } == true
  }
}

private func newestFirst(_ left: SourceVersion, _ right: SourceVersion) -> Bool {
  left.effectiveFrom == right.effectiveFrom
    ? left.importedAt > right.importedAt : left.effectiveFrom > right.effectiveFrom
}

private func olderFirst(_ left: SourceVersion, _ right: SourceVersion) -> Bool {
  newestFirst(right, left)
}

private func earlierFirst(_ left: SourceVersion, _ right: SourceVersion) -> Bool {
  left.effectiveFrom == right.effectiveFrom
    ? left.importedAt > right.importedAt : left.effectiveFrom < right.effectiveFrom
}

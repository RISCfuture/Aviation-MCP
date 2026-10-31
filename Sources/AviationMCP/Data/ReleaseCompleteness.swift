public import Foundation
import MCP

/// Refuses to publish a release that lost data a published release of the same source contains.
struct ReleaseCompleteness {
  /// The validation key listing record families that failed to parse as a whole.
  static let failedFamiliesKey = "failed_record_families"
  private static let maximumCountDrop = 0.1
  private static let minimumComparableCount = 100

  let baselines: [SourceName: SourceVersion]

  init(snapshot: SourceSnapshot) {
    baselines = Dictionary(
      uniqueKeysWithValues: SourceName.allCases.compactMap { source in
        snapshot.baseline(for: source).map { (source, $0) }
      })
  }

  func verify(_ staged: StagedImport) throws {
    let counts = Dictionary(grouping: staged.records, by: \.versionID).mapValues { records in
      Dictionary(grouping: records, by: \.kind).mapValues(\.count)
    }
    let problems = staged.versions.flatMap { version in
      Self.failedFamilies(version) + missingRecords(version, counts: counts[version.id] ?? [:])
    }
    guard problems.isEmpty else { throw IncompleteReleaseError(problems: problems) }
  }

  private static func failedFamilies(_ version: SourceVersion) -> [String] {
    (version.validation?[failedFamiliesKey]?.arrayValue ?? []).compactMap(\.stringValue).map {
      "\(version.source.rawValue) \(version.cycle): the \($0) record family failed to parse."
    }
  }

  private func missingRecords(_ version: SourceVersion, counts: [String: Int]) -> [String] {
    guard let baseline = baselines[version.source],
      let published = baseline.validation?["record_counts"]?.objectValue
    else { return [] }
    return published.keys.sorted().compactMap { kind in
      guard let expected = published[kind]?.intValue,
        Self.isMissing(counts[kind] ?? 0, expected: expected)
      else { return nil }
      return "\(version.source.rawValue) \(version.cycle): \(counts[kind] ?? 0) \(kind) records, "
        + "compared with \(expected) in published release \(baseline.cycle)."
    }
  }

  private static func isMissing(_ count: Int, expected: Int) -> Bool {
    expected > 0 && count == 0
      || expected >= minimumComparableCount
        && Double(count) < Double(expected) * (1 - maximumCountDrop)
  }
}

/// A staged release that is withheld from publication because it is incomplete.
public struct IncompleteReleaseError: LocalizedError {
  /// The process exit status that reports a withheld release to the ingestion workflow.
  public static let exitStatus: Int32 = 3

  /// Each way in which the staged release is incomplete.
  public let problems: [String]

  public var errorDescription: String? { "Release withheld from publication." }

  public var failureReason: String? {
    "The release is incomplete, so the published data is unchanged: "
      + problems.joined(separator: " ")
  }
}

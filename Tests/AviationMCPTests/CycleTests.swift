import Foundation
import Testing

@testable import AviationMCP

@Suite
struct `Effective source cycles` {
  private let boundary = Date(timeIntervalSince1970: 2_000_000_000)

  @Test
  func `changes NASR and CIFP together at the effective boundary`() throws {
    let versions = [
      version(.nasr, "old", -100, 0), version(.cifp, "old", -100, 0),
      version(.nasr, "next", 0, 100), version(.cifp, "next", 0, 100),
      version(.dof, "independent", -50, 50)
    ]
    let before = SourceCatalog(versions: versions).snapshot(at: boundary.addingTimeInterval(-1))
    let after = SourceCatalog(versions: versions).snapshot(at: boundary)
    #expect(before.versions[.nasr]?.cycle == "old")
    #expect(before.versions[.cifp]?.cycle == "old")
    #expect(after.versions[.nasr]?.cycle == "next")
    #expect(after.versions[.cifp]?.cycle == "next")
    #expect(before.versions[.dof]?.id == after.versions[.dof]?.id)
    #expect(before.token != after.token)
  }

  @Test
  func `serves NASR without CIFP and explains why CIFP is unavailable`() throws {
    let versions = [
      version(.nasr, "old", -100, 0), version(.cifp, "old", -100, 0),
      version(.nasr, "next", 0, 100), version(.dof, "current", -50, 50)
    ]
    let snapshot = SourceCatalog(versions: versions).snapshot(at: boundary)
    #expect(snapshot.versions[.nasr]?.cycle == "next")
    #expect(snapshot.versions[.cifp] == nil)
    #expect(snapshot.versions[.dof]?.cycle == "current")
    #expect(snapshot.unavailability(of: .nasr) == nil)
    let reason = try #require(snapshot.unavailability(of: .cifp))
    #expect(reason.contains("release old expired at \(boundary.ISO8601Format())"))
    #expect(reason.contains("has not been published yet"))
    #expect(throws: StorageError.self) { try snapshot.require(.cifp) }
  }

  @Test
  func `keeps a published aircraft snapshot without inventing expiration`() {
    let old = version(.aircraft, "release-1", -100, nil)
    let next = version(.aircraft, "release-2", 50, nil)
    let catalog = SourceCatalog(versions: [old, next])
    #expect(catalog.snapshot(at: boundary).versions[.aircraft]?.id == old.id)
    #expect(
      catalog.snapshot(at: boundary.addingTimeInterval(50)).versions[.aircraft]?.id == next.id
    )
    #expect(
      catalog.snapshot(at: boundary.addingTimeInterval(1_000)).versions[.aircraft]?.id == next.id
    )
  }

  @Test
  func `excludes failed imports and retains only current and nearest next versions`() {
    let current = version(.dof, "current", -10, 10)
    let next = version(.dof, "next", 10, 20)
    var corrected = version(.dof, "current", -10, 10)
    corrected.importedAt = current.importedAt.addingTimeInterval(1)
    let later = version(.dof, "later", 20, 30)
    let expired = version(.dof, "expired", -20, -10)
    var failed = version(.dof, "failed", -1, 10)
    failed.validated = false
    var restamped = version(.dof, "next", 11, 20)
    restamped.importedAt = next.importedAt.addingTimeInterval(1)
    let catalog = SourceCatalog(versions: [
      expired, current, failed, next, later, corrected, restamped
    ])
    #expect(catalog.snapshot(at: boundary).versions[.dof]?.id == corrected.id)
    #expect(Set(catalog.retained(at: boundary).map(\.id)) == Set([corrected.id, restamped.id]))
    #expect(catalog.retained(at: boundary.addingTimeInterval(40)).map(\.id) == [later.id])
  }

  private func version(_ source: SourceName, _ cycle: String, _ start: Double, _ end: Double?)
    -> SourceVersion
  {
    SourceVersion(
      id: UUID(),
      source: source,
      cycle: cycle,
      effectiveFrom: boundary.addingTimeInterval(start),
      effectiveUntil: end.map { boundary.addingTimeInterval($0) },
      checksum: "fixture",
      parserRevision: "fixture",
      validated: true
    )
  }
}

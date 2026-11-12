import Foundation
import MCP
import Testing

@testable import AviationMCP

@Suite
struct `Route grammar` {
  @Test
  func `classifies each element by its form`() throws {
    let words = try RouteGrammar.parse(
      "n0450f350 KOAK.SNS V25 PRB/N0450F350 DCT 3730N12200W 37S122E SNS090020")
    #expect(
      words.map(\.token) == [
        .speedLevel, .name("KOAK"), .name("SNS"), .name("V25"), .name("PRB"), .direct,
        .coordinate(GeoPoint(latitude: 37.5, longitude: -122)),
        .coordinate(GeoPoint(latitude: -37, longitude: 122)),
        .placeBearingDistance(place: "SNS", bearingMagneticDeg: 90, distanceNM: 20)
      ])
    #expect(words[4].speedLevel == "N0450F350")
    #expect(words[4].text == "PRB/N0450F350")
  }

  @Test
  func `rejects empty, oversized and malformed routes`() throws {
    #expect(throws: ToolInputError.self) { try RouteGrammar.parse(" . ") }
    #expect(throws: ToolInputError.self) {
      try RouteGrammar.parse(Array(repeating: "DCT", count: 61).joined(separator: " "))
    }
    let error = try #require(throws: ToolInputError.self) {
      try RouteGrammar.parse("KOAK A$B")
    }
    #expect(error.reason.contains("Element 1 (A$B)"))
    #expect(throws: ToolInputError.self) { try RouteGrammar.parse("DCT/N0450F350 KOAK") }
    #expect(throws: ToolInputError.self) { try RouteGrammar.parse("9960N12200W KOAK") }
  }
}

@Suite
struct `Route assembly` {
  @Test
  func `anchors airway endpoints that are ambiguous on their own, in both directions`() throws {
    let navigation = [
      Self.point("SNS", 36.66, -121.6, kind: "navaid"),
      Self.point("SNS", 36.66, -121.61, kind: "airport", id: "SNS-airport"),
      Self.point("PRB", 35.67, -120.63, kind: "navaid"), Self.v25
    ]
    let forward = try Self.assemble("SNS V25 PRB", navigation)
    #expect(forward.runs.count == 1)
    #expect(forward.runs[0].map(\.identifier) == ["SNS", "MID", "PRB"])
    #expect(forward.elements.map { $0["resolution"] } == ["anchored", "unique", "anchored"])
    #expect(forward.runs[0][1].published["published_course_magnetic_deg"] == 128)
    #expect(forward.runs[0][1].published["published_distance_nm"] == 30)
    #expect(forward.runs[0][1].via == "V25")
    #expect(!forward.isBroken)
    #expect(forward.warnings.isEmpty)

    let reverse = try Self.assemble("PRB V25 SNS", navigation)
    #expect(reverse.runs[0].map(\.identifier) == ["PRB", "MID", "SNS"])
    #expect(reverse.elements[1]["reversed"] == true)
    // The leg into SNS is the published SNS-to-MID segment flown backwards.
    #expect(reverse.runs[0][2].published["published_course_magnetic_deg"] == 308)
    #expect(reverse.runs[0][2].published["published_distance_nm"] == 30)
    #expect(reverse.runs[0][2].published["airway_direction"] == "reversed")
  }

  @Test
  func `never chooses among duplicate identifiers, however near one is`() throws {
    let navigation = [
      Self.point("AAA", 37, -122), Self.point("BBB", 37, -121),
      Self.point("DUPE", 37, -121.5, id: "near"), Self.point("DUPE", 10, 100, id: "far")
    ]
    let ambiguous = try Self.assemble("AAA DUPE BBB", navigation)
    let element = ambiguous.elements[1]
    #expect(element["kind"] == "unresolved")
    let candidates = try #require(element["candidates"]?.arrayValue)
    #expect(candidates.map { $0.objectValue?["id"] } == ["near", "far"])
    let near = try #require(candidates.first?.objectValue)
    #expect(try #require(near["distance_from_previous_nm"]?.doubleValue) < 30)
    #expect(try #require(near["distance_to_next_nm"]?.doubleValue) < 30)
    #expect(ambiguous.runs.map { $0.map(\.identifier) } == [["AAA"], ["BBB"]])
    #expect(ambiguous.isBroken)
    #expect(ambiguous.warnings.count == 1)

    let selected = try Self.assemble("AAA DUPE BBB", navigation, selections: [1: "near"])
    #expect(selected.runs.map { $0.map(\.identifier) } == [["AAA", "DUPE", "BBB"]])
    #expect(selected.elements[1]["resolution"] == "selected")
    #expect(!selected.isBroken)

    #expect(throws: ToolInputError.self) {
      try Self.assemble("AAA DUPE BBB", navigation, selections: [1: "elsewhere"])
    }
    #expect(throws: ToolInputError.self) {
      try Self.assemble("AAA DUPE BBB", navigation, selections: [0: "AAA", 2: "nothing"])
    }
    #expect(throws: ToolInputError.self) {
      try Self.assemble("AAA DUPE BBB", navigation, selections: [7: "near"])
    }
  }

  @Test
  func `leaves unknown and misplaced elements unresolved and resolves the rest`() throws {
    let navigation = [
      Self.point("AAA", 37, -122), Self.point("BBB", 37, -121),
      Self.point("KMID", 37, -121.5, kind: "airport")
    ]
    let foreign = try Self.assemble("AAA EGLL BBB", navigation)
    #expect(foreign.elements[1]["kind"] == "unresolved")
    #expect(foreign.elements[1]["reason"]?.stringValue?.contains("United States only") == true)
    #expect(foreign.runs.map { $0.map(\.identifier) } == [["AAA"], ["BBB"]])

    let overflown = try Self.assemble("AAA KMID BBB", navigation)
    #expect(overflown.elements[1]["reason"]?.stringValue?.contains("first or last") == true)

    // A VOR test facility shares its airport's identifier but is not a route point.
    let tested = try Self.assemble(
      "AAA BBB",
      navigation + [
        Self.point("BBB", 37, -121.01, kind: "navaid", id: "vot", data: ["facility_type": "VOT"])
      ])
    #expect(tested.elements[1]["record_id"] == "BBB")

    let endpoint = try Self.assemble("KMID DCT BBB", navigation)
    #expect(endpoint.elements.map { $0["kind"] } == ["airport", "direct", "fix"])
    #expect(endpoint.runs.map { $0.map(\.identifier) } == [["KMID", "BBB"]])
    #expect(throws: ToolInputError.self) { try Self.assemble("AAA N0450F350", navigation) }
    #expect(throws: ToolInputError.self) { try Self.assemble("AAA DCT", navigation) }
    #expect(throws: ToolInputError.self) { try Self.assemble("DCT DCT", navigation) }
  }

  @Test
  func `splits the path at an airway gap and at a point without a position`() throws {
    var segments = Self.v25Segments
    segments[1]["airway_gap"] = true
    let gapped = try Self.assemble("SNS V25 PRB", [Self.airway("V25", segments)])
    #expect(gapped.runs.map { $0.map(\.identifier) } == [["SNS", "MID"], ["PRB"]])
    #expect(gapped.gaps.count == 1)
    #expect(gapped.gaps.first?.objectValue?["sequence"] == 20)
    #expect(gapped.isBroken)

    var unlocated = Self.v25Segments
    unlocated[1]["position"] = nil
    let missing = try Self.assemble("SNS V25 PRB", [Self.airway("V25", unlocated)])
    #expect(missing.runs.map { $0.map(\.identifier) } == [["SNS"], ["PRB"]])
    #expect(missing.gaps.count == 2)
  }

  @Test
  func `joins adjacent airways at their only shared point`() throws {
    let second = Self.airway(
      "V27",
      [
        Self.segment("PRB", 30, 35.67, -120.63, distance: 40, course: 100, opposite: 280),
        Self.segment("END", 40, 35.5, -119.9)
      ])
    let joined = try Self.assemble("SNS V25 V27 END", [Self.v25, second])
    #expect(joined.runs.map { $0.map(\.identifier) } == [["SNS", "MID", "PRB", "END"]])
    #expect(joined.elements[1]["exit"] == "PRB")
    #expect(joined.elements[2]["entry"] == "PRB")
    #expect(joined.runs[0].map(\.via) == ["DCT", "V25", "V25", "V27"])

    let disjoint = try Self.assemble(
      "SNS V25 V27 END", [Self.v25, Self.airway("V27", [Self.segment("END", 40, 35.5, -119.9)])])
    #expect(disjoint.elements[1]["kind"] == "unresolved")
    #expect(disjoint.elements[2]["kind"] == "unresolved")

    let offAirway = try Self.assemble(
      "AAA V25 PRB", [Self.point("AAA", 37, -122), Self.point("PRB", 35.67, -120.63), Self.v25])
    #expect(offAirway.elements.map { $0["kind"] } == ["fix", "unresolved", "fix"])
    #expect(offAirway.runs.map { $0.map(\.identifier) } == [["AAA"], ["PRB"]])
  }

  @Test
  func `projects a place, bearing and distance only from a navaid's published variation`() throws {
    let navaid = Self.point(
      "SNS", 36.66, -121.6, kind: "navaid", data: ["magnetic_variation_deg": 13])
    let navigation = [navaid, Self.point("AAA", 37, -122), Self.point("FIXXY", 36, -121)]
    let projected = try Self.assemble("AAA SNS090020", navigation)
    let element = projected.elements[1]
    #expect(element["kind"] == "place_bearing_distance")
    #expect(element["course_true_deg"] == 103.0)
    #expect(element["magnetic_variation_deg"] == 13.0)
    let expected = Geodesy.destination(
      from: GeoPoint(latitude: 36.66, longitude: -121.6), courseDeg: 103, distanceNM: 20)
    #expect(projected.runs[0].last?.position == expected)
    #expect(projected.runs[0].last?.identifier == "SNS090020")

    let fromFix = try Self.assemble("AAA FIXXY090020", navigation)
    #expect(fromFix.elements[1]["kind"] == "unresolved")
    #expect(fromFix.elements[1]["reason"]?.stringValue?.contains("needs a navaid") == true)

    let unknownVariation = try Self.assemble(
      "AAA SNS090020", [Self.point("SNS", 36.66, -121.6, kind: "navaid"), navigation[1]])
    #expect(unknownVariation.elements[1]["kind"] == "unresolved")
    #expect(
      unknownVariation.elements[1]["reason"]?.stringValue?.contains("no magnetic variation")
        == true)
  }

  @Test
  func `orders a departure runway, common, en route and omits an unchosen runway transition`()
    throws
  {
    let navigation = [
      Self.point("KTST", 37, -122, kind: "airport", data: ["faa_lid": "TST"]),
      Self.point("ZZZ", 36, -120)
    ]
    let departures = [
      Self.procedure("left", "departure", transition: "RW28L", [("RW28L", 37.0, -122.01)]),
      Self.procedure("right", "departure", transition: "RW28R", [("RW28R", 37.01, -122.01)]),
      Self.procedure("common", "departure", transition: nil, [nil, ("JOIN", 36.9, -121.8)]),
      Self.procedure(
        "exit", "departure", transition: "AVE", [("JOIN", 36.9, -121.8), ("AVE", 36.5, -121)])
    ]
    var request = try RouteAssembly(
      words: try RouteGrammar.parse("TST TEST1 AVE ZZZ"), navigation: navigation)
    #expect(request.procedureRequests.map(\.type) == ["departure"])
    #expect(request.procedureRequests.first?.identifier == "TEST1")
    #expect(request.procedureRequests.first?.airportCodes.sorted() == ["KTST", "TST"])
    request.procedureUnavailability = "CIFP release 2026-11-05 expired."
    try request.assemble()
    #expect(request.elements[1]["kind"] == "unresolved")
    #expect(request.elements[1]["reason"]?.stringValue?.contains("expired") == true)

    let chosen = try Self.assemble(
      "KTST TEST1 AVE ZZZ", navigation, departures: departures, departureRunway: "28R")
    // The common route's first leg has no fix, so the path breaks after the runway transition.
    #expect(
      chosen.runs.map { $0.map(\.identifier) } == [["KTST", "RW28R"], ["JOIN", "AVE", "ZZZ"]])
    #expect(chosen.gaps.count == 1)
    #expect(chosen.gaps.first?.objectValue?["path_terminator"] == "VA")
    #expect(chosen.elements[1]["runway_transition"] == "RW28R")
    #expect(chosen.elements[1]["enroute_transition"] == "AVE")
    #expect(chosen.elements[2]["resolution"] == "anchored")
    #expect(chosen.elements[2]["kind"] == "procedure_fix")
    #expect(chosen.usedProcedures)
    #expect(chosen.warnings.isEmpty)

    let unchosen = try Self.assemble("KTST TEST1 AVE ZZZ", navigation, departures: departures)
    #expect(unchosen.runs.map { $0.map(\.identifier) } == [["KTST"], ["JOIN", "AVE", "ZZZ"]])
    #expect(unchosen.elements[1]["runway_transition"] == nil)
    #expect(unchosen.warnings.contains { $0.contains("departure_runway") })

    // A runway written after the origin chooses the transition, as the argument does.
    let written = try Self.assemble("KTST 28R.TEST1.AVE ZZZ", navigation, departures: departures)
    #expect(
      written.elements.map { $0["kind"] } == [
        "airport", "runway", "departure", "procedure_fix", "fix"
      ])
    #expect(written.elements[2]["runway_transition"] == "RW28R")
    #expect(written.runs.map { $0.map(\.identifier) } == chosen.runs.map { $0.map(\.identifier) })
    #expect(throws: ToolInputError.self) {
      try Self.assemble(
        "KTST 28R TEST1 AVE ZZZ", navigation, departures: departures, departureRunway: "28L")
    }
    // A runway beside anything but a departure or arrival is not a route element.
    let stray = try Self.assemble("KTST 28R AVE ZZZ", navigation + [Self.point("AVE", 36.5, -121)])
    #expect(stray.elements[1]["kind"] == "unresolved")

    let direct = try Self.assemble(
      "KTST TEST1 ZZZ", navigation, departures: departures, departureRunway: "28L")
    #expect(direct.runs.last?.map(\.identifier) == ["JOIN", "ZZZ"])
    #expect(direct.warnings.contains { $0.contains("not one of its transitions (AVE)") })
  }

  @Test
  func `orders an arrival en route, common, runway and anchors its transition fix`() throws {
    let navigation = [
      Self.point("KDST", 35, -118, kind: "airport"), Self.point("AAA", 37, -122),
      Self.point("ENTR", 36, -120, id: "one"), Self.point("ENTR", 10, 10, id: "two")
    ]
    let arrivals = [
      Self.procedure(
        "entry", "arrival", transition: "ENTR", [("ENTR", 36.0, -120.0), ("MERGE", 35.5, -119)]),
      Self.procedure(
        "common", "arrival", transition: nil, [("MERGE", 35.5, -119.0), ("LAST", 35.2, -118.4)]),
      Self.procedure("runway", "arrival", transition: "ALL", [("LAST", 35.2, -118.4), nil])
    ]
    let arrival = try Self.assemble("AAA ENTR STAR1 KDST", navigation, arrivals: arrivals)
    #expect(
      arrival.runs.map { $0.map(\.identifier) } == [["AAA", "ENTR", "MERGE", "LAST"], ["KDST"]])
    #expect(arrival.elements[1]["resolution"] == "anchored")
    #expect(arrival.elements[2]["kind"] == "arrival")
    #expect(arrival.elements[2]["runway_transition"] == "ALL")
    #expect(arrival.runs[0].map(\.viaKind) == ["direct", "direct", "arrival", "arrival"])
    #expect(arrival.gaps.count == 1)

    // With no common route and no transition named, the runway transition is flown alone.
    let runwayOnly = try Self.assemble(
      "AAA STAR1 KDST", navigation, arrivals: [arrivals[0], arrivals[2]])
    #expect(runwayOnly.runs.map { $0.map(\.identifier) } == [["AAA", "LAST"], ["KDST"]])
    #expect(runwayOnly.elements[1]["runway_transition"] == "ALL")
    #expect(runwayOnly.warnings.contains { $0.contains("not one of its transitions (ENTR)") })
    let nothing = try Self.assemble("AAA STAR1 KDST", navigation, arrivals: [arrivals[0]])
    #expect(nothing.elements[1]["kind"] == "unresolved")

    // The fix the common route starts at is the arrival's own, however many records share its
    // name.
    let merge = [
      Self.point("MERGE", 35.5, -119, id: "near"), Self.point("MERGE", 10, 10, id: "far")
    ]
    let joined = try Self.assemble(
      "AAA MERGE STAR1 KDST", navigation + merge, arrivals: [arrivals[1], arrivals[2]])
    #expect(joined.elements[1]["resolution"] == "anchored")
    #expect(joined.elements[1]["anchor"] == "STAR1")
    #expect(joined.runs.map { $0.map(\.identifier) } == [["AAA", "MERGE", "LAST"], ["KDST"]])
    #expect(joined.runs[0].map(\.viaKind) == ["direct", "direct", "arrival"])
    #expect(joined.warnings.isEmpty)
    let unjoined = try Self.assemble("AAA MERGE KDST", navigation + merge)
    #expect(unjoined.elements[1]["kind"] == "unresolved")

    // Without the arrival to anchor it, the duplicated transition fix stays ambiguous.
    let unanchored = try Self.assemble("AAA ENTR KDST", navigation)
    #expect(unanchored.elements[1]["kind"] == "unresolved")
  }
}

extension `Route assembly` {
  @Test
  func `leaves an airway or procedure with withheld geometry unresolved`() throws {
    var withheld = Self.v25
    withheld = RouteRecord(
      id: withheld.id, kind: withheld.kind, identifier: withheld.identifier, name: withheld.name,
      data: withheld.data.merging(["geometry_scope": "unavailable_due_to_parse_errors"]) { $1 },
      position: nil)
    let navigation = [
      Self.point("SNS", 36.66, -121.6, kind: "navaid"), Self.point("PRB", 35.67, -120.63),
      withheld
    ]
    let airway = try Self.assemble("SNS V25 PRB", navigation)
    #expect(airway.elements.map { $0["kind"] } == ["navaid", "unresolved", "fix"])
    #expect(airway.elements[1]["reason"]?.stringValue?.contains("parsing errors") == true)
    // Its surviving points are not joined: MID never appears and the path is split.
    #expect(airway.runs.map { $0.map(\.identifier) } == [["SNS"], ["PRB"]])
    #expect(airway.isBroken)

    let airport = Self.point("KDST", 35, -118, kind: "airport")
    var entry = Self.procedure(
      "entry", "arrival", transition: "ENTR", [("ENTR", 36.0, -120.0), ("LAST", 35.2, -118.4)])
    entry = RouteRecord(
      id: entry.id, kind: entry.kind, identifier: entry.identifier, name: entry.name,
      data: entry.data.merging(["geometry_scope": "unavailable_due_to_parse_errors"]) { $1 },
      position: nil)
    let arrival = try Self.assemble(
      "AAA ENTR STAR1 KDST",
      [airport, Self.point("AAA", 37, -122), Self.point("ENTR", 36, -120)], arrivals: [entry])
    #expect(arrival.elements.map { $0["kind"] } == ["fix", "fix", "unresolved", "airport"])
    #expect(arrival.runs.map { $0.map(\.identifier) } == [["AAA", "ENTR"], ["KDST"]])
    #expect(!arrival.usedProcedures)
    let departure = try Self.assemble(
      "KDST STAR1 ENTR AAA", [airport, Self.point("AAA", 37, -122), Self.point("ENTR", 36, -120)],
      departures: [entry])
    #expect(departure.elements[1]["kind"] == "unresolved")
    #expect(departure.runs.map { $0.map(\.identifier) } == [["KDST"], ["ENTR", "AAA"]])
  }

  @Test
  func `does not join airways at two different points that share an identifier`() throws {
    // V27 has its own DUPE, 60 NM from the DUPE that ends V25.
    let first = Self.airway(
      "V25",
      [
        Self.segment("SNS", 10, 36.66, -121.6, distance: 30, course: 128, opposite: 308),
        Self.segment("DUPE", 20, 36.2, -121.1)
      ])
    let second = Self.airway(
      "V27", [Self.segment("DUPE", 10, 35.2, -121.1), Self.segment("END", 20, 35.0, -120)])
    let implicit = try Self.assemble("SNS V25 V27 END", [first, second])
    #expect(implicit.elements[1]["kind"] == "airway")
    #expect(implicit.elements[2]["kind"] == "unresolved")
    #expect(implicit.elements[2]["reason"]?.stringValue?.contains("different point") == true)
    #expect(implicit.runs.map { $0.map(\.identifier) }.first == ["SNS", "DUPE"])
    #expect(!implicit.runs.contains { $0.map(\.identifier).contains("END") && $0.count > 1 })
    #expect(implicit.isBroken)

    let explicit = try Self.assemble("SNS V25 DUPE V27 END", [first, second])
    #expect(
      explicit.elements.map { $0["kind"] } == [
        "airway_point", "airway", "airway_point", "unresolved", "unresolved"
      ])
    #expect(explicit.isBroken)
  }

  @Test
  func `draws only tracks to fixes and splits the path at every other leg`() throws {
    let navigation = [
      Self.point("KDST", 35, -118, kind: "airport"), Self.point("AAA", 37, -122)
    ]
    func arrival(_ terminators: [Int: String]) throws -> RouteAssembly {
      try Self.assemble(
        "AAA STAR1 KDST", navigation,
        arrivals: [
          Self.procedure(
            "common", "arrival", transition: nil,
            [("ONE", 36.0, -120.0), ("TWO", 35.6, -119.2), ("LAST", 35.2, -118.4)],
            terminators: terminators)
        ])
    }
    let tracks = try arrival([0: "IF"])
    #expect(tracks.runs.map { $0.map(\.identifier) } == [["AAA", "ONE", "TWO", "LAST", "KDST"]])
    #expect(tracks.gaps.isEmpty && !tracks.isBroken)

    // FM: from LAST on a course until told otherwise, so nothing joins LAST to the airport.
    let manual = try Self.assemble(
      "AAA STAR1 KDST", navigation,
      arrivals: [
        Self.procedure(
          "common", "arrival", transition: nil,
          [("ONE", 36.0, -120.0), ("LAST", 35.2, -118.4), ("LAST", 35.2, -118.4)],
          terminators: [2: "FM"])
      ])
    #expect(manual.runs.map { $0.map(\.identifier) } == [["AAA", "ONE", "LAST"], ["KDST"]])
    #expect(manual.gaps.count == 1)
    #expect(manual.gaps.first?.objectValue?["path_terminator"] == "FM")
    #expect(manual.isBroken)

    // An arc or a course to a fix ends there, but the way to it is not a straight track.
    for terminator in ["RF", "AF", "CF", "DF"] {
      let curved = try arrival([1: terminator])
      #expect(curved.runs.map { $0.map(\.identifier) } == [["AAA", "ONE"], ["TWO", "LAST", "KDST"]])
      #expect(curved.gaps.first?.objectValue?["path_terminator"] == .string(terminator))
    }
    // A leg of a kind the tool does not know is cut off on both sides.
    let unknown = try arrival([1: "ZZ"])
    #expect(
      unknown.runs.map { $0.map(\.identifier) } == [["AAA", "ONE"], ["TWO"], ["LAST", "KDST"]])
    // A hold at the fix the path has already reached changes nothing.
    let hold = try Self.assemble(
      "AAA STAR1 KDST", navigation,
      arrivals: [
        Self.procedure(
          "common", "arrival", transition: nil,
          [("ONE", 36.0, -120.0), ("ONE", 36.0, -120.0), ("LAST", 35.2, -118.4)],
          terminators: [1: "HF"])
      ])
    #expect(hold.runs.map { $0.map(\.identifier) } == [["AAA", "ONE", "LAST", "KDST"]])
    #expect(hold.gaps.isEmpty)
  }

  static let v25Segments: [[String: Value]] = [
    segment("SNS", 10, 36.66, -121.6, distance: 30, course: 128, opposite: 308),
    segment("MID", 20, 36.2, -121.1, distance: 25, course: 130, opposite: 310),
    segment("PRB", 30, 35.67, -120.63)
  ]

  static let v25 = airway("V25", v25Segments)

  static func assemble(
    _ route: String, _ navigation: [RouteRecord], selections: [Int: String] = [:],
    departures: [RouteRecord] = [], arrivals: [RouteRecord] = [], departureRunway: String? = nil
  ) throws -> RouteAssembly {
    var assembly = try RouteAssembly(
      words: try RouteGrammar.parse(route), navigation: navigation, selections: selections,
      departureRunway: departureRunway)
    assembly.departures = departures
    assembly.arrivals = arrivals
    try assembly.assemble()
    return assembly
  }

  static func point(
    _ identifier: String, _ latitude: Double, _ longitude: Double, kind: String = "fix",
    id: String? = nil, data: [String: Value] = [:]
  ) -> RouteRecord {
    RouteRecord(
      id: id ?? identifier, kind: kind, identifier: identifier, name: identifier, data: data,
      position: GeoPoint(latitude: latitude, longitude: longitude))
  }

  static func segment(
    _ identifier: String, _ sequence: Int, _ latitude: Double, _ longitude: Double,
    distance: Int? = nil, course: Int? = nil, opposite: Int? = nil
  ) -> [String: Value] {
    var fields: [String: Value] = [
      "identifier": .string(identifier), "sequence": .int(sequence),
      "position": Normalization.point(latitude: latitude, longitude: longitude)
    ]
    fields["distance_to_next_nm"] = distance.map(Value.int)
    fields["course_magnetic_deg"] = course.map(Value.int)
    fields["opposite_course_magnetic_deg"] = opposite.map(Value.int)
    return fields
  }

  static func airway(_ identifier: String, _ segments: [[String: Value]]) -> RouteRecord {
    RouteRecord(
      id: identifier, kind: "airway", identifier: identifier, name: identifier,
      data: ["segments": .array(segments.map(Value.object))], position: nil)
  }

  /// A procedure part whose legs are fixes with positions, or `nil` for a heading leg. Each
  /// leg is a track to its fix unless `terminators` names another path terminator for it.
  static func procedure(
    _ id: String, _ type: String, transition: String?,
    _ fixes: [(String, Double, Double)?], terminators: [Int: String] = [:]
  ) -> RouteRecord {
    let legs: [Value] = fixes.enumerated().map { sequence, fix in
      guard let fix else {
        return .object(["sequence": .int(sequence), "path_terminator": "VA"])
      }
      return .object([
        "sequence": .int(sequence), "fix": .string(fix.0),
        "path_terminator": .string(terminators[sequence] ?? "TF"),
        "position": Normalization.point(latitude: fix.1, longitude: fix.2)
      ])
    }
    var data: [String: Value] = [
      "airport": "KTST", "procedure_type": .string(type), "legs": .array(legs)
    ]
    data["transition"] = transition.map(Value.string)
    return RouteRecord(
      id: id, kind: "procedure", identifier: "TEST1", name: "TEST1", data: data, position: nil)
  }
}

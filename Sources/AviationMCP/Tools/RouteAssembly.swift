import Foundation
import MCP

/// A navigation or procedure record a route element may resolve to.
struct RouteRecord: Sendable {
  let id: String
  let kind: String
  let identifier: String
  let name: String
  let data: [String: Value]
  let position: GeoPoint?

  /// The FAA location identifier and ICAO code an airport record answers to.
  var airportCodes: [String] {
    [identifier, data["faa_lid"]?.stringValue, data["icao_identifier"]?.stringValue]
      .compactMap { $0?.uppercased() }
  }

  /// A VOR test facility (VOT) radiates a test signal; it is not a point to navigate to.
  var isTestFacility: Bool { data["facility_type"] == "VOT" }

  var transition: String? { data["transition"]?.stringValue }

  /// Whether a procedure record is a runway transition, as `ProcedureExpansion` tells them.
  var isRunwayTransition: Bool {
    guard let name = transition?.uppercased() else { return false }
    return name.hasPrefix("RW") || name == "ALL"
  }

  var segments: [[String: Value]] {
    data["segments"]?.arrayValue?.compactMap(\.objectValue) ?? []
  }

  var legs: [[String: Value]] { data["legs"]?.arrayValue?.compactMap(\.objectValue) ?? [] }

  /// The positions in `segments` of an airway point with this identifier.
  func segmentIndices(of identifier: String) -> [Int] {
    segments.indices.filter { segments[$0]["identifier"]?.stringValue?.uppercased() == identifier }
  }

  /// The record as a candidate to choose with `selections`.
  var candidate: [String: Value] {
    var fields: [String: Value] = [
      "id": .string(id), "record_kind": .string(kind), "identifier": .string(identifier),
      "name": .string(name)
    ]
    for key in ["facility_type", "airway_type", "city", "state", "icao_region"] {
      fields[key] = data[key]
    }
    fields["position"] = position.map {
      Normalization.point(latitude: $0.latitude, longitude: $0.longitude)
    }
    return fields
  }
}

/// A point on the resolved path, with the leg that arrives at it.
struct RoutePoint: Sendable {
  let identifier: String
  let kind: String
  let position: GeoPoint
  /// The index of the route element that produced the point.
  let element: Int
  var via = "DCT"
  var viaKind = "direct"
  /// What the source publishes for the arriving leg, such as an airway segment's altitudes.
  var published: [String: Value] = [:]
}

/// Resolves a route's elements against the records that could match them and assembles the
/// path, without ever choosing among several matches.
struct RouteAssembly: Sendable {
  struct ProcedureRequest: Sendable {
    let type: String
    let airportCodes: [String]
    let identifier: String
  }

  private static let pointKinds: Set = ["fix", "navaid"]
  /// Points nearer than this with one identifier are the same point, in nautical miles.
  private static let coincidenceNM = 0.1

  let words: [RouteWord]
  let navigation: [RouteRecord]
  let selections: [Int: String]
  let departureRunway: String?
  let arrivalRunway: String?
  var departures: [RouteRecord] = []
  var arrivals: [RouteRecord] = []
  /// Why departures and arrivals could not be looked up, when they could not.
  var procedureUnavailability: String?

  private(set) var elements: [[String: Value]]
  /// Contiguous runs of points; a gap in the route starts a new run.
  private(set) var runs: [[RoutePoint]] = []
  private(set) var gaps: [Value] = []
  private(set) var warnings: [String] = []
  private(set) var isBroken = false
  private(set) var usedProcedures = false

  /// The indices of the words that take part in the route, omitting speed and level groups.
  private let significant: [Int]
  private var breakPending = false
  private var usedSelections: Set<Int> = []
  /// Words an airway or procedure has already resolved.
  private var handled: Set<Int> = []
  /// The point at which the previous airway joins the next one.
  private var junction: String?
  private var flownDepartureRunway: String?
  private var flownArrivalRunway: String?

  init(
    words: [RouteWord], navigation: [RouteRecord], selections: [Int: String] = [:],
    departureRunway: String? = nil, arrivalRunway: String? = nil
  ) throws {
    self.words = words
    self.navigation = navigation
    self.selections = selections
    self.departureRunway = departureRunway
    self.arrivalRunway = arrivalRunway
    elements = Array(repeating: [:], count: words.count)
    significant = words.indices.filter { words[$0].token != .speedLevel }
    guard significant.count >= 2 else {
      throw ToolInputError(reason: "route_string needs at least two route elements.")
    }
    for index in selections.keys where !words.indices.contains(index) {
      throw ToolInputError(
        reason: "selections index \(index) is outside the route's \(words.count) elements.")
    }
  }

  /// The departure and arrival lookups the route calls for, given its endpoint airports.
  var procedureRequests: [ProcedureRequest] {
    guard significant.count >= 3 else { return [] }
    var requests: [ProcedureRequest] = []
    if let origin, let identifier = name(at: departurePosition) {
      requests.append(
        .init(type: "departure", airportCodes: origin.airportCodes, identifier: identifier))
    }
    if let destination, let identifier = name(at: arrivalPosition) {
      requests.append(
        .init(type: "arrival", airportCodes: destination.airportCodes, identifier: identifier))
    }
    return requests
  }

  private var origin: RouteRecord? { endpointAirport(0) }
  private var destination: RouteRecord? { endpointAirport(significant.count - 1) }

  /// Where a departure would stand: after the origin, or after a runway that follows it.
  private var departurePosition: Int {
    significant.count >= 4 && origin != nil && isRunwayWord(1) ? 2 : 1
  }

  /// Where an arrival would stand: before the destination, or before a runway that precedes it.
  private var arrivalPosition: Int {
    let last = significant.count - 2
    return last >= 2 && destination != nil && isRunwayWord(last) ? last - 1 : last
  }

  /// Whether a word is a runway designator, such as 20C, that names no fix, navaid or airway.
  private func isRunwayWord(_ position: Int) -> Bool {
    guard let name = name(at: position), let match = name.wholeMatch(of: /(\d{1,2})[LCR]?/),
      let number = Int(match.1), (1...36).contains(number)
    else { return false }
    return pointCandidates(name, endpoint: false).isEmpty && airways(name).isEmpty
  }

  /// The runway to fly: the one written in the route, which must agree with the argument.
  private func runway(wordAt position: Int?, argument: String?, name: String) throws -> String? {
    guard let position, let written = self.name(at: position) else { return argument }
    if let argument, RunwayName.canonical(argument) != RunwayName.canonical(written) {
      throw ToolInputError(
        reason: "\(name) \(argument) disagrees with runway \(written) in route_string.")
    }
    return written
  }

  mutating func assemble() throws {
    flownDepartureRunway = try runway(
      wordAt: departurePosition == 2 ? 1 : nil, argument: departureRunway,
      name: "departure_runway")
    flownArrivalRunway = try runway(
      wordAt: arrivalPosition == significant.count - 3 ? significant.count - 2 : nil,
      argument: arrivalRunway, name: "arrival_runway")
    for index in words.indices where words[index].token == .speedLevel {
      elements[index] = element(index, kind: "speed_level")
    }
    for position in significant.indices {
      let index = significant[position]
      guard !handled.contains(index) else { continue }
      switch words[index].token {
      case .speedLevel: continue
      case .direct: elements[index] = element(index, kind: "direct")
      case .coordinate(let point):
        elements[index] = element(
          index, kind: "coordinate", ["resolution": "literal", "position": Self.geoJSON(point)])
        emit(
          RoutePoint(identifier: label(index), kind: "coordinate", position: point, element: index))
      case .placeBearingDistance(let place, let bearing, let distance):
        try placeBearingDistance(index, place: place, bearing: bearing, distance: distance)
      case .name(let name):
        if position == 1, departurePosition == 2 {
          runwayElement(index, procedure: 2, kind: "departure")
        } else if position == arrivalPosition + 1, position == significant.count - 2 {
          runwayElement(index, procedure: arrivalPosition, kind: "arrival")
        } else if isDeparture(position) {
          departure(position, name)
        } else if isArrival(position) {
          try arrival(position, name)
        } else if isAirway(position) {
          try airway(position, name)
        } else if !isDeferred(position, name) {
          try point(position)
        }
      }
    }
    for index in selections.keys.sorted() where !usedSelections.contains(index) {
      throw ToolInputError(
        reason: "selections names element \(index) (\(words[index].text)), which has no "
          + "candidates to choose from.")
    }
    annotateCandidates()
  }

  // MARK: Classification

  private func name(at position: Int) -> String? {
    guard significant.indices.contains(position),
      case .name(let name) = words[significant[position]].token
    else { return nil }
    return name
  }

  private func airways(_ name: String) -> [RouteRecord] {
    navigation.filter { $0.kind == "airway" && $0.identifier.uppercased() == name }
  }

  /// The fixes and navaids an identifier names, and at either end of the route the airports.
  private func pointCandidates(_ name: String, endpoint: Bool) -> [RouteRecord] {
    navigation.filter { record in
      if Self.pointKinds.contains(record.kind) {
        return record.identifier.uppercased() == name && !record.isTestFacility
      }
      return endpoint && record.kind == "airport" && record.airportCodes.contains(name)
    }
  }

  /// The airport at one end of the route, when that end names exactly one record and it is an
  /// airport.
  private func endpointAirport(_ position: Int) -> RouteRecord? {
    guard let name = name(at: position) else { return nil }
    var candidates = pointCandidates(name, endpoint: true)
    if let selected = selections[significant[position]] {
      candidates = candidates.filter { $0.id == selected }
    }
    guard candidates.count == 1, candidates[0].kind == "airport" else { return nil }
    return candidates[0]
  }

  private func isDeparture(_ position: Int) -> Bool {
    position == departurePosition && significant.count >= 3 && name(at: position) != nil
      && origin != nil && !departures.isEmpty
  }

  private func isArrival(_ position: Int) -> Bool {
    position >= 1 && position == arrivalPosition && name(at: position) != nil
      && destination != nil && !arrivals.isEmpty && !isDeparture(position)
  }

  /// An identifier between two elements is an airway when it names only an airway, or when it
  /// also names a point and the element before it lies on that airway.
  private func isAirway(_ position: Int) -> Bool {
    guard position > 0, position < significant.count - 1, let name = name(at: position),
      !isDeparture(position), !isArrival(position)
    else { return false }
    let candidates = airways(name)
    guard !candidates.isEmpty else { return false }
    if pointCandidates(name, endpoint: false).isEmpty { return true }
    guard let previous = self.name(at: position - 1) else { return false }
    return candidates.contains { !$0.segmentIndices(of: previous).isEmpty }
      || isAirway(position - 1)
  }

  /// Whether the next element will resolve this one: an airway it lies on, or an arrival whose
  /// transition it names.
  private func isDeferred(_ position: Int, _ name: String) -> Bool {
    let next = position + 1
    if isArrival(next) {
      return arrivals.contains { !$0.isRunwayTransition && $0.transition?.uppercased() == name }
    }
    guard isAirway(next), let airway = self.name(at: next) else { return false }
    return airways(airway).contains { !$0.segmentIndices(of: name).isEmpty }
  }

  /// Records a runway written beside a departure or arrival, which only that procedure uses.
  private mutating func runwayElement(_ index: Int, procedure position: Int, kind: String) {
    guard
      elements[significant[position]]["kind"]?.stringValue == kind
        || (kind == "departure" && isDeparture(position))
    else {
      unresolve(
        index,
        reason: "Runway \(words[index].text) must stand beside a \(kind) of the airport; "
          + "\(name(at: position) ?? "the element beside it") is not one.")
      return
    }
    elements[index] = element(index, kind: "runway", ["resolution": "literal"])
  }

  // MARK: Points

  private mutating func point(_ position: Int) throws {
    let index = significant[position]
    guard let name = name(at: position) else { return }
    let endpoint = position == 0 || position == significant.count - 1
    let (candidates, selected) = try choose(
      pointCandidates(name, endpoint: endpoint), at: index)
    guard let record = candidates.first else {
      unresolve(index, reason: missingReason(name, position: position))
      return
    }
    guard candidates.count == 1 else {
      unresolve(
        index,
        reason: "\(name) matches \(candidates.count) records; choose one with selections.",
        candidates: candidates)
      return
    }
    guard let location = record.position else {
      unresolve(index, reason: "\(name) has no published position.")
      return
    }
    elements[index] = element(
      index, kind: record.kind,
      [
        "identifier": .string(record.identifier), "name": .string(record.name),
        "record_id": .string(record.id), "resolution": selected ? "selected" : "unique",
        "position": Self.geoJSON(location)
      ])
    emit(RoutePoint(identifier: name, kind: record.kind, position: location, element: index))
  }

  private func missingReason(_ name: String, position: Int) -> String {
    if navigation.contains(where: { $0.kind == "airport" && $0.airportCodes.contains(name) }) {
      return "\(name) is an airport; airports are accepted only as the first or last element."
    }
    if !airways(name).isEmpty {
      return "\(name) is an airway; an airway must lie between two points."
    }
    let besideAirport =
      (position == departurePosition && origin != nil)
      || (position == arrivalPosition && destination != nil)
    if besideAirport, let procedureUnavailability {
      return "\(name) is not a fix, navaid or airway in the effective NASR cycle, and "
        + "departures and arrivals cannot be matched: \(procedureUnavailability)"
    }
    return "\(name) is not in the effective FAA data, which covers the United States only."
  }

  private mutating func placeBearingDistance(
    _ index: Int, place: String, bearing: Double, distance: Double
  ) throws {
    let (navaids, selected) = try choose(
      navigation.filter {
        $0.kind == "navaid" && $0.identifier.uppercased() == place && !$0.isTestFacility
      }, at: index)
    guard let navaid = navaids.first else {
      let isFix = navigation.contains { $0.kind == "fix" && $0.identifier.uppercased() == place }
      unresolve(
        index,
        reason: isFix
          ? "\(place) is a fix. A place, bearing and distance needs a navaid, because NASR "
            + "publishes the magnetic variation that converts the bearing to true only for navaids."
          : "\(place) is not a navaid in the effective FAA data, which covers the United "
            + "States only.")
      return
    }
    guard navaids.count == 1 else {
      unresolve(
        index,
        reason: "\(place) matches \(navaids.count) navaids; choose one with selections.",
        candidates: navaids)
      return
    }
    guard let origin = navaid.position,
      let variation = navaid.data["magnetic_variation_deg"]?.number
    else {
      unresolve(
        index,
        reason: "\(place) publishes no magnetic variation or position, so its magnetic bearing "
          + "cannot be converted to a true course.")
      return
    }
    let course = Geodesy.normalizedCourse(bearing + variation)
    let location = Geodesy.destination(from: origin, courseDeg: course, distanceNM: distance)
    elements[index] = element(
      index, kind: "place_bearing_distance",
      [
        "identifier": .string(navaid.identifier), "name": .string(navaid.name),
        "record_id": .string(navaid.id), "resolution": selected ? "selected" : "unique",
        "bearing_magnetic_deg": .double(bearing), "magnetic_variation_deg": .double(variation),
        "course_true_deg": .double(course), "distance_nm": .double(distance),
        "position": Self.geoJSON(location)
      ])
    emit(
      RoutePoint(
        identifier: label(index), kind: "place_bearing_distance", position: location,
        element: index))
  }

  // MARK: Airways

  private mutating func airway(_ position: Int, _ name: String) throws {
    let index = significant[position]
    let followsAirway = isAirway(position - 1)
    let entry = followsAirway ? junction : self.name(at: position - 1)
    junction = nil
    let (records, selected) = try choose(airways(name), at: index)
    let joinsAirway = isAirway(position + 1)
    var exit = self.name(at: position + 1)
    if joinsAirway, let next = exit {
      let shared = Self.sharedPoints(records, airways(next))
      guard shared.count == 1 else {
        try failAirway(
          position,
          reason: "\(name) and \(next) share \(shared.count) points; name the fix where they join."
        )
        return
      }
      exit = shared[0]
    }
    guard let entry, let exit else {
      try failAirway(
        position,
        reason: followsAirway
          ? "The airway before \(name) is unresolved, so their junction is unknown."
          : "\(name) must lie between two fixes, navaids or airways.")
      return
    }
    let matches = records.filter {
      !$0.segmentIndices(of: entry).isEmpty && !$0.segmentIndices(of: exit).isEmpty
    }
    guard let record = matches.first else {
      try failAirway(position, reason: "\(name) does not contain both \(entry) and \(exit).")
      return
    }
    guard matches.count == 1 else {
      try failAirway(
        position,
        reason: "\(matches.count) airways named \(name) contain \(entry) and \(exit); "
          + "choose one with selections.",
        candidates: matches)
      return
    }
    let starts = record.segmentIndices(of: entry)
    let ends = record.segmentIndices(of: exit)
    guard starts.count == 1, ends.count == 1, starts[0] != ends[0] else {
      try failAirway(
        position,
        reason: "\(entry) or \(exit) appears more than once on \(name); use get_airway to "
          + "inspect its sequence.")
      return
    }
    let reversed = starts[0] > ends[0]
    elements[index] = element(
      index, kind: "airway",
      [
        "identifier": .string(record.identifier), "record_id": .string(record.id),
        "resolution": selected ? "selected" : "unique", "entry": .string(entry),
        "exit": .string(exit), "reversed": .bool(reversed)
      ])
    let segments = record.segments
    if !followsAirway {
      anchor(significant[position - 1], to: name, segment: segments[starts[0]])
    }
    traverse(segments, from: starts[0], to: ends[0], airway: name, element: index)
    if joinsAirway {
      junction = exit
    } else {
      let following = significant[position + 1]
      anchor(following, to: name, segment: segments[ends[0]])
      handled.insert(following)
    }
  }

  /// Emits an airway's points in travel order, breaking the path at a published gap or a point
  /// without a position.
  private mutating func traverse(
    _ segments: [[String: Value]], from start: Int, to end: Int, airway: String, element: Int
  ) {
    let forward = start < end
    let order = forward ? Array(start...end) : Array((end...start).reversed())
    var unusable = false
    for (step, current) in order.enumerated() {
      let location = segments[current]["position"].flatMap(GeoPoint.init(geoJSON:))
      var published: [String: Value] = [:]
      if step > 0 {
        let previous = order[step - 1]
        // A segment's fields describe the leg to the next point in published order.
        let leg = segments[min(previous, current)]
        let origin = segments[previous]["position"].flatMap(GeoPoint.init(geoJSON:))
        if leg["airway_gap"] == true || origin == nil || location == nil {
          gap([
            "element": .int(element), "via": .string(airway), "sequence": leg["sequence"],
            "reason": leg["airway_gap"] == true
              ? "The airway publishes a gap here."
              : "An airway point here has no resolved position."
          ])
        }
        unusable = unusable || leg["mea_unusable"] == true
        published = [
          "airway_direction": forward ? "published" : "reversed"
        ]
        published["published_distance_nm"] = leg["distance_to_next_nm"]
        published["published_course_magnetic_deg"] =
          leg[forward ? "course_magnetic_deg" : "opposite_course_magnetic_deg"]
        published["altitudes"] = leg["altitudes"]
      }
      guard let location else { continue }
      var point = RoutePoint(
        identifier: segments[current]["identifier"]?.stringValue ?? airway, kind: "airway_point",
        position: location, element: element)
      if step > 0 {
        point.via = airway
        point.viaKind = "airway"
        point.published = published
      }
      emit(point)
    }
    if unusable {
      warnings.append("\(airway) includes a segment whose MEA is unusable on this portion.")
    }
  }

  /// Records a word as resolved by the airway it lies on, unless it already resolved.
  private mutating func anchor(_ index: Int, to airway: String, segment: [String: Value]) {
    guard elements[index].isEmpty else { return }
    elements[index] = element(
      index, kind: "airway_point",
      [
        "identifier": segment["identifier"], "point_type": segment["point_type"],
        "resolution": "anchored", "anchor": .string(airway), "position": segment["position"]
      ])
  }

  private mutating func failAirway(
    _ position: Int, reason: String, candidates: [RouteRecord] = []
  ) throws {
    if elements[significant[position - 1]].isEmpty, !isAirway(position - 1) {
      try point(position - 1)
    }
    unresolve(significant[position], reason: reason, candidates: candidates)
  }

  private static func sharedPoints(_ first: [RouteRecord], _ second: [RouteRecord]) -> [String] {
    func identifiers(_ records: [RouteRecord]) -> Set<String> {
      Set(
        records.flatMap { $0.segments.compactMap { $0["identifier"]?.stringValue?.uppercased() } })
    }
    return identifiers(first).intersection(identifiers(second)).sorted()
  }

  // MARK: Departures and arrivals

  private mutating func departure(_ position: Int, _ name: String) {
    let index = significant[position]
    let common = departures.filter { $0.transition == nil }
    let enroute = departures.filter { $0.transition != nil && !$0.isRunwayTransition }
    let next = self.name(at: position + 1)
    let exits = enroute.filter { $0.transition?.uppercased() == next }
    guard common.count <= 1, exits.count <= 1 else {
      unresolve(index, reason: Self.variantsReason(name))
      return
    }
    let runway = runwayTransition(
      departures.filter(\.isRunwayTransition), requested: flownDepartureRunway,
      argument: "departure_runway", procedure: name)
    // A departure with no common route is flown on its runway transition alone.
    let parts = [runway.record, common.first, exits.first].compactMap(\.self)
    guard !parts.isEmpty else {
      unresolve(index, reason: Self.transitionReason(name, enroute, placement: "follow"))
      return
    }
    usedProcedures = true
    if runway.skipped { interrupt() }
    emit(parts, procedure: name, kind: "departure", element: index)
    elements[index] = procedureElement(index, kind: "departure", parts: parts, enroute: exits.first)
    guard let next else { return }
    let following = significant[position + 1]
    let last = parts.last?.legs.last
    if exits.first != nil || last?["fix"]?.stringValue?.uppercased() == next {
      anchor(following, toProcedure: name, leg: last)
      handled.insert(following)
    } else if !enroute.isEmpty {
      warnings.append(
        "\(name) is left by a direct leg: \(next) is not one "
          + "of its transitions (\(Self.names(enroute))).")
    }
  }

  private mutating func arrival(_ position: Int, _ name: String) throws {
    let index = significant[position]
    let previousIndex = significant[position - 1]
    let common = arrivals.filter { $0.transition == nil }
    let enroute = arrivals.filter { $0.transition != nil && !$0.isRunwayTransition }
    let previous = self.name(at: position - 1)
    let entries = enroute.filter { $0.transition?.uppercased() == previous }
    let hasVariants = common.count > 1 || entries.count > 1
    let runway =
      hasVariants
      ? (record: RouteRecord?.none, skipped: false)
      : runwayTransition(
        arrivals.filter(\.isRunwayTransition), requested: flownArrivalRunway,
        argument: "arrival_runway", procedure: name)
    // An arrival with no common route is flown on its runway transition alone.
    let parts = [entries.first, common.first, runway.record].compactMap(\.self)
    if hasVariants || parts.isEmpty {
      if elements[previousIndex].isEmpty { try point(position - 1) }
      unresolve(
        index,
        reason: hasVariants
          ? Self.variantsReason(name)
          : Self.transitionReason(name, enroute, placement: "precede"))
      return
    }
    usedProcedures = true
    emit(parts, procedure: name, kind: "arrival", element: index, joinedDirect: true)
    if runway.skipped { interrupt() }
    elements[index] = procedureElement(index, kind: "arrival", parts: parts, enroute: entries.first)
    let first = parts.first?.legs.first
    if elements[previousIndex].isEmpty {
      anchor(previousIndex, toProcedure: name, leg: first)
    } else if entries.isEmpty, !enroute.isEmpty, let previous,
      first?["fix"]?.stringValue?.uppercased() != previous
    {
      warnings.append(
        "\(name) is joined by a direct leg: \(previous) is "
          + "not one of its transitions (\(Self.names(enroute))).")
    }
  }

  /// The runway transition to fly, or none when the runway is needed to choose one and was not
  /// supplied or matches no single transition.
  private mutating func runwayTransition(
    _ transitions: [RouteRecord], requested: String?, argument: String, procedure: String
  ) -> (record: RouteRecord?, skipped: Bool) {
    guard !transitions.isEmpty else { return (nil, false) }
    guard let requested else {
      if transitions.count == 1 { return (transitions[0], false) }
      warnings.append(
        "\(procedure) has runway transitions (\(Self.names(transitions))); supply \(argument) "
          + "to include one. The path omits the runway transition.")
      return (nil, true)
    }
    let matching = transitions.filter {
      RunwayName.matches($0.transition ?? "", requested: requested)
    }
    if matching.count == 1 { return (matching[0], false) }
    warnings.append(
      "\(procedure) has \(matching.count) runway transitions for runway \(requested) "
        + "(published: \(Self.names(transitions))). The path omits the runway transition.")
    return (nil, true)
  }

  /// Emits the fixes of a procedure's parts in order, breaking the path at each leg that has no
  /// published fix position. An arrival is joined by a direct leg, so the leg into its first
  /// fix is not the procedure's.
  private mutating func emit(
    _ parts: [RouteRecord], procedure: String, kind: String, element: Int,
    joinedDirect: Bool = false
  ) {
    var isFirst = joinedDirect
    for part in parts {
      for leg in part.legs {
        guard let location = leg["position"].flatMap(GeoPoint.init(geoJSON:)) else {
          gap([
            "element": .int(element), "via": .string(procedure),
            "transition": part.transition.map(Value.string), "sequence": leg["sequence"],
            "path_terminator": leg["path_terminator"],
            "reason": "The leg has no published fix position."
          ])
          continue
        }
        var point = RoutePoint(
          identifier: leg["fix"]?.stringValue ?? procedure, kind: "procedure_fix",
          position: location, element: element)
        if !isFirst {
          point.via = procedure
          point.viaKind = kind
        }
        isFirst = false
        emit(point)
      }
    }
  }

  private func procedureElement(
    _ index: Int, kind: String, parts: [RouteRecord], enroute: RouteRecord?
  ) -> [String: Value] {
    element(
      index, kind: kind,
      [
        "identifier": parts.first.map { .string($0.identifier) },
        "airport": parts.first?.data["airport"], "resolution": "unique",
        "record_ids": .array(parts.map { .string($0.id) }),
        "runway_transition": parts.first(where: \.isRunwayTransition)?.transition.map(Value.string),
        "enroute_transition": enroute?.transition.map(Value.string)
      ])
  }

  /// Records a word as resolved by the procedure whose transition or end fix it names.
  private mutating func anchor(_ index: Int, toProcedure procedure: String, leg: [String: Value]?) {
    guard elements[index].isEmpty else { return }
    elements[index] = element(
      index, kind: "procedure_fix",
      [
        "identifier": leg?["fix"], "resolution": "anchored", "anchor": .string(procedure),
        "position": leg?["position"]
      ])
  }

  private static func names(_ transitions: [RouteRecord]) -> String {
    transitions.compactMap(\.transition).sorted().joined(separator: ", ")
  }

  private static func variantsReason(_ name: String) -> String {
    "Several published variants of \(name) match; use get_procedure to inspect them."
  }

  private static func transitionReason(
    _ name: String, _ enroute: [RouteRecord], placement: String
  ) -> String {
    enroute.isEmpty
      ? "\(name) publishes no route that can be joined here."
      : "\(name) publishes no common route; \(placement) it with one of its transitions "
        + "(\(names(enroute)))."
  }

  // MARK: Assembly

  /// Applies the caller's selection for an element, which must be one of its candidates.
  private mutating func choose(
    _ candidates: [RouteRecord], at index: Int
  ) throws -> (records: [RouteRecord], selected: Bool) {
    guard let id = selections[index] else { return (candidates, false) }
    guard let record = candidates.first(where: { $0.id == id }) else {
      throw ToolInputError(
        reason: "selections record_id \(id) is not a candidate for element \(index) "
          + "(\(words[index].text)).")
    }
    usedSelections.insert(index)
    return ([record], true)
  }

  private mutating func emit(_ point: RoutePoint) {
    if breakPending || runs.isEmpty {
      runs.append([])
      breakPending = false
    } else if let last = runs[runs.count - 1].last, last.identifier == point.identifier,
      Geodesy.sphericalDistanceNM(from: last.position, to: point.position) < Self.coincidenceNM
    {
      return
    }
    runs[runs.count - 1].append(point)
  }

  /// Ends the current run, so nothing is drawn across what could not be resolved.
  private mutating func interrupt() {
    breakPending = true
    isBroken = true
  }

  private mutating func gap(_ fields: [String: Value?]) {
    gaps.append(Normalization.object(fields))
    interrupt()
  }

  private mutating func unresolve(
    _ index: Int, reason: String, candidates: [RouteRecord] = []
  ) {
    elements[index] = element(
      index, kind: "unresolved",
      [
        "resolution": "unresolved", "reason": .string(reason),
        "candidates": candidates.isEmpty
          ? nil : .array(candidates.map { .object($0.candidate) })
      ])
    warnings.append("Element \(index) (\(words[index].text)) is unresolved: \(reason)")
    interrupt()
  }

  /// The element's text without any speed and level suffix.
  private func label(_ index: Int) -> String {
    String(words[index].text.prefix { $0 != "/" })
  }

  private func element(
    _ index: Int, kind: String, _ fields: [String: Value?] = [:]
  ) -> [String: Value] {
    var value: [String: Value] = [
      "index": .int(index), "text": .string(words[index].text), "kind": .string(kind)
    ]
    value["speed_level"] = words[index].speedLevel.map(Value.string)
    return value.merging(fields.compactMapValues(\.self)) { $1 }
  }

  /// Adds to each candidate its distance from the resolved elements either side, so a caller
  /// can choose without another lookup. Distances are spherical.
  private mutating func annotateCandidates() {
    let positions = elements.map { $0["position"].flatMap(GeoPoint.init(geoJSON:)) }
    for index in elements.indices {
      guard let candidates = elements[index]["candidates"]?.arrayValue else { continue }
      let previous = positions[..<index].last { $0 != nil } ?? nil
      let next = positions[(index + 1)...].first { $0 != nil } ?? nil
      elements[index]["candidates"] = .array(
        candidates.map { candidate in
          guard var fields = candidate.objectValue,
            let location = fields["position"].flatMap(GeoPoint.init(geoJSON:))
          else { return candidate }
          fields["distance_from_previous_nm"] = previous.map {
            Self.rounded(Geodesy.sphericalDistanceNM(from: $0, to: location))
          }
          fields["distance_to_next_nm"] = next.map {
            Self.rounded(Geodesy.sphericalDistanceNM(from: location, to: $0))
          }
          return .object(fields)
        })
    }
  }

  private static func rounded(_ distance: Double) -> Value {
    .double((distance * 10).rounded() / 10)
  }

  private static func geoJSON(_ point: GeoPoint) -> Value {
    Normalization.point(latitude: point.latitude, longitude: point.longitude)
  }
}

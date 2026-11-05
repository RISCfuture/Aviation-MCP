import Foundation
import MCP
import MeasurementKit
import SF50Performance

/// An airport as the NASR airport record describes it, reduced to what performance needs.
struct PerformanceAirport: Sendable {
  let id: String
  let identifier: String
  let name: String
  let elevationFt: Double?
  let magneticVariationDeg: Double
  let position: GeoPoint?
  let runways: [[String: MCP.Value]]

  init(_ record: [String: MCP.Value]) {
    id = record["id"]?.stringValue ?? ""
    identifier = record["identifier"]?.stringValue ?? ""
    name = record["name"]?.stringValue ?? ""
    elevationFt = record["elevation_msl_ft"].flatMap(\.number)
    magneticVariationDeg = record["magnetic_variation_deg"].flatMap(\.number) ?? 0
    position = record["geometry"].flatMap(GeoPoint.init(geoJSON:))
    runways = record["runways"]?.arrayValue?.compactMap(\.objectValue) ?? []
  }

  /// Every runway end the record publishes, in record order.
  var endIdentifiers: [String] {
    runways.flatMap { $0["ends"]?.arrayValue ?? [] }.compactMap {
      $0.objectValue?["identifier"]?.stringValue
    }
  }

  /// The runway end named `name`, with its runway and the opposite end.
  func end(_ name: String) throws -> PerformanceRunwayEnd {
    for runway in runways {
      let ends = runway["ends"]?.arrayValue?.compactMap(\.objectValue) ?? []
      guard
        let index = ends.firstIndex(where: {
          $0["identifier"]?.stringValue.map(RunwayName.canonical) == RunwayName.canonical(name)
        })
      else { continue }
      return PerformanceRunwayEnd(
        runway: runway, end: ends[index],
        opposite: ends.indices.contains(1 - index)
          ? ends[1 - index] : nil)
    }
    throw ToolInputError(
      reason: "\(identifier) has no runway \(name) in the current NASR cycle; its runway ends are "
        + "\(endIdentifiers.joined(separator: ", ")).")
  }

  /// The airport as results echo it.
  var description: MCP.Value {
    .object([
      "id": .string(id), "identifier": .string(identifier), "name": .string(name)
    ])
  }
}

/// One runway end of a NASR airport record.
struct PerformanceRunwayEnd: Sendable {
  let runway: [String: MCP.Value]
  let end: [String: MCP.Value]
  let opposite: [String: MCP.Value]?

  var identifier: String { end["identifier"]?.stringValue ?? "" }
  var lengthFt: Double? { runway["length_ft"].flatMap(\.number) }

  func number(_ field: String) -> Double? { end[field].flatMap(\.number) }
}

/// Runway values the caller supplies in place of the published ones.
struct RunwayOverrides: Sendable {
  var elevationFt: Double?
  var headingTrueDeg: Double?
  var slopePercent: Double?
  var surface: SurfaceType?
  var takeoffRunFt: Double?
  var takeoffDistanceFt: Double?
  var landingDistanceFt: Double?

  init(
    elevationFt: Double? = nil, headingTrueDeg: Double? = nil, slopePercent: Double? = nil,
    surface: SurfaceType? = nil, takeoffRunFt: Double? = nil, takeoffDistanceFt: Double? = nil,
    landingDistanceFt: Double? = nil
  ) {
    self.elevationFt = elevationFt
    self.headingTrueDeg = headingTrueDeg
    self.slopePercent = slopePercent
    self.surface = surface
    self.takeoffRunFt = takeoffRunFt
    self.takeoffDistanceFt = takeoffDistanceFt
    self.landingDistanceFt = landingDistanceFt
  }

  init(_ arguments: ToolArguments) throws {
    elevationFt = try arguments.number("elevation_ft", range: -1_500...15_000)
    headingTrueDeg = try arguments.number("runway_heading_true_deg", range: 0...360)
    slopePercent = try arguments.number("slope_percent", range: -5...5)
    surface = try arguments.string("surface").map {
      guard let surface = SurfaceType(rawValue: $0) else {
        throw ToolInputError(reason: "surface must be paved, grooved, pfc or turf.")
      }
      return surface
    }
    takeoffRunFt = try arguments.number("available_takeoff_run_ft", range: 0...30_000)
    takeoffDistanceFt = try arguments.number("available_takeoff_distance_ft", range: 0...30_000)
    landingDistanceFt = try arguments.number("available_landing_distance_ft", range: 0...30_000)
  }

  /// Whether any value describing one particular runway end is overridden.
  var describesOneEnd: Bool {
    [headingTrueDeg, slopePercent, takeoffRunFt, takeoffDistanceFt, landingDistanceFt, elevationFt]
      .contains { $0 != nil } || surface != nil
  }
}

/// A runway end's performance inputs, each tagged with where it came from.
struct ResolvedRunway: Sendable {
  private static let unpavedMaterials: Set<String> = ["TURF", "DIRT", "GRVL", "GRE", "SAND"]
  private static let pavedMaterials: Set<String> = ["CONC", "ASPH", "PEM"]

  var name: String?
  var elevationFt: Sourced<Double>
  var headingTrueDeg: Sourced<Double>
  var slopePercent: Sourced<Double>
  var surface: Sourced<String>
  var takeoffRunFt: Sourced<Double>?
  var takeoffDistanceFt: Sourced<Double>?
  var landingDistanceFt: Sourced<Double>?
  var magneticVariationDeg = 0.0
  var warnings: [String] = []

  /// Resolves a runway end from its NASR record, letting every override win.
  ///
  /// - Parameters:
  ///   - airport: The airport record, or `nil` for a call that describes the runway itself.
  ///   - end: The runway end within `airport`.
  ///   - overrides: Values the caller supplies in place of the published ones.
  /// - Throws: ``ToolInputError`` when neither the record nor the overrides give the runway's
  ///   elevation or heading.
  static func resolve(
    airport: PerformanceAirport?, end: PerformanceRunwayEnd?, overrides: RunwayOverrides
  ) throws -> Self {
    var warnings: [String] = []
    guard let elevation = elevation(airport: airport, end: end, overrides, warnings: &warnings)
    else {
      throw ToolInputError(reason: "The runway elevation is unknown; supply elevation_ft.")
    }
    guard let heading = heading(end, overrides) else {
      throw ToolInputError(
        reason: "The runway true heading is unknown; supply runway_heading_true_deg.")
    }
    var runway = Self(
      name: end?.identifier, elevationFt: elevation, headingTrueDeg: heading,
      slopePercent: slope(end, overrides, warnings: &warnings),
      surface: surface(end, overrides, warnings: &warnings),
      magneticVariationDeg: airport?.magneticVariationDeg ?? 0)
    runway.takeoffRunFt = distance(
      overrides.takeoffRunFt, published: end?.number("tora_ft"), length: end?.lengthFt,
      label: "TORA")
    runway.takeoffDistanceFt =
      distanceFollowingRun(overrides: overrides, end: end, run: runway.takeoffRunFt)
    runway.landingDistanceFt = distance(
      overrides.landingDistanceFt, published: end?.number("lda_ft"),
      length: end?.lengthFt.map { $0 - (end?.number("threshold_displacement_ft") ?? 0) },
      label: "LDA")
    runway.warnings = warnings
    return runway
  }

  private static func elevation(
    airport: PerformanceAirport?, end: PerformanceRunwayEnd?, _ overrides: RunwayOverrides,
    warnings: inout [String]
  ) -> Sourced<Double>? {
    if let value = overrides.elevationFt { return Sourced(value, .override) }
    if let value = end?.number("threshold_elevation_msl_ft") { return Sourced(value, .nasr) }
    guard let value = airport?.elevationFt else { return nil }
    if end != nil {
      warnings.append(
        "NASR publishes no threshold elevation for this runway end; the airport elevation is used.")
    }
    return Sourced(value, .nasr, note: "airport elevation")
  }

  private static func heading(_ end: PerformanceRunwayEnd?, _ overrides: RunwayOverrides)
    -> Sourced<Double>?
  {
    if let value = overrides.headingTrueDeg { return Sourced(value, .override) }
    guard let end else { return nil }
    if let value = end.number("heading_true_deg") { return Sourced(value, .nasr) }
    guard let threshold = end.end["threshold"].flatMap(GeoPoint.init(geoJSON:)),
      let departure = end.end["departure_end"].flatMap(GeoPoint.init(geoJSON:)),
      threshold != departure
    else { return nil }
    let course = Geodesy.initialCourse(from: threshold, to: departure)
    return Sourced(
      (course + 360).truncatingRemainder(dividingBy: 360), .nasr,
      note: "course from the threshold to the departure end")
  }

  private static func slope(
    _ end: PerformanceRunwayEnd?, _ overrides: RunwayOverrides, warnings: inout [String]
  ) -> Sourced<Double> {
    if let value = overrides.slopePercent { return Sourced(value, .override) }
    if let value = end?.number("gradient_percent") { return Sourced(value, .nasr) }
    if let end, let length = end.lengthFt, length > 0,
      let near = end.number("threshold_elevation_msl_ft"),
      let far = end.opposite?["threshold_elevation_msl_ft"].flatMap(\.number)
    {
      return Sourced(
        (far - near) / length * 100, .nasr, note: "estimated from the threshold elevations")
    }
    if end != nil {
      warnings.append("NASR publishes no slope for this runway end; a level runway is assumed.")
    }
    return Sourced(0, .assumed, note: "level")
  }

  private static func surface(
    _ end: PerformanceRunwayEnd?, _ overrides: RunwayOverrides, warnings: inout [String]
  ) -> Sourced<String> {
    if let value = overrides.surface { return Sourced(value.rawValue, .override) }
    let materials = Set(
      end?.runway["materials"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    let paved = end?.runway["paved"]?.boolValue
    if paved == false || !materials.isDisjoint(with: unpavedMaterials) {
      return Sourced(SurfaceType.turf.rawValue, .nasr, note: "unpaved")
    }
    if paved == true || !materials.isDisjoint(with: pavedMaterials) {
      return Sourced(SurfaceType.paved.rawValue, .nasr)
    }
    if end != nil {
      warnings.append("NASR publishes no surface for this runway; a paved surface is assumed.")
    }
    return Sourced(SurfaceType.paved.rawValue, .assumed)
  }

  /// The takeoff distance available: the caller's, otherwise the run the caller overrode, since a
  /// shortened run leaves no clearway to count, otherwise the published distance or the run.
  private static func distanceFollowingRun(
    overrides: RunwayOverrides, end: PerformanceRunwayEnd?, run: Sourced<Double>?
  ) -> Sourced<Double>? {
    if overrides.takeoffDistanceFt == nil, overrides.takeoffRunFt != nil, let run {
      return Sourced(run.value, .override, note: "follows available_takeoff_run_ft")
    }
    return distance(
      overrides.takeoffDistanceFt, published: end?.number("toda_ft"), length: end?.lengthFt,
      label: "TODA") ?? run
  }

  private static func distance(
    _ override: Double?, published: Double?, length: Double?, label: String
  ) -> Sourced<Double>? {
    if let override { return Sourced(override, .override) }
    if let published { return Sourced(published, .nasr) }
    return length.map { Sourced($0, .nasr, note: "runway length; no \(label) is published") }
  }

  /// The runway as the performance models read it, with any contamination.
  func input(contamination: Contamination? = nil) -> RunwayInput {
    let distances = [takeoffRunFt, takeoffDistanceFt, landingDistanceFt].compactMap(\.?.value)
    func feet(_ value: Sourced<Double>?) -> Measurement<UnitLength>? {
      value.map { Measurement(value: $0.value, unit: .feet) }
    }
    return RunwayInput(
      id: name ?? "RWY", elevation: Measurement(value: elevationFt.value, unit: .feet),
      trueHeading: Measurement(value: headingTrueDeg.value, unit: .degrees),
      gradient: Float(slopePercent.value / 100),
      length: Measurement(value: distances.max() ?? 0, unit: .feet),
      takeoffRun: feet(takeoffRunFt), takeoffDistance: feet(takeoffDistanceFt),
      landingDistance: feet(landingDistanceFt),
      surfaceType: SurfaceType(rawValue: surface.value) ?? .paved,
      recordedSurfaceType: surface.origin == .assumed
        ? nil : SurfaceType(rawValue: surface.value),
      hasKnownGradient: slopePercent.origin != .assumed,
      notam: PerformanceContamination.notam(contamination),
      airportVariation: Measurement(value: magneticVariationDeg, unit: .degrees))
  }

  /// The inputs as results echo them.
  func provenance() throws -> [String: MCP.Value] {
    var fields: [String: MCP.Value] = [
      "elevation_ft": try .encoded(elevationFt),
      "runway_heading_true_deg": try .encoded(headingTrueDeg),
      "slope_percent": try .encoded(slopePercent), "surface": try .encoded(surface)
    ]
    fields["runway"] = name.map(MCP.Value.string)
    fields["available_takeoff_run_ft"] = try takeoffRunFt.map(MCP.Value.encoded)
    fields["available_takeoff_distance_ft"] = try takeoffDistanceFt.map(MCP.Value.encoded)
    fields["available_landing_distance_ft"] = try landingDistanceFt.map(MCP.Value.encoded)
    return fields
  }
}

extension GeoPoint {
  /// The point a GeoJSON `Point` describes.
  init?(geoJSON: MCP.Value) {
    guard let coordinates = geoJSON.objectValue?["coordinates"]?.arrayValue,
      coordinates.count >= 2, let longitude = coordinates[0].number,
      let latitude = coordinates[1].number
    else { return nil }
    self.init(latitude: latitude, longitude: longitude)
  }
}

extension MCP.Value {
  /// The value as a double, whether it was encoded as an integer or a double.
  var number: Double? { doubleValue ?? intValue.map(Double.init) }
}

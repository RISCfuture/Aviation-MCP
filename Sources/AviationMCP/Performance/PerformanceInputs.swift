import AircraftPerformance
import Foundation
import MCP
import MeasurementKit

/// Where a performance input came from.
enum InputOrigin: String, Codable, Sendable {
  case nasr, metar, taf, override, isa, assumed
  case openMeteo = "open_meteo"
}

/// An input value tagged with its origin, as every performance result echoes it.
struct Sourced<Content: Encodable & Sendable>: Encodable, Sendable {
  let value: Content
  let origin: InputOrigin
  var time: Date?
  var note: String?

  init(_ value: Content, _ origin: InputOrigin, time: Date? = nil, note: String? = nil) {
    self.value = value
    self.origin = origin
    self.time = time
    self.note = note
  }
}

/// Runway contamination given as tool arguments.
enum PerformanceContamination {
  static let types = [
    "wet", "water_or_slush", "slush_or_wet_snow", "dry_snow", "compact_snow", "rwycc"
  ]

  private static let depthTypes = ["water_or_slush", "slush_or_wet_snow"]

  /// The contamination named by `contamination`, `contamination_depth_in` and `rwycc`, or `nil`
  /// for a dry runway.
  static func parse(_ arguments: ToolArguments) throws -> Contamination? {
    let depth = try arguments.number("contamination_depth_in", range: 0...4)
    let code = try arguments.number("rwycc", range: 1...6)
    guard let type = try arguments.string("contamination") else {
      guard depth == nil, code == nil else {
        throw ToolInputError(reason: "contamination_depth_in and rwycc require contamination.")
      }
      return nil
    }
    try validate(type, depth: depth, code: code)
    switch type {
    case "wet": return .wetRunway
    case "dry_snow": return .drySnow
    case "compact_snow": return .compactSnow
    case "water_or_slush", "slush_or_wet_snow":
      guard let depth, depth > 0 else {
        throw ToolInputError(reason: "\(type) requires a contamination_depth_in above zero.")
      }
      let measured = Measurement(value: depth, unit: UnitLength.inches)
      return type == "water_or_slush"
        ? .waterOrSlush(depth: measured) : .slushOrWetSnow(depth: measured)
    case "rwycc":
      guard let code, code.rounded() == code else {
        throw ToolInputError(reason: "rwycc contamination requires an integer rwycc from 1 to 6.")
      }
      return .rwyCC(UInt8(code))
    default:
      throw ToolInputError(reason: "contamination must be one of \(types.joined(separator: ", ")).")
    }
  }

  private static func validate(_ type: String, depth: Double?, code: Double?) throws {
    guard types.contains(type) else {
      throw ToolInputError(reason: "contamination must be one of \(types.joined(separator: ", ")).")
    }
    if depth != nil, !depthTypes.contains(type) {
      throw ToolInputError(
        reason: "contamination_depth_in applies only to \(depthTypes.joined(separator: " and ")).")
    }
    if code != nil, type != "rwycc" {
      throw ToolInputError(reason: "rwycc applies only to rwycc contamination.")
    }
  }

  /// Refuses a contamination the aircraft's manuals have no figures for on this runway.
  ///
  /// An aircraft with contaminated-runway figures takes any contamination on landing. One with a
  /// wet unpaved correction takes a wet turf runway, for takeoff and landing alike.
  static func check(
    _ contamination: Contamination?, aircraft: PerformanceAircraft, runway: RunwayInput,
    operation: AircraftPerformance.Operation
  ) throws {
    guard let contamination else { return }
    let capabilities = aircraft.aircraft.capabilities
    if operation == .landing, capabilities.contains(.contamination) { return }
    if contamination == .wetRunway, runway.surfaceType.isTurf,
      capabilities.contains(.wetUnpavedCorrection)
    {
      return
    }
    throw ToolInputError(
      reason: unsupported(contamination, aircraft: aircraft, operation: operation))
  }

  private static func unsupported(
    _ contamination: Contamination, aircraft: PerformanceAircraft,
    operation: AircraftPerformance.Operation
  ) -> String {
    let capabilities = aircraft.aircraft.capabilities
    if capabilities.contains(.wetUnpavedCorrection) {
      return "The \(aircraft.title) manuals correct only for a wet turf runway; contamination "
        + "applies only as wet with surface turf."
    }
    if operation == .takeoff, capabilities.contains(.contamination) {
      return "The \(aircraft.title) manuals give contaminated-runway figures only for landing."
    }
    return "The \(aircraft.title) manuals have no contaminated-runway figures."
  }

  /// A contamination as results echo it, or `nil` for a dry runway.
  static func json(_ contamination: Contamination?) -> MCP.Value? {
    guard let contamination else { return nil }
    var fields: [String: MCP.Value] = ["origin": "override"]
    switch contamination {
    case .wetRunway: fields["type"] = "wet"
    case .drySnow: fields["type"] = "dry_snow"
    case .compactSnow: fields["type"] = "compact_snow"
    case .waterOrSlush(let depth), .slushOrWetSnow(let depth):
      fields["type"] = .string(
        contamination.type == "waterOrSlush" ? "water_or_slush" : "slush_or_wet_snow")
      fields["depth_in"] = .double(depth.converted(to: .inches).value)
    case .rwyCC(let code):
      fields["type"] = "rwycc"
      fields["rwycc"] = .int(Int(code))
    }
    return .object(fields)
  }
  /// A NOTAM snapshot carrying only a contamination, as the performance models read it.
  static func notam(_ contamination: Contamination?) -> NOTAMInput? {
    guard let contamination else { return nil }
    return NOTAMInput(
      contaminationType: contamination.type,
      contaminationDepth: Measurement(value: contamination.depth ?? 0, unit: .meters),
      rwyCC: contamination.rwyCC, takeoffDistanceShortening: .zero,
      landingDistanceShortening: .zero, obstacleHeight: .zero, obstacleDistance: .zero)
  }
}

extension ToolArguments {
  /// The obstacle named by `obstacle_height_ft` and `obstacle_distance_ft`, which come together.
  func obstacle() throws -> Obstacle? {
    let height = try number("obstacle_height_ft", range: 0...3_000)
    let distance = try number("obstacle_distance_ft", range: 0...100_000)
    guard let height, let distance else {
      guard height == nil, distance == nil else {
        throw ToolInputError(
          reason: "obstacle_height_ft and obstacle_distance_ft must be given together.")
      }
      return nil
    }
    return Obstacle(
      height: Measurement(value: height, unit: .feet),
      distanceFromDepartureEnd: Measurement(value: distance, unit: .feet))
  }
}

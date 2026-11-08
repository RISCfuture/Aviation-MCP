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

/// The aircraft a calculation is for: its generation, weight and the engine settings.
struct PerformanceAircraft: Sendable {
  static let generations = ["g1", "g2", "g2_updated_thrust", "g2_plus", "g3"]
  static let landingFlaps = ["up", "up_ice", "50", "50_ice", "100"]

  let generation: String
  let type: SF50Variant
  let weight: Measurement<UnitMass>?
  let settings: PerformanceSettings

  var model: PerformanceModelKind { settings.modelKind }
  var limitations: AircraftLimitations { settings.limitations }

  init(_ arguments: ToolArguments, requiringWeight: Bool = true) throws {
    generation = try arguments.string("aircraft_generation", required: true) ?? ""
    type = try Self.aircraftType(generation)
    weight = try arguments.number("weight_lb", range: 3_000...7_000).map {
      Measurement(value: $0, unit: .pounds)
    }
    if requiringWeight, weight == nil {
      throw MCPError.invalidParams("weight_lb is required")
    }
    let model = try arguments.string("model") ?? PerformanceModelKind.tabular.rawValue
    guard let kind = PerformanceModelKind(rawValue: model) else {
      throw ToolInputError(reason: "model must be tabular or regression.")
    }
    let safetyFactor = try arguments.number("safety_factor", default: 1, range: 1...3) ?? 1
    settings = PerformanceSettings(
      aircraft: .sf50(type), modelKind: kind, safetyFactorDry: safetyFactor,
      safetyFactorContaminated: safetyFactor,
      VREFAdditive: Measurement(
        value: try arguments.number("vref_additive_kt", default: 0, range: 0...20) ?? 0,
        unit: .knots))
  }

  /// The weight, refused when it exceeds the structural maximum for the operation.
  func weight(within maximum: Measurement<UnitMass>, operation: String) throws
    -> Measurement<UnitMass>
  {
    guard let weight else { throw MCPError.invalidParams("weight_lb is required") }
    guard weight <= maximum else {
      throw ToolInputError(
        reason: "weight_lb exceeds the \(generation) maximum \(operation) weight of "
          + "\(Int(maximum.converted(to: .pounds).value)) lb; the AFM gives no data above it.")
    }
    return weight
  }

  /// The landing flap setting, 100% unless the caller names another.
  static func landingFlapSetting(_ arguments: ToolArguments) throws -> FlapSetting {
    switch try arguments.string("flaps") ?? "100" {
    case "up": .flapsUp
    case "up_ice": .flapsUpIce
    case "50": .flaps50
    case "50_ice": .flaps50Ice
    case "100": .flaps100
    default:
      throw ToolInputError(
        reason: "flaps must be one of \(landingFlaps.joined(separator: ", ")).")
    }
  }

  private static func aircraftType(_ generation: String) throws -> SF50Variant {
    switch generation {
    case "g1": .g1
    case "g2": .g2(updatedThrustSchedule: false)
    case "g2_updated_thrust": .g2(updatedThrustSchedule: true)
    case "g2_plus": .g2Plus
    case "g3": .g3
    default:
      throw ToolInputError(
        reason: "aircraft_generation must be one of \(generations.joined(separator: ", ")).")
    }
  }

  /// The aircraft as results echo it.
  ///
  /// - Parameter includingSafetyFactor: Whether to echo the safety factor, which does not apply
  ///   to a climb profile.
  func description(includingSafetyFactor: Bool = true) -> MCP.Value {
    var fields: [String: MCP.Value] = [
      "generation": .string(generation), "model": .string(model.rawValue)
    ]
    if includingSafetyFactor { fields["safety_factor"] = .double(settings.safetyFactorDry) }
    fields["weight_lb"] = weight.map { .double($0.converted(to: .pounds).value) }
    return .object(fields)
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

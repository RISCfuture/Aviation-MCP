import AircraftPerformance
import Foundation
import MCP
import MeasurementKit

/// The `aircraft` argument: an object whose `type` names the aircraft and whose other fields name
/// the options installed on it.
enum AircraftArgument {
  /// Every aircraft the tools calculate for, in every configuration; the schemas are built from
  /// what these have in common and where they differ.
  static let all: [Aircraft] =
    SF50Generations.variants.map { .sf50($0.value) } + SR22Fields.allOptions.map(Aircraft.sr22)

  /// The aircraft an `aircraft` object names.
  ///
  /// - Throws: `MCPError.invalidParams` for a malformed object, and ``ToolInputError`` for one
  ///   naming an aircraft or option the tools don't know.
  static func parse(_ value: MCP.Value?) throws -> Aircraft {
    guard let fields = value?.objectValue else {
      throw MCPError.invalidParams("aircraft must be an object with a type")
    }
    let arguments = ToolArguments(fields)
    switch try arguments.string("type", required: true) {
    case "sf50":
      try rejectUnknownFields(fields, accepted: ["type", "generation"])
      return .sf50(try SF50Generations.variant(arguments))
    case "sr22":
      try rejectUnknownFields(fields, accepted: ["type", SR22Fields.hartzell, SR22Fields.turbo])
      return .sr22(try SR22Fields.options(arguments))
    default:
      throw ToolInputError(reason: "aircraft type must be sf50 or sr22.")
    }
  }

  /// The aircraft as results echo it, in the shape the `aircraft` argument takes.
  static func description(_ aircraft: Aircraft) -> [String: MCP.Value] {
    switch aircraft {
    case .sf50(let variant): ["type": "sf50", "generation": .string(SF50Generations.name(variant))]
    case .sr22(let options):
      [
        "type": "sr22", SR22Fields.hartzell: .bool(options.hartzellPropeller),
        SR22Fields.turbo: .bool(options.turbonormalized)
      ]
    }
  }

  private static func rejectUnknownFields(_ fields: [String: MCP.Value], accepted: Set<String>)
    throws
  {
    let unknown = Set(fields.keys).subtracting(accepted).sorted()
    guard unknown.isEmpty else {
      throw MCPError.invalidParams(
        "aircraft does not accept \(unknown.joined(separator: ", ")); it accepts "
          + "\(accepted.sorted().joined(separator: ", ")).")
    }
  }
}

/// SF50 variants as the `generation` field names them.
enum SF50Generations {
  static let variants: KeyValuePairs<String, SF50Variant> = [
    "g1": .g1, "g2": .g2(updatedThrustSchedule: false),
    "g2_updated_thrust": .g2(updatedThrustSchedule: true), "g2_plus": .g2Plus, "g3": .g3
  ]

  static var names: [String] { variants.map(\.key) }

  /// The variant the `generation` field names.
  static func variant(_ arguments: ToolArguments) throws -> SF50Variant {
    let name = try arguments.string("generation", required: true)
    guard let variant = variants.first(where: { $0.key == name })?.value else {
      throw ToolInputError(
        reason: "An SF50's generation must be one of \(names.joined(separator: ", ")).")
    }
    return variant
  }

  /// The `generation` name of a variant.
  static func name(_ variant: SF50Variant) -> String {
    guard let name = variants.first(where: { $0.value == variant })?.key else {
      preconditionFailure("Every SF50 variant has a generation name.")
    }
    return name
  }
}

/// The SR22 options as the `aircraft` argument's fields name them.
enum SR22Fields {
  static let hartzell = "hartzell_propeller"
  static let turbo = "turbonormalized"

  /// Every combination of the options.
  static let allOptions = [false, true].flatMap { hartzell in
    [false, true].map { SR22Options(hartzellPropeller: hartzell, turbonormalized: $0) }
  }

  /// The options the fields name, both of which are required.
  static func options(_ arguments: ToolArguments) throws -> SR22Options {
    guard let hartzellPropeller = try arguments.boolean(hartzell),
      let turbonormalized = try arguments.boolean(turbo)
    else {
      throw MCPError.invalidParams("An SR22 requires \(hartzell) and \(turbo).")
    }
    return SR22Options(hartzellPropeller: hartzellPropeller, turbonormalized: turbonormalized)
  }
}

/// Which tool a performance calculation was called through.
///
/// The `sf50_*` tools are deprecated aliases of the aircraft-neutral tools, kept until the clients
/// built against them have moved, and then to be removed. They take `aircraft_generation` in place
/// of the `aircraft` object and leave the multi-aircraft fields out of their results.
enum PerformanceInterface: Sendable {
  case current
  case sf50Alias

  /// The weights an SF50 alias accepts.
  static let sf50AliasWeightRangeLb = 3_000.0...7_000.0
}

/// The aircraft a calculation is for: its configuration, weight and the engine settings.
struct PerformanceAircraft: Sendable {
  /// The weights the `weight_lb` arguments accept, wide enough for every aircraft; each
  /// calculation then holds the weight to its aircraft's structural maximum.
  static let weightRangeLb =
    lightestAcceptedWeightLb...AircraftArgument.all.map {
      $0.limitations.maxTakeoffWeight.converted(to: .pounds).value
    }.max()!

  /// The highest maximum operating altitude of any aircraft, which bounds a climb's top.
  static let highestCeilingFt = AircraftArgument.all.map {
    $0.limitations.maxEnrouteAltitude.converted(to: .feet).value
  }.max()!

  private static let lightestAcceptedWeightLb = 1_000.0

  let aircraft: Aircraft
  let interface: PerformanceInterface
  let weight: Measurement<UnitMass>?
  let settings: PerformanceSettings
  /// The manuals the figures come from, and the guidance that goes with them.
  let configuration: AircraftConfigurationInfo

  var model: PerformanceModelKind { settings.modelKind }
  var limitations: AircraftLimitations { aircraft.limitations }
  var title: String { configuration.aircraftTitle }

  /// The weights the `weight_lb` arguments accept.
  var weightRangeLb: ClosedRange<Double> {
    switch interface {
    case .current: Self.weightRangeLb
    case .sf50Alias: PerformanceInterface.sf50AliasWeightRangeLb
    }
  }

  /// The aircraft as error messages name it.
  private var name: String {
    switch (interface, aircraft) {
    case (.sf50Alias, .sf50(let variant)): SF50Generations.name(variant)
    default: title
    }
  }

  init(
    _ arguments: ToolArguments, through interface: PerformanceInterface,
    requiringWeight: Bool = true
  ) throws {
    self.interface = interface
    aircraft = try Self.aircraft(arguments, through: interface)
    configuration = try aircraft.configurationInfo()
    let weightRangeLb =
      interface == .sf50Alias ? PerformanceInterface.sf50AliasWeightRangeLb : Self.weightRangeLb
    weight = try arguments.number("weight_lb", range: weightRangeLb).map {
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
    let additive = Measurement(
      value: try arguments.number("vref_additive_kt", default: 0, range: 0...20) ?? 0,
      unit: UnitSpeed.knots)
    settings = PerformanceSettings(
      aircraft: aircraft, modelKind: kind, safetyFactorDry: safetyFactor,
      safetyFactorContaminated: safetyFactor, VREFAdditive: additive)
    if additive.value > 0 { try require(.vref, for: "vref_additive_kt") }
  }

  /// The weight, refused when it exceeds the structural maximum for the operation.
  func weight(within maximum: Measurement<UnitMass>, operation: String) throws
    -> Measurement<UnitMass>
  {
    guard let weight else { throw MCPError.invalidParams("weight_lb is required") }
    guard weight <= maximum else {
      throw ToolInputError(
        reason: "weight_lb exceeds the \(name) maximum \(operation) weight of "
          + "\(Int(maximum.converted(to: .pounds).value)) lb; the AFM gives no data above it.")
    }
    return weight
  }

  /// The lightest weight the manual's takeoff tables cover, where a takeoff weight search starts
  /// by default.
  ///
  /// - Throws: ``ToolInputError`` for an aircraft whose takeoff tables give no weights.
  func lightestTakeoffWeight() throws -> Measurement<UnitMass> {
    guard
      let weights = try aircraft.tabulatedWeights(
        for: .takeoff, flapSetting: PerformanceCalculator.takeoffFlapSetting)
    else {
      throw ToolInputError(
        reason: "The \(title) takeoff tables give no weights; supply minimum_weight_lb.")
    }
    return weights.lowerBound
  }

  /// The aircraft the `aircraft` object names, or the SF50 that `aircraft_generation` names.
  private static func aircraft(_ arguments: ToolArguments, through interface: PerformanceInterface)
    throws -> Aircraft
  {
    guard interface == .sf50Alias else {
      return try AircraftArgument.parse(arguments.values["aircraft"])
    }
    let generation = try arguments.string("aircraft_generation", required: true)
    guard let variant = SF50Generations.variants.first(where: { $0.key == generation })?.value
    else {
      throw ToolInputError(
        reason: "aircraft_generation must be one of "
          + "\(SF50Generations.names.joined(separator: ", ")).")
    }
    return .sf50(variant)
  }

  /// Whether the `air_conditioner` argument has it on, refused for an aircraft whose manual has no
  /// correction for it.
  func airConditioner(_ arguments: ToolArguments) throws -> Bool {
    guard try arguments.boolean("air_conditioner") == true else { return false }
    try require(.airConditionerCorrection, for: "air_conditioner")
    return true
  }

  /// The takeoff configuration as results echo it.
  func takeoffEcho(airConditioner: Bool) -> [String: MCP.Value] {
    var fields: [String: MCP.Value] = [
      "flaps": .string(PerformanceCalculator.takeoffFlapSetting.argument)
    ]
    if aircraft.capabilities.contains(.airConditionerCorrection) {
      fields["air_conditioner"] = .bool(airConditioner)
    }
    return fields
  }

  /// The altitude a climb ends at, refused above the aircraft's maximum operating altitude.
  func climbTopFt(_ arguments: ToolArguments) throws -> Double {
    let altitudeFt =
      try arguments.number("top_altitude_ft", range: 0...Self.highestCeilingFt) ?? 0
    let ceilingFt = limitations.maxEnrouteAltitude.converted(to: .feet).value
    guard interface == .sf50Alias || altitudeFt <= ceilingFt else {
      throw ToolInputError(
        reason: "top_altitude_ft is above the \(title) maximum operating altitude of "
          + "\(Int(ceilingFt)) ft.")
    }
    return altitudeFt
  }

  /// Refuses an argument that asks for figures the aircraft's manuals don't have.
  func require(_ capability: PerformanceCapability, for argument: String) throws {
    guard aircraft.capabilities.contains(capability) else {
      throw ToolInputError(
        reason: "\(argument) does not apply to the \(title): its manuals have no "
          + "\(capability.rawValue.replacing("_", with: " ")) figures.")
    }
  }

  /// The landing flap setting the arguments name, or the aircraft's fullest one by default.
  func landingFlapSetting(_ arguments: ToolArguments) throws -> FlapSetting {
    let offered = aircraft.landingFlapSettings
    guard let name = try arguments.string("flaps") else {
      return offered.contains(.flaps100) ? .flaps100 : offered[0]
    }
    guard let setting = offered.first(where: { $0.argument == name }) else {
      throw ToolInputError(
        reason: interface == .sf50Alias
          ? "flaps must be one of \(offered.map(\.argument).joined(separator: ", "))."
          : "The \(title) manuals give landing figures for flaps "
            + "\(offered.map(\.argument).joined(separator: ", ")).")
    }
    return setting
  }

  /// The aircraft as results echo it, with the manuals its figures come from.
  ///
  /// - Parameter includingSafetyFactor: Whether to echo the safety factor, which does not apply
  ///   to a climb profile.
  func description(includingSafetyFactor: Bool = true) -> MCP.Value {
    var fields =
      interface == .sf50Alias ? sf50AliasDescription : AircraftArgument.description(aircraft)
    if includingSafetyFactor { fields["safety_factor"] = .double(settings.safetyFactorDry) }
    fields["weight_lb"] = weight.map { .double($0.converted(to: .pounds).value) }
    guard interface == .current else { return .object(fields) }
    fields.merge([
      "title": .string(title), "model": .string(model.rawValue),
      "capabilities": .array(aircraft.capabilities.map(\.rawValue).sorted().map(MCP.Value.string)),
      "documents": .array(configuration.documents.map(Self.document))
    ]) { $1 }
    return .object(fields)
  }

  /// The aircraft as the SF50 aliases echo it: its generation and model.
  private var sf50AliasDescription: [String: MCP.Value] {
    ["generation": .string(name), "model": .string(model.rawValue)]
  }

  /// The planning disclaimer and the guidance that goes with the aircraft's manuals.
  var disclaimers: [String] {
    guard interface == .current else { return [FigureEncoder.disclaimer] }
    return [FigureEncoder.disclaimer]
      + configuration.notes.map { note in
        "\(note.subject.prefix(1).uppercased())\(note.subject.dropFirst()): \(note.text)"
          + (note.sources.isEmpty ? "" : " Sources: \(note.sources.joined(separator: "; ")).")
      }
  }

  /// The outputs a result leaves out because the aircraft's manuals have no figures for them,
  /// or `nil` when it leaves none out or answers through an SF50 alias.
  ///
  /// - Parameter outputs: Each output a result can carry, with the capability it needs.
  func unavailable(_ outputs: [(output: String, capability: PerformanceCapability)]) -> MCP.Value? {
    let missing = outputs.filter { !aircraft.capabilities.contains($0.capability) }
    guard interface == .current, !missing.isEmpty else { return nil }
    return .array(
      missing.map { output, capability in
        .object([
          "output": .string(output), "capability": .string(capability.rawValue),
          "reason": .string(
            "The \(title) manuals have no \(capability.rawValue.replacing("_", with: " ")) "
              + "figures.")
        ])
      })
  }

  private static func document(_ document: AircraftConfigurationInfo.Document) -> MCP.Value {
    var fields: [String: MCP.Value] = [
      "title": .string(document.title), "part_number": .string(document.partNumber),
      "revision": .string(document.revision), "supplement": .bool(document.isSupplement)
    ]
    if !document.errata.isEmpty {
      fields["errata"] = .array(
        document.errata.map { erratum in
          .object([
            "table": .string(erratum.table),
            "cell": .object(erratum.cell.mapValues(MCP.Value.double)),
            "printed": .double(erratum.printed), "corrected": .double(erratum.corrected),
            "reason": .string(erratum.reason)
          ])
        })
    }
    return .object(fields)
  }
}

extension FlapSetting {
  /// The setting as the `flaps` argument and results name it.
  var argument: String {
    switch self {
    case .flapsUp: "up"
    case .flapsUpIce: "up_ice"
    case .flaps50: "50"
    case .flaps50Ice: "50_ice"
    case .flaps100: "100"
    }
  }

  /// Whether the setting is with ice protection on.
  var isIceProtected: Bool { self == .flapsUpIce || self == .flaps50Ice }
}

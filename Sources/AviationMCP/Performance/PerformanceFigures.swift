import AircraftPerformance
import Foundation
import MCP
import MeasurementKit

/// Turns the performance models' figures into JSON, collecting a warning for each figure the
/// model could not stand behind.
///
/// Every figure becomes `{status, value?, uncertainty?, clamped_value?}`, where `status` is
/// `value`, `uncertain`, `offscale_high`, `offscale_low`, `not_available`, `not_authorized` or
/// `invalid`. Nothing is substituted for a figure the model refused.
struct FigureEncoder {
  /// Text sent to every performance result.
  static let disclaimer =
    "This tool has not been approved by the FAA or by Cirrus Aircraft as an official source of "
    + "performance information. Always verify performance information with official sources "
    + "when using this tool. For pre-flight planning only, not for cockpit use."
  /// The AFM's qualification of its contaminated-runway data.
  static let contaminationDisclaimer =
    "Contaminated runway performance data is considered supplemental and is not FAA approved."

  let model: PerformanceModelKind
  private(set) var warnings: [String] = []
  private(set) var isPartial = false
  private var suggestsRegression = false

  init(model: PerformanceModelKind) {
    self.model = model
  }

  /// The collected warnings, ending with a suggestion to retry with the regression model when a
  /// tabular figure was offscale or not available.
  var allWarnings: [String] {
    warnings
      + (suggestsRegression
        ? [
          "Retry with model \"regression\", which extrapolates past the AFM tables and reports an "
            + "uncertainty."
        ] : [])
  }

  /// A figure in whole units of `unit`.
  mutating func encode<UnitType: Dimension>(
    _ figure: AircraftPerformance.Value<Measurement<UnitType>>, _ name: String, in unit: UnitType
  ) -> MCP.Value {
    encode(figure, name) { .double($0.converted(to: unit).value.rounded()) }
  }

  /// A figure already in its unit, rounded to whole units.
  mutating func encode(_ figure: AircraftPerformance.Value<Double>, _ name: String) -> MCP.Value {
    encode(figure, name) { .double($0.rounded()) }
  }

  /// A yes-or-no figure.
  mutating func encode(_ figure: AircraftPerformance.Value<Bool>, _ name: String) -> MCP.Value {
    encode(figure, name, number: MCP.Value.bool)
  }

  /// Records a warning that a result rests on figures the AFM tables do not cover.
  mutating func noteOffscale(_ name: String) {
    isPartial = true
    warnings.append(
      "\(name) rests on figures held at the edge of the AFM tables, so the AFM does not fully "
        + "support it.")
    suggestsRegression = suggestsRegression || model == .tabular
  }

  /// Marks the result partial with a warning of its own.
  mutating func warn(_ warning: String) {
    isPartial = true
    warnings.append(warning)
  }

  private mutating func encode<T>(
    _ figure: AircraftPerformance.Value<T>, _ name: String, number: (T) -> MCP.Value
  ) -> MCP.Value {
    switch figure {
    case .value, .valueWithUncertainty: break
    case .offscaleHigh(let clamped), .offscaleLow(let clamped):
      refuse(
        name,
        "is offscale \(figure.isOffscaleHigh ? "high" : "low"): the conditions lie beyond the AFM "
          + "tables"
          + (clamped == nil
            ? "." : ", and clamped_value is the figure at the table edge, not a prediction."),
        suggestingRegression: true)
    case .notAvailable:
      refuse(
        name, "is not available: the AFM data gives no figure here.", suggestingRegression: true)
    case .notAuthorized:
      refuse(
        name, "is not authorized: the AFM does not permit this operation.",
        suggestingRegression: false)
    case .invalid:
      refuse(name, "is invalid for these inputs.", suggestingRegression: false)
    }
    return Self.json(figure, number: number)
  }

  /// A figure's JSON, without recording a warning for it.
  static func json<T>(
    _ figure: AircraftPerformance.Value<T>, number: (T) -> MCP.Value
  ) -> MCP.Value {
    var fields: [String: MCP.Value]
    switch figure {
    case .value(let value):
      fields = ["status": "value", "value": number(value)]
    case .valueWithUncertainty(let value, let uncertainty):
      fields = ["status": "uncertain", "value": number(value), "uncertainty": number(uncertainty)]
    case .offscaleHigh(let clamped), .offscaleLow(let clamped):
      fields = ["status": figure.isOffscaleHigh ? "offscale_high" : "offscale_low"]
      fields["clamped_value"] = clamped.map(number)
    case .notAvailable: fields = ["status": "not_available"]
    case .notAuthorized: fields = ["status": "not_authorized"]
    case .invalid: fields = ["status": "invalid"]
    }
    return .object(fields)
  }

  /// A figure in whole feet, without recording a warning for it.
  static func feet(_ figure: AircraftPerformance.Value<Double>) -> MCP.Value {
    json(figure) { .double($0.rounded()) }
  }

  private mutating func refuse(_ name: String, _ reason: String, suggestingRegression: Bool) {
    isPartial = true
    warnings.append("\(name) \(reason)")
    suggestsRegression = suggestsRegression || (suggestingRegression && model == .tabular)
  }
}

/// JSON for the parts of a performance report that are not single figures.
enum PerformanceJSON {
  /// A distance's base figure and each correction the model applied, in order. The distance's
  /// own figure carries any warning, so these figures add none.
  static func breakdown(_ breakdown: DistanceBreakdown) -> MCP.Value {
    .object([
      "base_ft": FigureEncoder.feet(breakdown.baseFt),
      "adjustments": .array(
        breakdown.adjustments.map { adjustment in
          .object([
            "kind": .string(adjustment.kind.code),
            "description": .string(adjustment.kind.localizedDescription),
            "multiplier": .double((adjustment.multiplier * 1000).rounded() / 1000),
            "result_ft": FigureEncoder.feet(adjustment.resultFt)
          ])
        })
    ])
  }

  /// Each note as a code, a severity and the message the app shows.
  static func notes(_ notes: [PerformanceNote]) -> MCP.Value {
    .array(
      notes.map {
        .object([
          "code": .string($0.code),
          "severity": .string($0.severity == .warning ? "warning" : "info"),
          "message": .string($0.localizedDescription)
        ])
      })
  }

  /// What a figure held at the edge of the AFM tables means for anything built on it.
  static let clampedNote =
    "The AFM tables do not cover these conditions; this uses the figure at the table edge, "
    + "not a prediction."

  /// A required distance against the available one, marked when the required figure is the
  /// clamped value of an offscale one.
  static func margin(
    required: AircraftPerformance.Value<Measurement<UnitLength>>, available: Measurement<UnitLength>
  ) -> MCP.Value {
    let availableFt = available.converted(to: .feet).value.rounded()
    var fields: [String: MCP.Value] = ["available_ft": .double(availableFt)]
    if let requiredFt = required.nominalOrClamped?.converted(to: .feet).value.rounded() {
      fields["required_ft"] = .double(requiredFt)
      fields["margin_ft"] = .double(availableFt - requiredFt)
      if required.isOffscale {
        fields["basis"] = "clamped"
        fields["basis_note"] = .string(clampedNote)
      }
    }
    return .object(fields)
  }

  /// The wind resolved along and across the runway; positive is a headwind and a crosswind from
  /// the right.
  static func windComponents(_ runway: RunwayInput, conditions: Conditions) -> MCP.Value {
    .object([
      "headwind_kt": .double(
        (runway.headwind(conditions: conditions).converted(to: .knots).value * 10).rounded() / 10),
      "crosswind_kt": .double(
        (runway.crosswind(conditions: conditions).converted(to: .knots).value * 10).rounded() / 10)
    ])
  }

  /// A climb gradient in whole feet per nautical mile.
  static func feetPerNauticalMile(_ gradient: Measurement<UnitSlope>) -> Double {
    gradient.converted(to: .feetPerNauticalMile).value.rounded()
  }
}

extension AdjustmentKind {
  /// The adjustment's name in results.
  var code: String {
    switch self {
    case .headwind: "headwind"
    case .tailwind: "tailwind"
    case .uphillGradient: "uphill_slope"
    case .downhillGradient: "downhill_slope"
    case .unpavedSurface: "unpaved_surface"
    case .wetUnpavedSurface: "wet_unpaved_surface"
    case .airConditioner: "air_conditioner"
    case .contamination: "contamination"
    case .safetyMargin: "safety_factor"
    case .VREFAdditive: "vref_additive"
    }
  }

}

extension PerformanceNote {
  /// The note's name in results.
  var code: String {
    switch self {
    case .offscaleHigh: "offscale_high"
    case .offscaleLow: "offscale_low"
    case .contaminationSupplemental: "contamination_supplemental"
    case .rwyCCSafetyFactorNotApplied: "rwycc_safety_factor_not_applied"
    case .VREFAdditiveApproximate: "vref_additive_approximate"
    case .pressureAltitudeFromFieldElevation: "pressure_altitude_from_field_elevation"
    case .crosswindExceedance: "crosswind_exceeds_demonstrated"
    case .tailwindExceedance: "tailwind_exceeds_limit"
    case .weightAboveMax: "weight_above_maximum"
    case .zeroFuelWeightExceeded: "zero_fuel_weight_above_maximum"
    case .fuelExceedsCapacity: "fuel_exceeds_capacity"
    case .airportElevationOutsideLimits, .airportElevationAboveLimit, .airportElevationBelowLimit:
      "elevation_outside_limits"
    case .temperatureOutsideLimits, .temperatureAboveLimit, .temperatureBelowLimit:
      "temperature_outside_limits"
    case .takeoffDistanceExceedsAvailable: "takeoff_distance_exceeds_available"
    case .takeoffRunExceedsAvailable: "takeoff_run_exceeds_available"
    case .landingDistanceExceedsAvailable: "landing_distance_exceeds_available"
    case .insufficientClimbGradient: "insufficient_climb_gradient"
    case .obstacleWithinTakeoffDistance: "obstacle_within_takeoff_distance"
    case .doesNotMeetGoAroundGradient: "does_not_meet_go_around_gradient"
    }
  }
}

extension AircraftPerformance.Value {
  /// Whether the model held an input at the edge of its data, whether or not it substituted a
  /// figure.
  var isOffscale: Bool { isOffscaleHigh || isOffscaleLow }
}

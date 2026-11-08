import AircraftPerformance
import Foundation
import MeasurementKit
import Testing

/// The package's figures, rounded and keyed as results give them, for the fixtures' runway and
/// weather built from their raw values, so a tool reading any of them wrongly disagrees.
enum PackageFigures {
  /// The fixture METAR's wind and temperature with the model's altimeter setting.
  private static let reportedConditions = Conditions(
    windDirection: .init(value: 280, unit: .degrees), windSpeed: .init(value: 10, unit: .knots),
    temperature: .init(value: 15, unit: .celsius),
    seaLevelPressure: .init(value: 30.12, unit: .inchesOfMercury))

  /// Runway 28R as the fixture airport publishes it. A shortened takeoff run also shortens the
  /// takeoff distance, as the tools treat an `available_takeoff_run_ft` override.
  static func runway28R(availableTakeoffRunFt: Double? = nil) -> RunwayInput {
    let takeoffRunFt = availableTakeoffRunFt ?? 10_000
    let takeoffDistanceFt = availableTakeoffRunFt ?? 10_500
    return RunwayInput(
      id: "28R", elevation: .init(value: 6, unit: .feet),
      trueHeading: .init(value: 295, unit: .degrees), gradient: 0.001,
      length: .init(value: max(takeoffDistanceFt, 9_000), unit: .feet),
      takeoffRun: .init(value: takeoffRunFt, unit: .feet),
      takeoffDistance: .init(value: takeoffDistanceFt, unit: .feet),
      landingDistance: .init(value: 9_000, unit: .feet), notam: nil,
      airportVariation: .init(value: 0, unit: .degrees))
  }

  /// A G2+ takeoff at 5,800 lb from 28R, and the ground run's correction multipliers.
  static func takeoff() throws -> (figures: [String: Double], runMultipliers: [Double]) {
    let report = try PerformanceCalculator(settings: .init(aircraft: .sf50(.g2Plus))).takeoff(
      conditions: reportedConditions, weight: .init(value: 5_800, unit: .pounds),
      runway: runway28R())
    let results = report.results
    return (
      [
        "takeoff_run_ft": try whole(results.takeoffRun.nominal, in: .feet),
        "takeoff_distance_ft": try whole(results.takeoffDistance.nominal, in: .feet),
        "takeoff_climb_gradient_ft_per_nm": try whole(
          results.takeoffClimbGradient.nominal, in: .feetPerNauticalMile)
      ],
      report.groundRunBreakdown.adjustments.map { ($0.multiplier * 1000).rounded() / 1000 }
    )
  }

  /// A dry G2+ flaps 100 landing on 28R.
  static func landing(weightLb: Double) throws -> [String: Double] {
    let results = try PerformanceCalculator(settings: .init(aircraft: .sf50(.g2Plus))).landing(
      conditions: reportedConditions,
      configuration: .init(weight: .init(value: weightLb, unit: .pounds), flapSetting: .flaps100),
      runway: runway28R()
    ).results
    return [
      "landing_run_ft": try whole(results.landingRun.nominal, in: .feet),
      "landing_distance_ft": try whole(results.landingDistance.nominal, in: .feet),
      "vref_kt": try whole(results.Vref.nominal, in: .knots)
    ]
  }

  /// A G2+ climb profile at 5,800 lb from the field, at the METAR's temperature and the lowest
  /// level's wind, through the fixture forecast's two pressure levels.
  static func forecastClimb() throws -> ClimbProfile {
    func feet(meters: Double) -> Double { meters / 0.304_8 }
    return try ClimbProfileGenerator.generate(
      windsAloft: [
        .init(altitudeFt: 6, temperatureC: 15, windDirectionDeg: 290, windSpeedKts: 20),
        .init(
          altitudeFt: feet(meters: 780), temperatureC: 12, windDirectionDeg: 290,
          windSpeedKts: 20),
        .init(
          altitudeFt: feet(meters: 3_100), temperatureC: -2, windDirectionDeg: 270,
          windSpeedKts: 30)
      ],
      weightLb: 5_800, aircraft: .sf50(.g2Plus), seaLevelPressureInHg: 30.12,
      useRegressionModel: false)
  }

  /// The G1 maximum takeoff weight from 5,000 lb up, and what binds it.
  static func maxTakeoffWeight(runway: RunwayInput) throws -> (
    limit: Double, constraint: BindingConstraint
  ) {
    let search = try PerformanceCalculator(settings: .init(aircraft: .sf50(.g1))).maxTakeoffWeight(
      conditions: reportedConditions, runway: runway,
      minimumWeight: .init(value: 5_000, unit: .pounds))
    return (try whole(search.limit, in: .pounds), search.bindingConstraint)
  }

  /// The G1 maximum takeoff temperature from 28R at a weight, and what binds it.
  static func maxTakeoffTemperature(weightLb: Double, availableTakeoffRunFt: Double) throws -> (
    limit: Double, constraint: BindingConstraint
  ) {
    let search = try PerformanceCalculator(settings: .init(aircraft: .sf50(.g1)))
      .maxTakeoffTemperature(
        conditions: reportedConditions, weight: .init(value: weightLb, unit: .pounds),
        runway: runway28R(availableTakeoffRunFt: availableTakeoffRunFt))
    return (try whole(search.limit, in: .celsius), search.bindingConstraint)
  }

  /// A figure in whole units, failing the test where the package gives none.
  private static func whole<UnitType: Dimension>(
    _ measurement: Measurement<UnitType>?, in unit: UnitType
  ) throws -> Double {
    try #require(measurement).converted(to: unit).value.rounded()
  }
}

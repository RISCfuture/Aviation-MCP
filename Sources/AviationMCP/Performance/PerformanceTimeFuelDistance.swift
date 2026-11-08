import AircraftPerformance
import Foundation
import MCP
import MeasurementKit

extension PerformanceTools {
  /// The time, fuel and distance outputs, with the capability each needs.
  static let timeFuelDistanceOutputs: [(output: String, capability: PerformanceCapability)] = [
    ("time_fuel_distance_to_climb", .timeFuelDistanceToClimb),
    ("time_fuel_distance_to_climb_lean_of_peak", .leanOfPeakClimb)
  ]

  private static let timeFuelDistanceNote =
    "The manual's table between the two pressure altitudes, without its additions for start, "
    + "taxi and takeoff fuel or for temperatures above standard; apply those from the manual."

  /// The time, fuel and distance to climb between two altitudes, rich and lean of peak, for
  /// each the aircraft's manual has figures for.
  static func timeFuelDistance(
    _ aircraft: PerformanceAircraft, fromFt: Double, toFt: Double, altimeterInHg: Double?,
    figures: inout FigureEncoder
  ) throws -> [String: MCP.Value] {
    let conditions = Conditions(
      seaLevelPressure: altimeterInHg.map { Measurement(value: $0, unit: .inchesOfMercury) })
    let (bottom, top) = (
      conditions.pressureAltitude(elevation: Measurement(value: fromFt, unit: .feet)),
      conditions.pressureAltitude(elevation: Measurement(value: toFt, unit: .feet))
    )
    let calculator = PerformanceCalculator(settings: aircraft.settings)
    var fields: [String: MCP.Value] = [:]
    for (name, capability) in timeFuelDistanceOutputs
    where aircraft.aircraft.capabilities.contains(capability) {
      let climb = try calculator.timeFuelDistanceToClimb(
        from: bottom, to: top, leanOfPeak: capability == .leanOfPeakClimb)
      fields[name] = .object([
        "time_min": figures.encode(climb.time, "\(name) time_min", in: .minutes),
        "fuel_gal": figures.encode(climb.fuel, "\(name) fuel_gal", in: .gallons),
        "distance_nm": figures.encode(climb.distance, "\(name) distance_nm", in: .nauticalMiles),
        "from_pressure_altitude_ft": .double(bottom.converted(to: .feet).value.rounded()),
        "to_pressure_altitude_ft": .double(top.converted(to: .feet).value.rounded()),
        "note": .string(timeFuelDistanceNote)
      ])
    }
    return fields
  }
}

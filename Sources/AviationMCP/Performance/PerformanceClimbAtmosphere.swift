import Foundation
import MCP
import MeasurementKit
import SF50Performance

/// The atmosphere a climb passes through: the forecast winds aloft where they are available, and
/// otherwise a calm column built on the surface temperature.
struct ClimbAtmosphere {
  private static let feetPerMeter = 3.280_84

  let observations: [ClimbProfileGenerator.WindsAloftObservation]
  let column: Sourced<String>
  let altimeterInHg: Sourced<Double>?
  /// The surface temperature the column is built on, where it is not the forecast's own.
  let surfaceTemperatureC: Sourced<Double>?
  var warnings: [String] = []

  var highestLevelFt: Double { observations.map(\.altitudeFt).max() ?? 0 }

  /// Whether the column carries no wind.
  var isCalm: Bool { column.value == "calm" }

  init(
    reported: ReportedWeather, overrides: WeatherOverrides, time: Date, fieldElevationFt: Double
  ) {
    func sourced(_ override: Double?, _ name: String) -> Sourced<Double>? {
      if let override { return Sourced(override, .override) }
      guard let field = reported.fields[name], let value = field.value.number else { return nil }
      return Sourced(value, field.origin, time: field.time)
    }
    let temperatureC = sourced(overrides.temperatureC, "temperature_c")
    altimeterInHg = sourced(overrides.altimeterInHg, "altimeter_inhg")
    if altimeterInHg == nil {
      warnings.append("No altimeter setting is available; true airspeeds assume 29.92 inHg.")
    }
    let forecast = (reported.fields["pressure_levels"]?.value.arrayValue ?? []).compactMap {
      Self.observation($0)
    }.sorted { $0.altitudeFt < $1.altitudeFt }
    let levelsTime = reported.fields["pressure_levels"]?.time
    if let entered = overrides.temperatureC, !forecast.isEmpty {
      observations = Self.shifted(forecast, surfaceTemperatureC: entered, fieldFt: fieldElevationFt)
      column = Sourced(
        "forecast", .openMeteo, time: levelsTime,
        note: "forecast winds, with temperature_c's deviation from the standard atmosphere "
          + "held aloft")
      surfaceTemperatureC = temperatureC
      return
    }
    if overrides.temperatureC == nil, !forecast.isEmpty {
      observations = forecast
      column = Sourced("forecast", .openMeteo, time: levelsTime)
      surfaceTemperatureC = nil
      return
    }
    let calm = Self.calmColumn(
      temperatureC: temperatureC, time: time, fieldElevationFt: fieldElevationFt)
    observations = calm.observations
    column = calm.column
    surfaceTemperatureC = temperatureC
    warnings.append(calm.warning)
  }

  private struct CalmColumn {
    let observations: [ClimbProfileGenerator.WindsAloftObservation]
    let column: Sourced<String>
    let warning: String
  }

  /// A calm column on the surface temperature, with the warning that no forecast covers the
  /// climb.
  private static func calmColumn(
    temperatureC: Sourced<Double>?, time: Date, fieldElevationFt: Double
  ) -> CalmColumn {
    // The generator holds a surface temperature's deviation from the standard atmosphere aloft
    // only for a temperature marked as entered, so any known temperature is passed as one.
    let conditions = Conditions(
      validTime: DateInterval(start: time, duration: 3600),
      source: temperatureC == nil ? .downloaded(.openMeteo) : .entered, windDirection: nil,
      windSpeed: nil,
      temperature: temperatureC.map { Measurement(value: $0.value, unit: .celsius) },
      dewpoint: nil, seaLevelPressure: nil)
    let observations = ClimbProfileGenerator.standardObservations(
      conditions: conditions, fieldElevation: Measurement(value: fieldElevationFt, unit: .feet))
    guard let temperatureC else {
      return CalmColumn(
        observations: observations,
        column: Sourced("calm", .isa, note: "calm, standard atmosphere above the field"),
        warning: "No winds-aloft forecast covers the climb; the column is calm and follows the "
          + "standard atmosphere above the field.")
    }
    let note =
      "calm, with the surface temperature's deviation from the standard atmosphere held aloft"
    return CalmColumn(
      observations: observations, column: Sourced("calm", temperatureC.origin, note: note),
      warning: "No winds-aloft forecast covers the climb; the column is " + note + ".")
  }

  /// The inputs the column resolved, as results echo them.
  func inputs(time: Date) throws -> [String: MCP.Value] {
    var inputs: [String: MCP.Value] = [
      "time": .string(time.ISO8601Format()), "winds_aloft": try .encoded(column)
    ]
    inputs["temperature_c"] = try surfaceTemperatureC.map(MCP.Value.encoded)
    inputs["altimeter_inhg"] = try altimeterInHg.map(MCP.Value.encoded)
    return inputs
  }

  /// The forecast levels with their temperatures replaced by the standard atmosphere shifted to
  /// the surface temperature, and a surface level carrying the lowest level's wind.
  private static func shifted(
    _ forecast: [ClimbProfileGenerator.WindsAloftObservation], surfaceTemperatureC: Double,
    fieldFt: Double
  ) -> [ClimbProfileGenerator.WindsAloftObservation] {
    let deviation = surfaceTemperatureC - isaTemperature(altitudeFt: fieldFt)
    var levels = forecast.map {
      ClimbProfileGenerator.WindsAloftObservation(
        altitudeFt: $0.altitudeFt,
        temperatureC: isaTemperature(altitudeFt: $0.altitudeFt) + deviation,
        windDirectionDeg: $0.windDirectionDeg, windSpeedKts: $0.windSpeedKts)
    }
    if let lowest = forecast.first, lowest.altitudeFt > fieldFt {
      levels.insert(
        .init(
          altitudeFt: fieldFt, temperatureC: surfaceTemperatureC,
          windDirectionDeg: lowest.windDirectionDeg, windSpeedKts: lowest.windSpeedKts), at: 0)
    }
    return levels
  }

  private static func observation(_ level: MCP.Value) -> ClimbProfileGenerator
    .WindsAloftObservation?
  {
    guard let fields = level.objectValue, let height = fields["geopotential_height_m"]?.number,
      let temperature = fields["temperature_c"]?.number,
      let direction = fields["wind_direction_true_deg"]?.number,
      let speed = fields["wind_speed_kt"]?.number
    else { return nil }
    return .init(
      altitudeFt: height * feetPerMeter, temperatureC: temperature, windDirectionDeg: direction,
      windSpeedKts: speed)
  }
}

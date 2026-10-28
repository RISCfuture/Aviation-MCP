import Foundation
import MCP

struct OpenMeteoForecast: Decodable, Sendable {
  let elevation: Double
  let hourly: [String: [Double?]]

  static let pressureLevels = [
    1000, 975, 950, 925, 900, 850, 800, 700, 600, 500, 400, 300, 250, 200
  ]
  static let surfaceVariables = [
    "temperature_c": "temperature_2m", "dewpoint_c": "dew_point_2m",
    "altimeter_hpa": "pressure_msl", "wind_speed_kt": "wind_speed_10m",
    "wind_direction_true_deg": "wind_direction_10m", "wind_gust_kt": "wind_gusts_10m"
  ]

  static func variables(for fields: [String]) -> [String] {
    var variables = fields.compactMap { surfaceVariables[$0] }
    if fields.contains("pressure_levels") {
      variables += pressureLevels.flatMap { level in
        [
          "temperature_\(level)hPa", "wind_speed_\(level)hPa", "wind_direction_\(level)hPa",
          "geopotential_height_\(level)hPa"
        ]
      }
    }
    return variables.sorted()
  }

  func sample(at instant: Date, retrievedAt: Date) throws -> WeatherSample {
    guard let times = hourly["time"],
      let index = times.lastIndex(where: { $0.map { $0 <= instant.timeIntervalSince1970 } == true }
      ),
      let seconds = times[index], instant.timeIntervalSince1970 - seconds < 3600
    else {
      throw WeatherFailure(
        provider: "open_meteo", reason: "The model forecast does not cover the requested hour.")
    }
    let start = Date(timeIntervalSince1970: seconds)
    func field(_ value: Value) -> WeatherField {
      WeatherField(
        value: value, provider: "open_meteo", product: "hourly_forecast", modeled: true,
        validFrom: start, validUntil: start.addingTimeInterval(3600), retrievedAt: retrievedAt)
    }
    var fields: [String: WeatherField] = [:]
    for (name, variable) in Self.surfaceVariables {
      if let value = value(variable, at: index) { fields[name] = field(.double(value)) }
    }
    fields["altimeter_hpa"]?.notes = [
      "Modeled mean sea-level pressure is an approximation to an altimeter setting."
    ]
    let levels = Self.pressureLevels.compactMap { level -> Value? in
      guard let height = value("geopotential_height_\(level)hPa", at: index), height > elevation,
        let temperature = value("temperature_\(level)hPa", at: index),
        let speed = value("wind_speed_\(level)hPa", at: index),
        let direction = value("wind_direction_\(level)hPa", at: index)
      else { return nil }
      return .object([
        "pressure_hpa": .int(level), "geopotential_height_m": .double(height),
        "temperature_c": .double(temperature), "wind_speed_kt": .double(speed),
        "wind_direction_true_deg": .double(direction)
      ])
    }
    if !levels.isEmpty { fields["pressure_levels"] = field(.array(levels)) }
    return WeatherSample(fields: fields)
  }

  private func value(_ name: String, at index: Int) -> Double? {
    guard let column = hourly[name], column.indices.contains(index), let value = column[index],
      value.isFinite
    else { return nil }
    return value
  }
}

import Foundation
import MCP
import SwiftMETAR

enum WeatherParsing {
  static func parse(_ arguments: ToolArguments) async throws -> ToolResult {
    guard let type = try arguments.string("type", required: true),
      let text = try arguments.string("report", required: true)
    else {
      throw MCPError.invalidParams("Report type and text are required")
    }
    let reference = try arguments.instant("reference_date", default: .now) ?? .now
    let value: Value
    switch type.lowercased() {
    case "metar":
      value = metar(try await METAR.from(string: text, on: reference, lenientRemarks: true))
    case "taf": value = taf(try await TAF.from(string: text, on: reference))
    case "winds_aloft": value = winds(try await WindsAloft.from(string: text, on: reference))
    default: throw MCPError.invalidParams("Supported report types: metar, taf, winds_aloft")
    }
    return ToolResult(
      results: [value],
      warnings: ["Parsed from client-supplied text; not retrieved from a live provider."])
  }

  static func fields(_ report: METAR) -> [String: Value] {
    var fields = ReportedConditions.values(
      wind: report.wind, visibility: report.visibility,
      conditions: report.conditions, altimeter: report.altimeter)
    if let temperature = report.temperature { fields["temperature_c"] = .int(Int(temperature)) }
    if let dewpoint = report.dewpoint { fields["dewpoint_c"] = .int(Int(dewpoint)) }
    return fields
  }

  static func metar(_ report: METAR) -> Value {
    .object([
      "type": "METAR", "station": .string(report.stationID),
      "observation_time": .string(report.date.ISO8601Format()), "fields": .object(fields(report)),
      "original_text": .string(report.text ?? ""),
      "weather_codes": .array((report.weather ?? []).map { .string($0.codedString) }),
      "runway_visibility": .array(report.runwayVisibility.map { .string($0.codedString) })
    ])
  }

  static func taf(_ report: TAF) -> Value {
    var result: [String: Value] = [
      "type": "TAF", "station": .string(report.airportID),
      "original_text": .string(report.text ?? ""), "groups": .array(report.groups.map(group))
    ]
    if let issued = report.originDate { result["issued_at"] = .string(issued.ISO8601Format()) }
    return .object(result)
  }

  private static func group(_ group: TAF.Group) -> Value {
    var result = period(group.period)
    result["fields"] = .object(
      ReportedConditions.values(
        wind: group.wind,
        visibility: group.visibility, conditions: group.conditions, altimeter: group.altimeter))
    result["weather_codes"] = .array((group.weather ?? []).map { .string($0.codedString) })
    result["icing_codes"] = .array(group.icing.map { .string($0.codedString) })
    result["turbulence_codes"] = .array(group.turbulence.map { .string($0.codedString) })
    return .object(result)
  }

  private static func period(_ period: TAF.Group.Period) -> [String: Value] {
    var value: [String: Value] = ["period_code": .string(period.codedString)]
    let interval: DateInterval?
    switch period {
    case .from(let start):
      value["type"] = "from"
      if let date = start.date { value["valid_from"] = .string(date.ISO8601Format()) }
      interval = nil
    case .range(let range):
      value["type"] = "prevailing"
      interval = range.dateInterval
    case .temporary(let range):
      value["type"] = "temporary"
      interval = range.dateInterval
    case .becoming(let range):
      value["type"] = "becoming"
      interval = range.dateInterval
    case .probability(let probability, let range):
      value["type"] = "probability"
      value["probability_percent"] = .int(Int(probability))
      interval = range.dateInterval
    }
    if let interval {
      value["valid_from"] = .string(interval.start.ISO8601Format())
      value["valid_until"] = .string(interval.end.ISO8601Format())
    }
    return value
  }

  private static func winds(_ report: WindsAloft) -> Value {
    .object([
      "type": "winds_aloft", "original_text": .string(report.text ?? ""),
      "valid_from": .string(report.usePeriod.dateInterval.start.ISO8601Format()),
      "valid_until": .string(report.usePeriod.dateInterval.end.ISO8601Format()),
      "stations": .array(
        report.stations.map { station in
          .object([
            "station": .string(station.id),
            "levels": .array(
              station.entries.map { entry in
                var value: [String: Value] = [
                  "altitude_ft": .int(Int(entry.altitude)),
                  "code": .string(entry.data.codedString)
                ]
                if let speed = entry.data.speedMeasurement {
                  value["wind_speed_kt"] = .double(speed.converted(to: .knots).value)
                }
                if let direction = entry.data.directionMeasurement {
                  value["wind_direction_true_deg"] = .double(direction.value)
                }
                if let temperature = entry.data.temperatureMeasurement {
                  value["temperature_c"] = .double(temperature.value)
                }
                return .object(value)
              })
          ])
        })
    ])
  }
}

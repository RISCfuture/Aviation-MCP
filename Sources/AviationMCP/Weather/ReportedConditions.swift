import Foundation
import MCP
import SwiftMETAR

enum ReportedConditions {
  static func values(
    wind: Wind?, visibility: Visibility?, conditions: [Condition], altimeter: Altimeter?
  ) -> [String: Value] {
    var fields = wind.map(Self.wind) ?? [:]
    if let visibility { fields["visibility"] = Self.visibility(visibility) }
    fields["cloud_layers"] = .array(
      conditions.map { condition in
        var layer: [String: Value] = ["code": .string(condition.codedString)]
        if let height = condition.heightMeasurement?.value {
          layer["base_agl_ft"] = .double(height)
        }
        return .object(layer)
      })
    if let altimeter {
      fields["altimeter_hpa"] = .double(altimeter.measurement.converted(to: .hectopascals).value)
    }
    return fields
  }

  static func wind(_ wind: Wind) -> [String: Value] {
    var fields: [String: Value] = ["wind_report": .string(wind.codedString)]
    switch wind {
    case .calm:
      fields["wind_speed_kt"] = 0
      fields["wind_calm"] = true
    case .variable(let speed, let range):
      fields["wind_speed_kt"] = .double(speed.measurement.converted(to: .knots).value)
      fields["wind_variable"] = true
      if let range {
        fields["wind_direction_range_true_deg"] = .array([.int(Int(range.0)), .int(Int(range.1))])
      }
    case .direction(let direction, let speed, let gust),
      .directionRange(let direction, _, let speed, let gust):
      fields["wind_direction_true_deg"] = .int(Int(direction))
      fields["wind_speed_kt"] = .double(speed.measurement.converted(to: .knots).value)
      if let gust { fields["wind_gust_kt"] = .double(gust.measurement.converted(to: .knots).value) }
      if case .directionRange(_, let range, _, _) = wind {
        fields["wind_direction_range_true_deg"] = .array([.int(Int(range.0)), .int(Int(range.1))])
      }
    }
    return fields
  }

  private static func visibility(_ visibility: Visibility) -> Value {
    switch visibility {
    case .equal(let value): return distance(value, relation: "equal")
    case .lessThan(let value): return distance(value, relation: "less_than")
    case .greaterThan(let value): return distance(value, relation: "greater_than")
    case .variable(let low, let high):
      return .object([
        "relation": "variable", "low": Self.visibility(low), "high": Self.visibility(high)
      ])
    case .notRecorded: return .object(["relation": "not_recorded"])
    }
  }

  private static func distance(_ value: Visibility.Value, relation: String) -> Value {
    .object([
      "relation": .string(relation),
      "meters": .double(value.measurement.converted(to: .meters).value)
    ])
  }
}

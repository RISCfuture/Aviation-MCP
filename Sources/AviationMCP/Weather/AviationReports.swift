import Foundation
import MCP
import SwiftMETAR

enum AviationReports {
  /// How long a METAR describes current conditions after its observation time.
  static let observationLifetime: TimeInterval = 3600

  static func sample(metar: METAR, at instant: Date, retrievedAt: Date) throws -> WeatherSample {
    let interval = DateInterval(start: metar.date, duration: observationLifetime)
    guard interval.start <= instant && instant < interval.end else {
      throw WeatherFailure(
        provider: "awc", reason: "The observation does not cover the requested time.")
    }
    return WeatherSample(
      fields: fields(
        WeatherParsing.fields(metar), product: "METAR",
        interval: interval, retrievedAt: retrievedAt, observedAt: metar.date),
      reports: [WeatherParsing.metar(metar)])
  }

  static func sample(taf: TAF, at instant: Date, retrievedAt: Date) throws -> WeatherSample {
    guard let first = taf.groups.first, case .range(let validity) = first.period,
      validity.dateInterval.start <= instant, instant < validity.dateInterval.end,
      let group = taf.during(instant)
    else {
      throw WeatherFailure(
        provider: "awc", reason: "The terminal forecast does not cover the requested time.")
    }
    let transitions = taf.groups.flatMap { boundaries($0.period) }.sorted()
    let start = transitions.last { $0 <= instant } ?? validity.dateInterval.start
    let end = transitions.first { $0 > instant } ?? validity.dateInterval.end
    return WeatherSample(
      fields: fields(
        ReportedConditions.values(
          wind: group.wind,
          visibility: group.visibility, conditions: group.conditions, altimeter: group.altimeter),
        product: "TAF", interval: .init(start: start, end: end), retrievedAt: retrievedAt,
        observedAt: taf.originDate),
      reports: [WeatherParsing.taf(taf)],
      warnings: [
        "TAF summary combines applicable change, temporary and probability groups; "
          + "consult the preserved groups for conditional forecasts."
      ])
  }

  private static func fields(
    _ values: [String: Value], product: String, interval: DateInterval,
    retrievedAt: Date, observedAt: Date?
  ) -> [String: WeatherField] {
    var values = values
    if values["wind_variable"] == true || values["wind_calm"] == true {
      values["wind_direction_true_deg"] = .null
    }
    let reportsNoGust = values["wind_report"] != nil && values["wind_gust_kt"] == nil
    if reportsNoGust { values["wind_gust_kt"] = .null }
    var fields = values.mapValues { value in
      WeatherField(
        value: value, provider: "awc", product: product, modeled: false,
        validFrom: interval.start, validUntil: interval.end, retrievedAt: retrievedAt,
        observationTime: product == "METAR" ? observedAt : nil,
        issueTime: product == "TAF" ? observedAt : nil)
    }
    if reportsNoGust {
      fields["wind_gust_kt"]?.notes = ["The \(product) wind group reports no gusts."]
    }
    return fields
  }

  private static func boundaries(_ period: TAF.Group.Period) -> [Date] {
    switch period {
    case .from(let date): return [date.date].compactMap { $0 }
    case .range(let range), .temporary(let range), .becoming(let range), .probability(_, let range):
      return [range.dateInterval.start, range.dateInterval.end]
    }
  }
}

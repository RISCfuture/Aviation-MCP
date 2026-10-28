import Foundation
import MCP

struct WeatherQuery: Sendable {
  var station: String?
  var latitude: Double?
  var longitude: Double?
  let instant: Date
  var fields: [String]
  var sources: [String]?

  static let supportedFields = [
    "temperature_c", "dewpoint_c", "altimeter_hpa", "wind_speed_kt",
    "wind_direction_true_deg", "wind_gust_kt", "visibility", "cloud_layers", "pressure_levels"
  ]

  init(
    station: String?, latitude: Double?, longitude: Double?, instant: Date,
    fields: [String], sources: [String]?
  ) {
    self.station = station
    self.latitude = latitude
    self.longitude = longitude
    self.instant = instant
    self.fields = fields
    self.sources = sources
  }

  init(arguments: ToolArguments) throws {
    station = try arguments.string("station")?.uppercased()
    let coordinate = try arguments.coordinate()
    latitude = coordinate?.latitude
    longitude = coordinate?.longitude
    instant = try arguments.instant("time", default: .now) ?? .now
    fields = try arguments.strings("fields") ?? Self.supportedFields
    sources = try arguments.strings("sources")
    guard !fields.isEmpty, Set(fields).isSubset(of: Set(Self.supportedFields)) else {
      throw MCPError.invalidParams("Unsupported weather fields")
    }
    if let station {
      guard (3...4).contains(station.count),
        station.allSatisfy({ $0.isASCII && $0.isLetter || $0.isNumber })
      else {
        throw MCPError.invalidParams("Invalid station identifier")
      }
    }
    guard station != nil || coordinate != nil else {
      throw MCPError.invalidParams("A station or coordinate is required")
    }
  }
}

struct WeatherField: Codable, Sendable {
  let value: Value
  let provider: String
  let product: String
  let modeled: Bool
  let validFrom: Date
  let validUntil: Date
  let retrievedAt: Date
  var observationTime: Date?
  var issueTime: Date?
  var notes: [String] = []

  func covers(_ instant: Date) -> Bool { validFrom <= instant && instant < validUntil }
}

struct WeatherSample: Sendable {
  var fields: [String: WeatherField]
  var reports: [Value] = []
  var warnings: [String] = []
  var rateLimit: BudgetReport?
  var sources: [SourceStamp] = []
}

struct WeatherService: Sendable {
  typealias Provider = @Sendable (WeatherQuery) async throws -> WeatherSample
  let awc: Provider?
  let openMeteo: Provider?

  func weather(_ query: WeatherQuery) async throws -> ToolResult {
    let available = [awc == nil ? nil : "awc", openMeteo == nil ? nil : "open_meteo"].compactMap {
      $0
    }
    let selected = query.sources ?? available
    guard !selected.isEmpty, Set(selected).isSubset(of: Set(available)) else {
      throw MCPError.invalidParams("A requested weather source is unknown or disabled")
    }
    var result = WeatherAggregation()
    for provider in ["awc", "open_meteo"] where selected.contains(provider) {
      guard query.fields.contains(where: { result.fields[$0] == nil }) else { break }
      guard let fetch = provider == "awc" ? awc : openMeteo else { continue }
      do {
        var missing = query
        missing.fields = query.fields.filter { result.fields[$0] == nil }
        result.merge(try await fetch(missing), for: query)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        result.record(error, provider: provider)
      }
    }
    return try result.response(for: query, selected: selected)
  }
}

private struct WeatherAggregation {
  var fields: [String: WeatherField] = [:]
  var reports: [Value] = []
  var warnings: [String] = []
  var budgets: [BudgetReport] = []
  var failures: [WeatherFailure] = []
  var sources: [SourceStamp] = []

  mutating func merge(_ sample: WeatherSample, for query: WeatherQuery) {
    for (name, field) in sample.fields
    where query.fields.contains(name)
      && fields[name] == nil && field.covers(query.instant)
    {
      fields[name] = field
    }
    reports += sample.reports
    warnings += sample.warnings
    sources += sample.sources
    if let budget = sample.rateLimit { budgets.append(budget) }
  }

  mutating func record(_ error: any Error, provider: String) {
    let failure =
      error as? WeatherFailure
      ?? WeatherFailure(provider: provider, reason: "Provider request failed.")
    failures.append(failure)
    warnings.append("\(provider): \(failure.reason)")
    if let budget = failure.rateLimits { budgets.append(budget) }
  }

  mutating func response(for query: WeatherQuery, selected: [String]) throws -> ToolResult {
    guard !fields.isEmpty else {
      return ToolResult(
        results: [], sources: sources, completeness: "unavailable",
        warnings: warnings, rateLimits: try .encoded(budgets),
        error: .object([
          "code": "weather_unavailable",
          "reason": "No report or forecast covers the requested location and time.",
          "sources": try .encoded(selected), "providers": try .encoded(failures)
        ]))
    }
    let missing = query.fields.filter { fields[$0] == nil }
    if !missing.isEmpty {
      warnings.append("Unavailable fields: \(missing.joined(separator: ", ")).")
    }
    var value: [String: Value] = [
      "time": .string(query.instant.ISO8601Format()),
      "fields": try .encoded(fields), "reports": .array(reports)
    ]
    if fields.values.contains(where: \.modeled) {
      value["attribution"] = .string(
        "Weather data by Open-Meteo (https://open-meteo.com/), CC BY 4.0; "
          + "normalized and combined with aviation reports.")
    }
    return ToolResult(
      results: [.object(value)],
      sources: sources,
      completeness: missing.isEmpty && failures.isEmpty ? "complete" : "partial",
      warnings: warnings, rateLimits: try .encoded(budgets))
  }
}

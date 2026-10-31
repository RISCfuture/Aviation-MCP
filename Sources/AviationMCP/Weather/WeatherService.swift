import Foundation
import MCP

struct WeatherQuery: Sendable {
  var station: String?
  var latitude: Double?
  var longitude: Double?
  let instant: Date
  var fields: [String]
  var sources: [String]?
  /// The ICAO identifier NASR publishes for `station`.
  var reportingStation: String?
  /// The NASR cycle that located `station`.
  var locationSource: SourceStamp?
  /// Why `station` could not be located, when it could not.
  var locationProblem: String?

  static let supportedFields = [
    "temperature_c", "dewpoint_c", "altimeter_inhg", "altimeter_hpa", "wind_speed_kt",
    "wind_direction_true_deg", "wind_gust_kt", "visibility", "cloud_layers", "pressure_levels"
  ]

  /// The identifier to request from AWC by name: the ICAO identifier NASR publishes, or a
  /// four-character identifier NASR could not look up.
  var directStation: String? {
    reportingStation ?? (locationSource == nil && station?.count == 4 ? station : nil)
  }

  /// True when the requested time falls within the lifetime of a recent observation.
  var isRecent: Bool {
    instant <= .now && instant.timeIntervalSinceNow > -AviationReports.observationLifetime
  }

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

  func unlocated(_ problem: String) -> Self {
    var query = self
    query.locationProblem = problem
    return query
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
  var parsingGaps: [Value] = []
  /// The station whose report supplies the fields.
  var reportingStation: Value?
  /// The position a model forecast describes.
  var modelGridPoint: Value?
}

struct WeatherService: Sendable {
  typealias Provider = @Sendable (WeatherQuery) async throws -> WeatherSample
  typealias Locator = @Sendable (WeatherQuery) async throws -> WeatherQuery
  let awc: Provider?
  let openMeteo: Provider?
  var locate: Locator?

  func weather(_ query: WeatherQuery) async throws -> ToolResult {
    let available = [awc == nil ? nil : "awc", openMeteo == nil ? nil : "open_meteo"].compactMap {
      $0
    }
    let selected = query.sources ?? available
    guard !selected.isEmpty, Set(selected).isSubset(of: Set(available)) else {
      throw MCPError.invalidParams("A requested weather source is unknown or disabled")
    }
    let query = try await located(query)
    var result = WeatherAggregation()
    result.sources += query.locationSource.map { [$0] } ?? []
    for provider in ["awc", "open_meteo"] where selected.contains(provider) {
      let missing = query.fields.filter { !result.covers($0) }
      guard !missing.isEmpty else { break }
      guard let fetch = provider == "awc" ? awc : openMeteo else { continue }
      do {
        var request = query
        request.fields = missing
        result.merge(try await fetch(request), for: query)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        result.record(error, provider: provider)
      }
    }
    return try result.response(for: query, selected: selected)
  }

  private func located(_ query: WeatherQuery) async throws -> WeatherQuery {
    guard let locate, query.station != nil else { return query }
    do {
      return try await locate(query)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return query.unlocated("The station could not be looked up in NASR; supply coordinates.")
    }
  }
}

private struct WeatherAggregation {
  var fields: [String: WeatherField] = [:]
  var modeled: [String: WeatherField] = [:]
  var reports: [Value] = []
  var warnings: [String] = []
  var budgets: [BudgetReport] = []
  var failures: [WeatherFailure] = []
  var sources: [SourceStamp] = []
  var parsingGaps: [Value] = []
  var reportingStation: Value?
  var modelGridPoint: Value?

  func covers(_ name: String) -> Bool { fields[name] != nil || modeled[name] != nil }

  mutating func merge(_ sample: WeatherSample, for query: WeatherQuery) {
    for (name, field) in sample.fields
    where query.fields.contains(name) && !covers(name) && field.covers(query.instant) {
      if field.modeled { modeled[name] = field } else { fields[name] = field }
    }
    reports += sample.reports
    warnings += sample.warnings
    sources += sample.sources
    parsingGaps += sample.parsingGaps
    reportingStation = reportingStation ?? sample.reportingStation
    modelGridPoint = modelGridPoint ?? sample.modelGridPoint
    if let budget = sample.rateLimit { budgets.append(budget) }
  }

  mutating func record(_ error: any Error, provider: String) {
    let failure =
      error as? WeatherFailure
      ?? WeatherFailure(provider: provider, reason: "Provider request failed.")
    failures.append(failure)
    parsingGaps += failure.parsingGaps ?? []
    warnings.append("\(provider): \(failure.reason)")
    if let budget = failure.rateLimits { budgets.append(budget) }
  }

  mutating func response(for query: WeatherQuery, selected: [String]) throws -> ToolResult {
    guard !fields.isEmpty || !modeled.isEmpty else {
      return ToolResult(
        results: [], sources: sources, completeness: "unavailable",
        warnings: warnings, rateLimits: try .encoded(budgets),
        error: .object([
          "code": "weather_unavailable",
          "reason": "No report or forecast covers the requested location and time.",
          "sources": try .encoded(selected), "providers": try .encoded(failures)
        ]))
    }
    if !parsingGaps.isEmpty {
      warnings.append(
        "Some aviation reports could not be parsed. See parsing_gaps for affected products and stations."
      )
    }
    let missing = query.fields.filter { !covers($0) }
    if !missing.isEmpty {
      warnings.append("Unavailable fields: \(missing.joined(separator: ", ")).")
    }
    if fields.isEmpty {
      warnings.append(
        "No aviation observation or terminal forecast is available; every value is a modeled "
          + "estimate in model_supplement.")
    }
    var value: [String: Value] = [
      "time": .string(query.instant.ISO8601Format()),
      "fields": try .encoded(fields), "reports": .array(reports),
      "parsing_gaps": .array(parsingGaps)
    ]
    value["reporting_station"] = reportingStation
    if !modeled.isEmpty { value["model_supplement"] = try modelSupplement() }
    return ToolResult(
      results: [.object(value)],
      sources: sources,
      completeness: missing.isEmpty && failures.isEmpty && parsingGaps.isEmpty
        ? "complete" : "partial",
      warnings: warnings, rateLimits: try .encoded(budgets))
  }

  private func modelSupplement() throws -> Value {
    var supplement: [String: Value] = [
      "fields": try .encoded(modeled),
      "notice": .string(
        "Modeled estimates for fields no aviation report covers. They are not observations or "
          + "terminal forecasts and must not be presented as reported conditions."),
      "attribution": .string(
        "Weather data by Open-Meteo (https://open-meteo.com/), CC BY 4.0; normalized by "
          + "aviation-mcp.org.")
    ]
    supplement["grid_point"] = modelGridPoint
    return .object(supplement)
  }
}

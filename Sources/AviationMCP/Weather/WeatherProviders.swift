import Foundation
import MCP
import SwiftMETAR

struct WeatherProviders: Sendable {
  let http: WeatherHTTP
  var openMeteoEndpoint = "https://api.open-meteo.com/v1/forecast"
  var openMeteoKey: String?
  var openMeteoLimits = BudgetLimit.openMeteo
  var awcLimits = [BudgetLimit(period: .minute, units: 60)]

  func openMeteo(_ query: WeatherQuery) async throws -> WeatherSample {
    try await withBudget(provider: "open_meteo", limits: openMeteoLimits) {
      try await openMeteoSample(query)
    }
  }

  func awc(_ query: WeatherQuery) async throws -> WeatherSample {
    try await withBudget(provider: "awc", limits: awcLimits) {
      try await aviationSample(query)
    }
  }

  private func withBudget(
    provider: String, limits: [BudgetLimit],
    fetch: () async throws -> WeatherSample
  ) async throws -> WeatherSample {
    do {
      var sample = try await fetch()
      sample.rateLimit = try await http.budgets.reserve(
        provider: provider, units: 0, limits: limits)
      return sample
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      var failure =
        error as? WeatherFailure
        ?? WeatherFailure(
          provider: provider, reason: "Upstream report or forecast could not be interpreted.")
      if failure.rateLimits == nil {
        failure.rateLimits = try? await http.budgets.reserve(
          provider: provider, units: 0, limits: limits)
      }
      throw failure
    }
  }

  private func openMeteoSample(_ query: WeatherQuery) async throws -> WeatherSample {
    guard let latitude = query.latitude, let longitude = query.longitude else {
      throw WeatherFailure(
        provider: "open_meteo", reason: "Coordinates are unavailable for this station.")
    }
    let variables = OpenMeteoForecast.variables(for: query.fields)
    guard !variables.isEmpty else { return WeatherSample(fields: [:]) }
    let hoursAhead = query.instant.timeIntervalSinceNow / 3600
    guard (-24...383).contains(hoursAhead) else {
      throw WeatherFailure(
        provider: "open_meteo",
        reason: "The requested time is outside the supported forecast window.")
    }
    let days = max(1, min(16, Int(ceil(max(0, hoursAhead) / 24)) + 1))
    var parameters = [
      "latitude": String(latitude), "longitude": String(longitude),
      "hourly": variables.joined(separator: ","), "wind_speed_unit": "kn",
      "temperature_unit": "celsius",
      "timeformat": "unixtime", "timezone": "GMT", "forecast_days": String(days), "past_days": "1"
    ]
    if let key = openMeteoKey { parameters["apikey"] = key }
    let url = try Self.url(openMeteoEndpoint, parameters: parameters)
    let cached = try await http.get(
      provider: "open_meteo", url: url,
      units: WeatherRequestCost.units(
        variables: variables.count, locations: 1, models: 1, hours: (days + 1) * 24),
      limits: openMeteoLimits)
    let forecast = try JSONDecoder().decode(
      OpenMeteoForecast.self, from: JSONEncoder().encode(cached.payload))
    return try forecast.sample(at: query.instant, retrievedAt: cached.retrievedAt)
  }

  private func aviationSample(_ query: WeatherQuery) async throws -> WeatherSample {
    guard let station = query.station else {
      throw WeatherFailure(
        provider: "awc",
        reason: "No reporting station was specified or resolved for these coordinates.")
    }
    var diagnostics = ImportDiagnostics()
    if query.instant <= .now, query.instant.timeIntervalSinceNow > -3600,
      var sample = try await observation(
        station: station, at: query.instant, diagnostics: &diagnostics)
    {
      sample.parsingGaps = parsingGaps(diagnostics)
      return sample
    }
    let cached = try await fetchAWC("taf", station: station)
    var selected: WeatherSample?
    for value in cached.payload.arrayValue ?? [] {
      do {
        guard let text = value.objectValue?["rawTAF"]?.stringValue else {
          throw WeatherFailure(provider: "awc", reason: "TAF entry is missing rawTAF.")
        }
        let taf = try await TAF.from(string: text, on: cached.retrievedAt)
        guard let first = taf.groups.first, case .range(let validity) = first.period else {
          throw WeatherFailure(
            provider: "awc", reason: "TAF has no usable forecast validity period.")
        }
        guard validity.dateInterval.start <= query.instant,
          query.instant < validity.dateInterval.end
        else { continue }
        let sample = try AviationReports.sample(
          taf: taf, at: query.instant, retrievedAt: cached.retrievedAt)
        if selected == nil { selected = sample }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        diagnostics.record(error, kind: "TAF", recordID: station)
      }
    }
    if var selected {
      selected.parsingGaps = parsingGaps(diagnostics)
      return selected
    }
    throw WeatherFailure(
      provider: "awc",
      reason: "No usable aviation report or forecast covers the requested station and time.",
      parsingGaps: parsingGaps(diagnostics))
  }

  private func observation(
    station: String, at instant: Date, diagnostics: inout ImportDiagnostics
  ) async throws -> WeatherSample? {
    let cached = try await fetchAWC("metar", station: station)
    var selected: (date: Date, sample: WeatherSample)?
    for value in cached.payload.arrayValue ?? [] {
      do {
        guard let text = value.objectValue?["rawOb"]?.stringValue else {
          throw WeatherFailure(provider: "awc", reason: "METAR entry is missing rawOb.")
        }
        let report = try await METAR.from(
          string: text, on: cached.retrievedAt, lenientRemarks: true)
        guard report.date <= instant, instant < report.date.addingTimeInterval(3600) else {
          continue
        }
        let sample = try AviationReports.sample(
          metar: report, at: instant, retrievedAt: cached.retrievedAt)
        if selected == nil || report.date > (selected?.date ?? .distantPast) {
          selected = (report.date, sample)
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        diagnostics.record(error, kind: "METAR", recordID: station)
      }
    }
    return selected?.sample
  }

  private func parsingGaps(_ diagnostics: ImportDiagnostics) -> [Value] {
    guard diagnostics.count > 0 else { return [] }
    return [
      .object(["provider": "awc", "parse_errors": diagnostics.validation["parse_errors"] ?? .null])
    ]
  }

  private func fetchAWC(_ product: String, station: String) async throws -> CachedWeather {
    let url = try Self.url(
      "https://aviationweather.gov/api/data/\(product)",
      parameters: ["ids": station, "format": "json"])
    return try await http.get(provider: "awc", url: url, units: 1, limits: awcLimits)
  }

  private static func url(_ base: String, parameters: [String: String]) throws -> String {
    guard var components = URLComponents(string: base), components.scheme == "https",
      components.host != nil
    else {
      throw WeatherFailure(
        provider: "configuration", reason: "Weather endpoints must be HTTPS URLs.")
    }
    components.queryItems = parameters.sorted { $0.key < $1.key }.map {
      URLQueryItem(name: $0.key, value: $0.value)
    }
    guard let url = components.url else {
      throw WeatherFailure(provider: "configuration", reason: "Invalid weather endpoint.")
    }
    return url.absoluteString
  }
}

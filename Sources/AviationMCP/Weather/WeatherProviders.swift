import Foundation
import MCP

struct WeatherProviders: Sendable {
  /// Model positions snap to a grid of this many cells per degree, so nearby requests share one
  /// cached forecast.
  private static let modelCellsPerDegree = 20.0
  /// Forecast lengths requested from Open-Meteo, so requests for different hours share one cached
  /// forecast. With one past day, up to 13 forecast days cost a single API call per ten variables.
  private static let forecastDayOptions = [3, 13, 16]

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
      try await AviationWeatherCenter(http: http, limits: awcLimits).sample(query)
    }
  }

  static func url(_ base: String, parameters: [String: String]) throws -> String {
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

  private static func modelCoordinate(_ degrees: Double) -> Double {
    (degrees * modelCellsPerDegree).rounded() / modelCellsPerDegree
  }

  private static func forecastDays(reaching hoursAhead: Double) -> Int {
    let needed = Int(ceil(max(0, hoursAhead) / 24)) + 1
    return forecastDayOptions.first { $0 >= needed } ?? forecastDayOptions.last ?? needed
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
        provider: "open_meteo",
        reason: query.locationProblem ?? "Coordinates are unavailable for this station.")
    }
    let variables = OpenMeteoForecast.variables(for: query.fields)
    guard !variables.isEmpty else { return WeatherSample(fields: [:]) }
    let hoursAhead = query.instant.timeIntervalSinceNow / 3600
    guard (-24...383).contains(hoursAhead) else {
      throw WeatherFailure(
        provider: "open_meteo",
        reason: "The requested time is outside the supported forecast window.")
    }
    let days = Self.forecastDays(reaching: hoursAhead)
    let gridLatitude = Self.modelCoordinate(latitude)
    let gridLongitude = Self.modelCoordinate(longitude)
    var parameters = [
      "latitude": String(gridLatitude), "longitude": String(gridLongitude),
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
    var sample = try forecast.sample(at: query.instant, retrievedAt: cached.retrievedAt)
    sample.modelGridPoint = .object([
      "latitude": .double(gridLatitude), "longitude": .double(gridLongitude)
    ])
    return sample
  }
}

import Foundation
import MCP
import SwiftMETAR
import Testing

@testable import AviationMCP

@Suite
struct `Weather selection and provenance` {
  @Test
  func `prefers aviation fields and fills missing fields from the model`() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let query = WeatherQuery(
      station: "KOAK", latitude: 37.7, longitude: -122.2,
      instant: now, fields: ["temperature_c", "wind_speed_kt"], sources: nil)
    let service = WeatherService(
      awc: { _ in Self.sample(provider: "awc", instant: now, values: ["temperature_c": 18]) },
      openMeteo: { request in
        #expect(request.fields == ["wind_speed_kt"])
        return Self.sample(
          provider: "open_meteo", instant: now,
          values: ["temperature_c": 20, "wind_speed_kt": 12])
      })
    let result = try await service.weather(query)
    let fields = try #require(result.results.first?.objectValue?["fields"]?.objectValue)
    #expect(fields["temperature_c"]?.objectValue?["value"] == 18)
    #expect(fields["temperature_c"]?.objectValue?["provider"] == "awc")
    #expect(fields["wind_speed_kt"]?.objectValue?["modeled"] == true)
    let disabled = WeatherService(awc: service.awc, openMeteo: nil)
    var selected = query
    selected.sources = ["open_meteo"]
    let request = selected
    await #expect(throws: MCPError.self) { try await disabled.weather(request) }

    let retry = now.addingTimeInterval(60)
    let budget = BudgetReport(
      provider: "open_meteo", allowed: false, requestedUnits: 1,
      limits: [.init(period: .minute, limit: 600, remaining: 0, resetsAt: retry.ISO8601Format())],
      retryAt: retry.ISO8601Format(), retrySource: "upstream")
    let unavailable = WeatherService(
      awc: { _ in throw WeatherFailure(provider: "awc", reason: "No reporting station.") },
      openMeteo: { _ in
        throw WeatherFailure(
          provider: "open_meteo", reason: "Provider throttled.", retryAt: retry,
          retrySource: "upstream", rateLimits: budget)
      })
    let failure = try await unavailable.weather(query)
    #expect(failure.completeness == "unavailable")
    #expect(failure.results.isEmpty)
    let errors = try #require(failure.error?.objectValue?["providers"]?.arrayValue)
    #expect(errors.compactMap { $0.objectValue?["provider"]?.stringValue } == ["awc", "open_meteo"])
    #expect(errors.last?.objectValue?["retrySource"] == "upstream")
    #expect(errors.last?.objectValue?["retryAt"] != nil)
    #expect(
      failure.rateLimits?.arrayValue?.first?.objectValue?["retryAt"]
        == .string(retry.ISO8601Format()))
    #expect(try failure.response().isError == true)
  }

  @Test
  func `rejects uncovered model hours and excludes levels below terrain`() throws {
    let data = Data(
      """
      {"elevation":1000,"hourly":{"time":[1700000000],"temperature_2m":[18],
      "wind_speed_10m":[9],"geopotential_height_1000hPa":[100],
      "temperature_1000hPa":[22],"wind_speed_1000hPa":[15],"wind_direction_1000hPa":[280],
      "geopotential_height_850hPa":[1600],"temperature_850hPa":[10],
      "wind_speed_850hPa":[25],"wind_direction_850hPa":[270]}}
      """.utf8)
    let response = try JSONDecoder().decode(OpenMeteoForecast.self, from: data)
    let sample = try response.sample(
      at: Date(timeIntervalSince1970: 1_700_000_050), retrievedAt: .now)
    let levels = try #require(sample.fields["pressure_levels"]?.value.arrayValue)
    #expect(levels.count == 1)
    #expect(levels.first?.objectValue?["pressure_hpa"] == 850)
    #expect(throws: WeatherFailure.self) {
      try response.sample(at: Date(timeIntervalSince1970: 1_700_003_600), retrievedAt: .now)
    }
  }

  @Test
  func `normalizes supplied reports without inventing variable wind headings`() async throws {
    let result = try await WeatherParsing.parse(
      ToolArguments([
        "type": "metar", "reference_date": "2026-10-28T12:00:00Z",
        "report": "KOAK 281153Z VRB03KT 10SM BKN020 18/12 A2992"
      ]))
    let report = try #require(result.results.first?.objectValue)
    let fields = try #require(report["fields"]?.objectValue)
    #expect(fields["wind_direction_true_deg"] == nil)
    #expect(fields["wind_speed_kt"]?.doubleValue == 3)
    #expect(fields["wind_variable"] == true)
    #expect(fields["temperature_c"] == 18)
    #expect(report["observation_time"] == "2026-10-28T11:53:00Z")
  }

  @Test
  func `bounds combined TAF fields at the next transition`() async throws {
    let reference = Date(timeIntervalSince1970: 1_793_188_800)
    let taf = try await TAF.from(
      string:
        "TAF KOAK 281130Z 2812/2918 28010KT P6SM SCT020 FM281500 30015KT P6SM BKN025 TEMPO 2816/2818 3SM BR",
      on: reference)
    let instant = try #require(ISO8601DateFormatter().date(from: "2026-10-28T17:00:00Z"))
    let sample = try AviationReports.sample(taf: taf, at: instant, retrievedAt: reference)
    #expect(sample.fields["wind_speed_kt"]?.validUntil.ISO8601Format() == "2026-10-28T18:00:00Z")
    #expect(sample.fields["wind_speed_kt"]?.value.doubleValue == 15)
    #expect(!sample.warnings.isEmpty)
    #expect(throws: WeatherFailure.self) {
      try AviationReports.sample(
        taf: taf, at: instant.addingTimeInterval(48 * 3600), retrievedAt: reference)
    }
  }

  private static func sample(provider: String, instant: Date, values: [String: Value])
    -> WeatherSample
  {
    WeatherSample(
      fields: values.mapValues {
        WeatherField(
          value: $0, provider: provider, product: provider == "awc" ? "METAR" : "forecast",
          modeled: provider == "open_meteo", validFrom: instant,
          validUntil: instant.addingTimeInterval(3600), retrievedAt: instant)
      })
  }
}

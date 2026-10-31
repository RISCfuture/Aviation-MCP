import Foundation
import MCP
import Testing
import Vapor

@testable import AviationMCP

extension `Transactional publication` {
  @Test
  func `selects valid reports for current and future requests while reporting rejected neighbors`()
    async throws
  {
    try await withDatabase { store in
      let now = Date.now
      let reports = Self.nearTermReports(at: now)
      let providers = WeatherProviders(
        http: WeatherHTTP(
          cache: WeatherCache(database: store.database),
          budgets: ProviderBudgets(database: store.database)
        ) { request in
          let report = request.url.path.hasSuffix("metar") ? reports.metar : reports.taf
          let data = try JSONEncoder().encode(report)
          let json = try #require(String(data: data, encoding: .utf8))
          return ClientResponse(status: .ok, body: ByteBuffer(string: json))
        })
      let service = WeatherService(awc: providers.awc, openMeteo: nil)
      for future in [false, true] {
        let result = try await service.weather(
          WeatherQuery(
            station: "KOAK", latitude: nil, longitude: nil,
            instant: future ? now.addingTimeInterval(1800) : now,
            fields: ["wind_speed_kt"], sources: ["awc"]))
        let weather = try #require(result.results.first?.objectValue)
        let wind = try #require(weather["fields"]?.objectValue?["wind_speed_kt"]?.objectValue)
        #expect(wind["product"] == .string(future ? "TAF" : "METAR"))
        #expect(wind["value"]?.intValue == (future ? 10 : 15))
        #expect(result.completeness == "partial")
        let gap = try #require(weather["parsing_gaps"]?.arrayValue?.first?.objectValue)
        #expect(gap["parse_errors"]?.objectValue?["count"] == 1)
      }
    }
  }

  @Test
  func `limits each client's upstream share without caching its refusal for others`()
    async throws
  {
    try await withDatabase { store in
      let http = WeatherHTTP(
        cache: WeatherCache(database: store.database),
        budgets: ProviderBudgets(database: store.database),
        allowance: ClientAllowance(fraction: 0.5)
      ) { _ in ClientResponse(status: .ok, body: ByteBuffer(string: "[]")) }
      let limits = [BudgetLimit(period: .day, units: 2)]
      try await WeatherClient.$key.withValue("first") {
        _ = try await http.get(
          provider: "awc", url: "https://example.invalid/a", units: 1, limits: limits)
        let refusal = await #expect(throws: WeatherFailure.self) {
          try await http.get(
            provider: "awc", url: "https://example.invalid/b", units: 1, limits: limits)
        }
        #expect(refusal?.clientSpecific == true)
      }
      try await WeatherClient.$key.withValue("second") {
        let fetched = try await http.get(
          provider: "awc", url: "https://example.invalid/b", units: 1, limits: limits)
        #expect(!fetched.cacheHit)
      }
    }
  }

  @Test
  func `reserves weighted budgets atomically across concurrent callers`() async throws {
    try await withDatabase { store in
      let budgets = ProviderBudgets(database: store.database)
      let limits = [BudgetLimit(period: .day, units: 3)]
      let outcomes = try await withThrowingTaskGroup(of: BudgetReport.self) { group in
        for _ in 0..<8 {
          group.addTask {
            try await budgets.reserve(provider: "fixture", units: 1.5, limits: limits)
          }
        }
        var reports: [BudgetReport] = []
        for try await report in group { reports.append(report) }
        return reports
      }
      #expect(outcomes.filter(\.allowed).count == 2)
      #expect(outcomes.filter { !$0.allowed }.allSatisfy { $0.retryAt != nil })
      let denied = try #require(outcomes.first { !$0.allowed })
      #expect(denied.limits.first?.remaining == 0)
      #expect(denied.tracking == "local_estimate")
      let metrics = try await DatabaseMetrics(database: store.database).render()
      #expect(
        metrics.contains(
          "aviation_provider_consumed_units{provider=\"fixture\",period=\"day\"} 3.0"))
      try await budgets.coolDown(
        provider: "throttled", until: .now.addingTimeInterval(60), source: "upstream")
      let throttled = try await budgets.reserve(provider: "throttled", units: 1, limits: limits)
      #expect(!throttled.allowed)
      #expect(throttled.retrySource == "upstream")
      #expect(throttled.limits.first?.remaining == 3)
      #expect(WeatherRequestCost.units(variables: 15, locations: 2, models: 1, hours: 672) == 6)
    }
  }

  @Test
  func `coalesces weather requests and serves fresh cache without fetching`() async throws {
    try await withDatabase { store in
      let cache = WeatherCache(database: store.database, freshness: 900)
      let counter = FetchCounter()
      let fetch: @Sendable () async throws -> Value = {
        await counter.increment()
        try await Task.sleep(for: .milliseconds(100))
        return .object(["temperature_c": 18])
      }
      let results = try await withThrowingTaskGroup(of: CachedWeather.self) { group in
        for _ in 0..<10 {
          group.addTask { try await cache.value(key: "fixture", provider: "awc", fetch: fetch) }
        }
        var results: [CachedWeather] = []
        for try await result in group { results.append(result) }
        return results
      }
      #expect(await counter.count == 1)
      #expect(results.allSatisfy { $0.payload.objectValue?["temperature_c"] == 18 })
      let hit = try await cache.value(key: "fixture", provider: "awc", fetch: fetch)
      #expect(hit.cacheHit)
      #expect(await counter.count == 1)
      for status in [HTTPStatus.tooManyRequests, .serviceUnavailable] {
        let http = WeatherHTTP(
          cache: cache, budgets: ProviderBudgets(database: store.database)
        ) { _ in
          await counter.increment()
          return ClientResponse(status: status, headers: ["Retry-After": "60"])
        }
        for _ in 0..<2 {
          let failure = await #expect(throws: WeatherFailure.self) {
            try await http.get(
              provider: "fixture-\(status.code)", url: "https://example.invalid/weather", units: 1,
              limits: [.init(period: .minute, units: 5)])
          }
          #expect(failure?.retrySource == "upstream")
          #expect(failure?.retryAt.map { $0 > .now } == true)
          #expect(failure?.rateLimits?.tracking == "local_estimate")
        }
      }
      #expect(await counter.count == 3)
    }
  }

  @Test
  func `retains reserved weather budget metadata when upstream data cannot be used`() async throws {
    try await withDatabase { store in
      for transportFailure in [false, true] {
        let http = WeatherHTTP(
          cache: WeatherCache(database: store.database),
          budgets: ProviderBudgets(database: store.database)
        ) { _ in
          if transportFailure { throw URLError(.timedOut) }
          return ClientResponse(status: .ok, body: ByteBuffer(string: "invalid JSON"))
        }
        let failure = await #expect(throws: WeatherFailure.self) {
          try await http.get(
            provider: "awc", url: "https://example.invalid/\(transportFailure)", units: 1,
            limits: [.init(period: .minute, units: 5)])
        }
        #expect(failure?.rateLimits?.tracking == "local_estimate")
        #expect(failure?.rateLimits?.limits.first?.remaining == (transportFailure ? 3 : 4))
        #expect(failure?.retryAt != nil)
      }
      let providers = WeatherProviders(
        http: WeatherHTTP(
          cache: WeatherCache(database: store.database),
          budgets: ProviderBudgets(database: store.database)
        ) { _ in
          ClientResponse(status: .ok, body: ByteBuffer(string: "{}"))
        },
        openMeteoLimits: [.init(period: .day, units: 5)],
        awcLimits: [.init(period: .day, units: 5)])
      let query = WeatherQuery(
        station: "KOAK", latitude: 37.7, longitude: -122.2,
        instant: .now.addingTimeInterval(1800), fields: ["temperature_c"], sources: nil)
      for fetch in [providers.openMeteo, providers.awc] {
        let failure = await #expect(throws: WeatherFailure.self) { try await fetch(query) }
        #expect(failure?.rateLimits?.tracking == "local_estimate")
        #expect(failure?.rateLimits?.limits.first?.remaining == 4)
      }
    }
  }
}

extension `Transactional publication` {
  private static func nearTermReports(at date: Date) -> (metar: Value, taf: Value) {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .gmt
    formatter.dateFormat = "ddHHmm"
    let issued = formatter.string(from: date)
    formatter.dateFormat = "ddHH"
    let start = formatter.string(from: date)
    let end = formatter.string(from: date.addingTimeInterval(21600))
    return (
      .array([
        .object(["rawOb": "invalid METAR"]),
        .object(["rawOb": .string("KOAK \(issued)Z 10015KT 10SM CLR 18/12 A2992")])
      ]),
      .array([
        .object(["rawTAF": "invalid TAF"]),
        .object(["rawTAF": .string("TAF KOAK \(issued)Z \(start)/\(end) 28010KT P6SM SCT020")])
      ])
    )
  }
}

private actor FetchCounter {
  var count = 0
  func increment() { count += 1 }
}

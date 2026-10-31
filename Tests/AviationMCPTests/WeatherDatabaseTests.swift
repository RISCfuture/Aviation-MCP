import Foundation
import MCP
import Testing
import Vapor

@testable import AviationMCP

extension `Transactional publication` {
  @Test
  func `selects valid reports for recent and future requests while reporting rejected neighbors`()
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
      let cases = [
        ReportExpectation(offset: 0, product: "METAR", speed: 15, parseErrors: 2),
        ReportExpectation(offset: -2400, product: "METAR", speed: 20, parseErrors: 2),
        ReportExpectation(offset: 1800, product: "TAF", speed: 10, parseErrors: 1)
      ]
      for expected in cases {
        let result = try await service.weather(
          WeatherQuery(
            station: "KOAK", latitude: nil, longitude: nil,
            instant: now.addingTimeInterval(expected.offset),
            fields: ["wind_gust_kt", "wind_speed_kt"], sources: ["awc"]))
        let weather = try #require(result.results.first?.objectValue)
        let fields = try #require(weather["fields"]?.objectValue)
        let wind = try #require(fields["wind_speed_kt"]?.objectValue)
        #expect(wind["product"] == .string(expected.product))
        #expect(wind["value"]?.intValue == expected.speed)
        #expect(fields["wind_gust_kt"]?.objectValue?["value"] == .null)
        #expect(result.completeness == "partial")
        let gap = try #require(weather["parsing_gaps"]?.arrayValue?.first?.objectValue)
        #expect(gap["parse_errors"]?.objectValue?["count"] == .int(expected.parseErrors))
        if expected.offset == 0 {
          let types = weather["reports"]?.arrayValue?.compactMap { $0.objectValue?["type"] }
          #expect(types == ["METAR", "TAF"])
        }
      }
    }
  }

  @Test
  func `resolves FAA identifiers and positions to the nearest reporting station`() async throws {
    try await withDatabase { store in
      let nasr = Self.version(.nasr)
      let cifp = Self.version(.cifp)
      try await store.publish(
        [nasr, cifp],
        records: [
          Self.airport(nasr, lid: "SQL", icao: "KSQL", latitude: 37.5119, longitude: -122.2495),
          Self.airport(nasr, lid: "O69", icao: nil, latitude: 38.2578, longitude: -122.6055),
          .fixture(cifp)
        ])
      let reports = Self.stationReports(at: .now)
      let providers = WeatherProviders(
        http: WeatherHTTP(
          cache: WeatherCache(database: store.database),
          budgets: ProviderBudgets(database: store.database)
        ) { request in
          let body = Self.stationResponse(for: request.url, reports: reports)
          let json = try #require(String(data: try JSONEncoder().encode(body), encoding: .utf8))
          return ClientResponse(status: .ok, body: ByteBuffer(string: json))
        })
      let service = WeatherService(
        awc: providers.awc, openMeteo: nil,
        locate: { try await WeatherLocation(store: store).resolve($0) })
      let requests = [
        StationExpectation(station: "SQL", reporter: "KSQL"),
        StationExpectation(station: "O69", reporter: "KO69"),
        StationExpectation(latitude: 38.15, longitude: -122.56, reporter: "KDVO")
      ]
      for request in requests {
        let result = try await service.weather(
          WeatherQuery(
            station: request.station, latitude: request.latitude, longitude: request.longitude,
            instant: .now, fields: ["wind_speed_kt"], sources: ["awc"]))
        let weather = try #require(result.results.first?.objectValue)
        let reporter = try #require(weather["reporting_station"]?.objectValue)
        #expect(reporter["identifier"] == .string(request.reporter))
        #expect((reporter["distance_nm"]?.doubleValue ?? 0) <= StationSearchArea.radiusNM)
        #expect(result.sources.map(\.source) == (request.station == nil ? [] : ["nasr"]))
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
      try await RequestClient.$key.withValue(IPNetwork(cidr: "192.0.2.1")) {
        _ = try await http.get(
          provider: "awc", url: "https://example.invalid/a", units: 1, limits: limits)
        let refusal = await #expect(throws: WeatherFailure.self) {
          try await http.get(
            provider: "awc", url: "https://example.invalid/b", units: 1, limits: limits)
        }
        #expect(refusal?.clientSpecific == true)
      }
      try await RequestClient.$key.withValue(IPNetwork(cidr: "192.0.2.2")) {
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
      let fetches: [(fetch: WeatherService.Provider, remaining: Double)] = [
        (providers.openMeteo, 4), (providers.awc, 3)
      ]
      for expected in fetches {
        let failure = await #expect(throws: WeatherFailure.self) { try await expected.fetch(query) }
        #expect(failure?.rateLimits?.tracking == "local_estimate")
        #expect(failure?.rateLimits?.limits.first?.remaining == expected.remaining)
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
    let previous = formatter.string(from: date.addingTimeInterval(-3000))
    formatter.dateFormat = "ddHH"
    let start = formatter.string(from: date)
    let end = formatter.string(from: date.addingTimeInterval(21600))
    return (
      .array([
        .object(["rawOb": "invalid METAR"]),
        .object(["rawOb": .string("KOAK \(previous)Z 10020KT 10SM CLR 18/12 A2992")]),
        .object(["rawOb": .string("KOAK \(issued)Z 10015KT 10SM CLR 18/12 A2992")])
      ]),
      .array([
        .object(["rawTAF": "invalid TAF"]),
        .object(["rawTAF": .string("TAF KOAK \(issued)Z \(start)/\(end) 28010KT P6SM SCT020")])
      ])
    )
  }
}

private struct ReportExpectation {
  let offset: TimeInterval
  let product: String
  let speed: Int
  let parseErrors: Int
}

private struct StationExpectation {
  var station: String?
  var latitude: Double?
  var longitude: Double?
  let reporter: String
}

extension `Transactional publication` {
  private static func stationResponse(
    for url: URI, reports: (named: Value, nearby: Value)
  ) -> Value {
    guard url.path.hasSuffix("metar") else { return [] }
    let query = url.query ?? ""
    if query.contains("ids=KSQL") { return reports.named }
    return query.contains("bbox=") ? reports.nearby : []
  }

  private static func airport(
    _ version: SourceVersion, lid: String, icao: String?, latitude: Double, longitude: Double
  ) -> AviationRecord {
    var airport = AviationRecord(
      versionID: version.id, kind: "airport", id: lid, identifier: icao ?? lid, name: lid)
    airport.geometry = Normalization.point(latitude: latitude, longitude: longitude)
    airport.data = ["faa_lid": .string(lid), "icao_identifier": icao.map(Value.string) ?? .null]
    return airport
  }

  private static func stationReports(at date: Date) -> (named: Value, nearby: Value) {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .gmt
    formatter.dateFormat = "ddHHmm"
    let issued = formatter.string(from: date)
    func metar(_ station: String, latitude: Double, longitude: Double) -> Value {
      .object([
        "icaoId": .string(station), "lat": .double(latitude), "lon": .double(longitude),
        "rawOb": .string("\(station) \(issued)Z 22005KT 10SM CLR 18/12 A2992")
      ])
    }
    return (
      .array([metar("KSQL", latitude: 37.5119, longitude: -122.2483)]),
      .array([
        metar("KSTS", latitude: 38.5090, longitude: -122.8130),
        metar("KDVO", latitude: 38.1436, longitude: -122.5561),
        metar("KO69", latitude: 38.2601, longitude: -122.6070)
      ])
    )
  }
}

private actor FetchCounter {
  var count = 0
  func increment() { count += 1 }
}

import Crypto
import Foundation
import MCP
import Vapor

struct WeatherHTTP: Sendable {
  let cache: WeatherCache
  let budgets: ProviderBudgets
  var allowance = ClientAllowance()
  let send: @Sendable (ClientRequest) async throws -> ClientResponse

  func get(provider: String, url: String, units: Double, limits: [BudgetLimit]) async throws
    -> CachedWeather
  {
    let key = "\(provider):\(SHA256.hash(data: Data(url.utf8)))"
    return try await cache.value(key: key, provider: provider) {
      let client = WeatherClient.key
      if let client {
        try await reserveShare(provider: provider, client: client, units: units, limits: limits)
      }
      let report = try await budgets.reserve(provider: provider, units: units, limits: limits)
      guard report.allowed else {
        if let client {
          try await allowance.refund(
            provider: provider, client: client, units: units, limits: limits)
        }
        throw WeatherFailure(
          provider: provider, reason: "Provider budget or retry window is exhausted.",
          retryAt: report.retryAt.flatMap { ISO8601DateFormatter().date(from: $0) },
          retrySource: report.retrySource ?? "local_estimate", rateLimits: report)
      }
      do {
        return try await fetch(provider: provider, url: url, report: report)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        var failure =
          error as? WeatherFailure
          ?? WeatherFailure(
            provider: provider, reason: "Upstream request failed or returned invalid data.")
        failure.rateLimits = failure.rateLimits ?? report
        failure.retryAt = failure.retryAt ?? .now.addingTimeInterval(30)
        throw failure
      }
    }
  }

  private func reserveShare(
    provider: String, client: IPNetwork, units: Double, limits: [BudgetLimit]
  ) async throws {
    guard
      let retry = try await allowance.reserve(
        provider: provider, client: client, units: units, limits: limits)
    else { return }
    throw WeatherFailure(
      provider: provider,
      reason: "This client has used its share of the provider budget; retry after the reset time.",
      retryAt: retry, clientSpecific: true)
  }

  private func fetch(provider: String, url: String, report: BudgetReport) async throws -> Value {
    let request = ClientRequest(
      method: .GET, url: URI(string: url),
      headers: ["User-Agent": "aviation-mcp.org/0.1", "Accept": "application/json"],
      timeout: .seconds(10))
    let response = try await send(request)
    guard (200..<300).contains(response.status.code) else {
      throw try await upstreamFailure(response, provider: provider, report: report)
    }
    if response.status == .noContent { return .array([]) }
    guard let body = response.body, body.readableBytes <= 2_097_152 else {
      throw WeatherFailure(
        provider: provider, reason: "Upstream response is empty or exceeds the size limit.")
    }
    return try JSONDecoder().decode(Value.self, from: Data(body.readableBytesView))
  }

  private func upstreamFailure(_ response: ClientResponse, provider: String, report: BudgetReport)
    async throws -> WeatherFailure
  {
    let supplied = Self.retryDate(response.headers.first(name: "Retry-After"), now: .now)
    let retry = supplied ?? .now.addingTimeInterval(30)
    let source = supplied == nil ? "local_estimate" : "upstream"
    if response.status == .tooManyRequests || supplied != nil {
      try await budgets.coolDown(provider: provider, until: retry, source: source)
    }
    return WeatherFailure(
      provider: provider, reason: "Upstream returned HTTP \(response.status.code).", retryAt: retry,
      retrySource: source, rateLimits: report)
  }

  static func retryDate(_ text: String?, now: Date) -> Date? {
    guard let text else { return nil }
    if let seconds = TimeInterval(text), seconds.isFinite, seconds >= 0 {
      return now.addingTimeInterval(seconds)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .gmt
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
    return formatter.date(from: text).map { max(now, $0) }
  }
}

import Foundation
import MCP

protocol AviationWeatherError: Error {}

struct WeatherFailure: AviationWeatherError, LocalizedError, Codable, Sendable {
  let provider: String
  let reason: String
  var retryAt: Date?
  var retrySource = "local_estimate"
  var rateLimits: BudgetReport?
  var parsingGaps: [Value]?
  /// True when the failure reflects only the requesting client's allowance, so the cache must not
  /// share it with other clients.
  var clientSpecific: Bool?

  var errorDescription: String? { "Weather provider unavailable." }
  var failureReason: String? { reason }
}

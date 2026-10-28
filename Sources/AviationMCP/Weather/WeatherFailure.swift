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

  var errorDescription: String? { "Weather provider unavailable." }
  var failureReason: String? { reason }
}

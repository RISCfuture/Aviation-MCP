import Fluent
import Foundation
import SQLKit

struct DatabaseMetrics: Sendable {
  let database: any Database

  func render() async throws -> String {
    try await database.withSQLTransaction { database in
      let sql = try database.sqlDatabase()
      try await sql.raw("SET TRANSACTION READ ONLY").run()
      try await sql.raw("SET LOCAL statement_timeout = '5s'").run()
      let runs = try await sql.raw(
        """
        SELECT source, outcome, count(*) AS count,
          max(extract(epoch FROM finished_at))::double precision AS finished
        FROM ingestion_runs GROUP BY source, outcome
        """
      ).all(decoding: IngestionMetric.self)
      let budgets = try await sql.raw(
        """
        SELECT provider, period, consumed FROM provider_budgets
        WHERE window_start <= now() AND window_end > now()
        ORDER BY provider, period
        """
      ).all(decoding: BudgetMetric.self)
      return runs.map(Self.ingestion).joined() + budgets.map(Self.budget).joined()
    }
  }

  private static func ingestion(_ run: IngestionMetric) -> String {
    let labels = "source=\"\(escape(run.source))\",outcome=\"\(escape(run.outcome))\""
    var text = "aviation_ingestion_runs{\(labels)} \(run.count)\n"
    if let finished = run.finished {
      text += "aviation_ingestion_last_finished_timestamp_seconds{\(labels)} \(finished)\n"
    }
    return text
  }

  private static func budget(_ budget: BudgetMetric) -> String {
    let labels = "provider=\"\(escape(budget.provider))\",period=\"\(escape(budget.period))\""
    return "aviation_provider_consumed_units{\(labels)} \(budget.consumed)\n"
  }

  private static func escape(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
  }

  private struct IngestionMetric: Decodable {
    let source: String
    let outcome: String
    let count: Int
    let finished: Double?
  }

  private struct BudgetMetric: Decodable {
    let provider: String
    let period: String
    let consumed: Double
  }
}

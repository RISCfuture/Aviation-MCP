import Fluent
import Foundation
import SQLKit
import Vapor

struct AdmissionDecision: Sendable {
  let allowed: Bool
  let retryAfterSeconds: Int
}

struct AdmissionLimiter: Sendable {
  let database: any Database
  var requestsPerMinute: Double = 60
  var burst: Double = 20

  func admit(key: String) async throws -> AdmissionDecision {
    try await database.withSQLTransaction { database in
      let sql = try database.sqlDatabase()
      try await sql.raw("SET LOCAL statement_timeout = '10s'").run()
      try await sql.raw(
        """
        INSERT INTO admission_buckets(key, tokens, updated_at)
        VALUES (\(bind: key), \(bind: burst), clock_timestamp()) ON CONFLICT(key) DO NOTHING
        """
      ).run()
      guard
        let row = try await sql.raw(
          """
          SELECT tokens, updated_at FROM admission_buckets WHERE key = \(bind: key) FOR UPDATE
          """
        ).first()
      else { throw StorageError.requiresPostgreSQL }
      let now = try await sql.clock()
      let previous = try row.decode(column: "updated_at", as: Date.self)
      let refill = max(0, now.timeIntervalSince(previous)) * requestsPerMinute / 60
      let tokens = min(burst, try row.decode(column: "tokens", as: Double.self) + refill)
      let allowed = tokens >= 1
      try await sql.raw(
        """
        UPDATE admission_buckets SET tokens = \(bind: tokens - (allowed ? 1 : 0)),
          updated_at = \(bind: now) WHERE key = \(bind: key)
        """
      ).run()
      return AdmissionDecision(
        allowed: allowed,
        retryAfterSeconds: allowed ? 0 : max(1, Int(ceil((1 - tokens) * 60 / requestsPerMinute))))
    }
  }
}

struct AdmissionMiddleware: AsyncMiddleware {
  let limiter: AdmissionLimiter
  let trustFlyProxy: Bool
  var edgeIdentity = EdgeClientIdentity(secret: nil)

  func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
    guard request.url.path == "/mcp" else { return try await next.respond(to: request) }
    let key =
      edgeIdentity.verifiedIP(headers: request.headers)
      ?? (trustFlyProxy ? request.headers.first(name: "Fly-Client-IP") : nil)
      ?? request.remoteAddress?.ipAddress ?? "unknown"
    let decision = try await limiter.admit(key: key)
    guard decision.allowed else {
      return Response(
        status: .tooManyRequests,
        headers: [
          "Retry-After": String(decision.retryAfterSeconds), "Content-Type": "application/json"
        ],
        body: .init(
          string:
            "{\"error\":\"server_rate_limit\",\"retry_after_seconds\":\(decision.retryAfterSeconds)}"
        ))
    }
    return try await WeatherClient.$key.withValue(key) { try await next.respond(to: request) }
  }
}

import Foundation
import SQLKit

/// The FAA location identifiers and ICAO codes under which datasets may record one requested
/// airport, resolved through the effective NASR airport records.
struct AirportCodes: Sendable {
  enum Resolution: Sendable {
    case matched, unknown, unverifiable
  }

  /// The identifier as the client supplied it, uppercased.
  let requested: String
  /// Every code to match, beginning with the requested identifier.
  let codes: [String]
  let resolution: Resolution

  /// The codes a FAA LID or ICAO identifier stands for in the effective NASR cycle; only the
  /// requested identifier when NASR is unavailable or no airport matches.
  static func resolve(
    _ identifier: String, on sql: any SQLDatabase, snapshot: SourceSnapshot
  ) async throws -> Self {
    let requested = identifier.uppercased()
    guard let version = snapshot.versions[.nasr] else {
      return Self(requested: requested, codes: [requested], resolution: .unverifiable)
    }
    let rows = try await sql.raw(
      """
      SELECT identifier, data->>'faa_lid' AS faa_lid, data->>'icao_identifier' AS icao
      FROM aviation_records WHERE version_id = \(bind: version.id) AND kind = 'airport'
        AND (upper(identifier) = \(bind: requested) OR upper(data->>'faa_lid') = \(bind: requested))
      """
    ).all(decoding: AirportCodeRow.self)
    let aliases = Set(rows.flatMap(\.codes)).subtracting([requested]).sorted()
    return Self(
      requested: requested, codes: [requested] + aliases,
      resolution: rows.isEmpty ? .unknown : .matched)
  }

  /// Explains an empty result when the identifier could not be cross-referenced.
  func emptyResultWarning(role: String) -> String? {
    switch resolution {
    case .matched: nil
    case .unknown:
      "No airport \(requested) exists in the effective NASR cycle; check the \(role) identifier."
    case .unverifiable:
      "No effective NASR cycle can cross-reference \(requested) to its FAA and ICAO identifiers; "
        + "only \(requested) was searched."
    }
  }
}

/// Airport, origin and destination filters for periodic record searches.
struct AirportReferences: Sendable {
  private static let routeKinds: Set = ["preferred_route", "coded_departure_route"]

  var airport: AirportCodes?
  var origin: AirportCodes?
  var destination: AirportCodes?
  let routes: Bool

  /// Resolves the airport-like arguments; obstacle searches use `airport` as a runway context
  /// instead of a filter.
  static func resolve(
    _ arguments: ToolArguments, kinds: [String], on sql: any SQLDatabase, snapshot: SourceSnapshot
  ) async throws -> Self {
    func codes(_ name: String) async throws -> AirportCodes? {
      guard let identifier = try arguments.string(name) else { return nil }
      return try await AirportCodes.resolve(identifier, on: sql, snapshot: snapshot)
    }
    return Self(
      airport: kinds.contains("obstacle") ? nil : try await codes("airport"),
      origin: try await codes("origin"), destination: try await codes("destination"),
      routes: Set(kinds).isSubset(of: routeKinds))
  }

  /// SQL conditions restricting records to the requested airports.
  var predicate: SQLQueryString {
    var query: SQLQueryString = ""
    if let airport {
      query +=
        routes
        ? " AND (\(Self.recorded(airport)) OR \(Self.destination(airport)))"
        : " AND \(Self.recorded(airport))"
    }
    if let origin { query += " AND \(Self.recorded(origin))" }
    if let destination { query += " AND \(Self.destination(destination))" }
    return query
  }

  /// Warnings for identifiers that could not be cross-referenced, given an empty result.
  var emptyResultWarnings: [String] {
    [
      airport?.emptyResultWarning(role: "airport"), origin?.emptyResultWarning(role: "origin"),
      destination?.emptyResultWarning(role: "destination")
    ].compactMap(\.self)
  }

  private static func recorded(_ airport: AirportCodes) -> SQLQueryString {
    "(airport IS NOT NULL AND upper(airport) IN (\(binds: airport.codes)))"
  }

  private static func destination(_ airport: AirportCodes) -> SQLQueryString {
    "upper(data->>'destination') IN (\(binds: airport.codes))"
  }
}

private struct AirportCodeRow: Decodable {
  let identifier: String
  let faaLID: String?
  let icao: String?

  var codes: [String] { [identifier, faaLID, icao].compactMap { $0?.uppercased() } }

  enum CodingKeys: String, CodingKey {
    case identifier
    case faaLID = "faa_lid"
    case icao
  }
}

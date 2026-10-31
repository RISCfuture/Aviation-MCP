import Foundation
import SQLKit

/// Looks up a requested station in the effective NASR cycle for its ICAO identifier and position.
struct WeatherLocation: Sendable {
  let store: AviationStore

  /// Fills in the station's ICAO identifier and, when the query has none, its position; records
  /// why when the station cannot be located.
  func resolve(_ query: WeatherQuery) async throws -> WeatherQuery {
    guard let station = query.station else { return query }
    return try await store.withSnapshot { sql, snapshot in
      guard let version = snapshot.versions[.nasr] else {
        return query.unlocated(
          "No effective NASR cycle can locate \(station); supply coordinates or an ICAO identifier."
        )
      }
      let candidates = try await Self.candidates(station, versionID: version.id, on: sql)
      guard candidates.count == 1, let position = candidates.first else {
        return query.unlocated(
          candidates.isEmpty
            ? "\(station) has no published NASR position; supply coordinates."
            : "\(station) is ambiguous; supply coordinates.")
      }
      var located = query
      located.reportingStation = position.icao
      located.latitude = query.latitude ?? position.latitude
      located.longitude = query.longitude ?? position.longitude
      located.locationSource = SourceStamp(version)
      return located
    }
  }

  private static func candidates(
    _ station: String, versionID: UUID, on sql: any SQLDatabase
  ) async throws -> [StationPosition] {
    let rows = try await sql.raw(
      """
      SELECT id, kind, data->>'icao_identifier' AS icao, ST_Y(geometry::geometry) AS latitude,
        ST_X(geometry::geometry) AS longitude
      FROM aviation_records WHERE version_id = \(bind: versionID)
        AND kind IN ('airport','awos') AND geometry IS NOT NULL
        AND (upper(identifier) = \(bind: station) OR upper(data->>'faa_lid') = \(bind: station))
      ORDER BY (kind = 'airport') DESC, id LIMIT 3
      """
    ).all(decoding: StationPosition.self)
    let airports = rows.filter { $0.kind == "airport" }
    return airports.isEmpty ? rows : airports
  }
}

private struct StationPosition: Decodable {
  let id: String
  let kind: String
  let icao: String?
  let latitude: Double
  let longitude: Double
}

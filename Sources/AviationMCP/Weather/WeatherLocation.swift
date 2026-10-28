import Foundation
import SQLKit

struct WeatherLocation: Sendable {
  let store: AviationStore

  func resolve(_ query: WeatherQuery) async throws -> (query: WeatherQuery, source: SourceStamp?) {
    guard query.latitude == nil, let station = query.station else { return (query, nil) }
    return try await store.withSnapshot { sql, snapshot in
      guard let version = snapshot.versions[.nasr] else {
        throw WeatherFailure(
          provider: "open_meteo",
          reason: "No effective NASR cycle can locate this station; supply coordinates.")
      }
      let rows = try await sql.raw(
        """
        SELECT id, kind, ST_Y(geometry::geometry) AS latitude,
          ST_X(geometry::geometry) AS longitude
        FROM aviation_records WHERE version_id = \(bind: version.id)
          AND kind IN ('airport','awos') AND geometry IS NOT NULL
          AND (upper(identifier) = \(bind: station) OR upper(data->>'faa_lid') = \(bind: station))
        ORDER BY (kind = 'airport') DESC, id LIMIT 3
        """
      ).all(decoding: StationPosition.self)
      let airports = rows.filter { $0.kind == "airport" }
      let candidates = airports.isEmpty ? rows : airports
      guard candidates.count == 1, let position = candidates.first else {
        throw WeatherFailure(
          provider: "open_meteo",
          reason: candidates.isEmpty
            ? "The station has no published NASR position; supply coordinates."
            : "The station identifier is ambiguous; supply coordinates.")
      }
      var resolved = query
      resolved.latitude = position.latitude
      resolved.longitude = position.longitude
      return (resolved, SourceStamp(version))
    }
  }
}

private struct StationPosition: Decodable {
  let id: String
  let kind: String
  let latitude: Double
  let longitude: Double
}

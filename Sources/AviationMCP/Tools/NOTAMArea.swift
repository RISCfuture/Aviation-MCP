import Foundation
import MCP
import SQLKit

/// The NOTAM locations a search covers: the requested airport under its FAA and ICAO
/// identifiers (or the airports near a position), plus the overlying ARTCCs whose area NOTAMs,
/// such as TFRs, are centered near it.
struct NOTAMArea: Sendable {
  private static let defaultRadiusNM = 30.0
  private static let maximumNearbyAirports = 25

  /// NOTAM locations whose NOTAMs are included regardless of position.
  var locations: [String] = []
  /// Overlying ARTCC locations whose NOTAMs are included when centered within the radius.
  var centers: [String] = []
  var reference: GeoPoint?
  var radiusNM = defaultRadiusNM
  var warnings: [String] = []

  /// Resolves `location`, `latitude`/`longitude` and `radius_nm` through the effective NASR cycle.
  static func resolve(_ arguments: ToolArguments, store: AviationStore) async throws -> Self {
    let location = try arguments.string("location")
    let coordinate = try arguments.coordinate().map {
      GeoPoint(latitude: $0.latitude, longitude: $0.longitude)
    }
    guard location != nil || coordinate != nil else {
      throw MCPError.invalidParams("A location or latitude and longitude are required")
    }
    let radius =
      try arguments.number("radius_nm", default: defaultRadiusNM, range: 1...200) ?? defaultRadiusNM
    return try await store.withSnapshot { sql, snapshot in
      var area = Self(radiusNM: radius)
      if let location {
        let airport = try await AirportCodes.resolve(location, on: sql, snapshot: snapshot)
        area.locations = airport.codes
        area.reference = coordinate
      }
      guard let version = snapshot.versions[.nasr] else {
        guard location != nil else { throw StorageError.unavailable(.nasr) }
        area.warnings.append(
          "No effective NASR cycle can locate the overlying ARTCC; area NOTAMs such as TFRs "
            + "are not included.")
        return area
      }
      if let location, coordinate == nil {
        area.reference = try await airportPosition(location, version: version.id, on: sql)
      }
      if location == nil, let coordinate {
        area.locations = try await nearbyAirports(
          coordinate, radiusNM: radius, version: version.id, on: sql)
      }
      try await area.resolveCenters(version: version.id, on: sql)
      return area
    }
  }

  private mutating func resolveCenters(version: UUID, on sql: any SQLDatabase) async throws {
    guard let reference else {
      warnings.append(
        "The location has no published NASR position; area NOTAMs such as TFRs are not included.")
      return
    }
    let rows = try await sql.raw(
      """
      SELECT DISTINCT area.identifier, facility.data->>'icao_identifier' AS icao
      FROM aviation_records area
      LEFT JOIN aviation_records facility ON facility.version_id = area.version_id
        AND facility.kind = 'artcc' AND facility.identifier = area.identifier
      WHERE area.version_id = \(bind: version) AND area.kind = 'artcc_airspace'
        AND ST_Intersects(area.geometry, \(Self.point(reference)))
      """
    ).all(decoding: CenterRow.self)
    centers = Set(rows.flatMap(\.codes)).sorted()
    if centers.isEmpty {
      warnings.append(
        "No overlying ARTCC is published for this position; area NOTAMs such as TFRs are not "
          + "included.")
    } else {
      warnings.append(
        "Area NOTAMs from the overlying ARTCC are included when their Q-line center lies within "
          + "radius_nm; the feed publishes no NOTAM radius, so larger areas centered farther "
          + "away are not included.")
    }
  }

  private static func airportPosition(
    _ location: String, version: UUID, on sql: any SQLDatabase
  ) async throws -> GeoPoint? {
    let rows = try await sql.raw(
      """
      SELECT ST_Y(geometry::geometry) AS latitude, ST_X(geometry::geometry) AS longitude
      FROM aviation_records WHERE version_id = \(bind: version) AND kind = 'airport'
        AND geometry IS NOT NULL
        AND (upper(identifier) = \(bind: location.uppercased())
          OR upper(data->>'faa_lid') = \(bind: location.uppercased()))
      LIMIT 2
      """
    ).all(decoding: Position.self)
    return rows.count == 1
      ? GeoPoint(latitude: rows[0].latitude, longitude: rows[0].longitude) : nil
  }

  private static func nearbyAirports(
    _ reference: GeoPoint, radiusNM: Double, version: UUID, on sql: any SQLDatabase
  ) async throws -> [String] {
    let rows = try await sql.raw(
      """
      SELECT identifier, data->>'faa_lid' AS faa_lid FROM aviation_records
      WHERE version_id = \(bind: version) AND kind = 'airport'
        AND ST_DWithin(geometry, \(point(reference)), \(bind: radiusNM * 1852))
      ORDER BY ST_Distance(geometry, \(point(reference))), id
      LIMIT \(bind: maximumNearbyAirports)
      """
    ).all(decoding: AirportRow.self)
    return Set(rows.flatMap(\.codes)).sorted()
  }

  private static func point(_ point: GeoPoint) -> SQLQueryString {
    "ST_SetSRID(ST_MakePoint(\(bind: point.longitude), \(bind: point.latitude)), 4326)::geography"
  }
}

private struct CenterRow: Decodable {
  let identifier: String
  let icao: String?

  var codes: [String] { [identifier, icao].compactMap { $0?.uppercased() } }
}

private struct AirportRow: Decodable {
  let identifier: String
  let faaLID: String?

  var codes: [String] { [identifier, faaLID].compactMap { $0?.uppercased() } }

  enum CodingKeys: String, CodingKey {
    case identifier
    case faaLID = "faa_lid"
  }
}

private struct Position: Decodable {
  let latitude: Double
  let longitude: Double
}

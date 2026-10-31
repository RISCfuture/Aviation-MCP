import MCP
import SQLKit

extension SpatialContext {
  /// Columns giving each record's distance from the reference, a bearing toward it from a
  /// point reference, and whether an areal record contains or crosses the reference.
  func measurementColumns() throws -> SQLQueryString {
    guard let geometry else { return "" }
    let origin = try Self.geography(geometry)
    var columns: SQLQueryString = """
      , ST_Distance(geometry, \(origin)) / 1852 AS distance_nm,
        CASE WHEN ST_Dimension(geometry::geometry) = 2
          THEN ST_Intersects(geometry, \(origin)) END AS intersects
      """
    if hasPointReference {
      columns += """
        , degrees(ST_Azimuth(\(origin),
            ST_ClosestPoint(geometry::geometry, \(origin)::geometry)::geography))
          AS bearing_true_deg
        """
    }
    return columns
  }

  /// Restricts records to the searched area, or to `radiusNM` around the reference.
  func filter(radiusNM: Double) throws -> SQLQueryString {
    if let area { return " AND ST_Intersects(geometry, \(try Self.geography(area)))" }
    guard let geometry else { return "" }
    return " AND ST_DWithin(geometry, \(try Self.geography(geometry)), \(bind: radiusNM * 1852))"
  }

  /// Orders records by distance from the reference.
  func nearestOrdering() throws -> SQLQueryString? {
    guard let geometry else { return nil }
    return " ORDER BY ST_Distance(geometry, \(try Self.geography(geometry))), id, kind, version_id"
  }

  /// The measurement fields of a row selected with `measurementColumns()`.
  static func measurements(in row: any SQLRow) throws -> [String: Value] {
    var fields: [String: Value] = [:]
    if row.contains(column: "distance_nm"),
      let distance = try row.decode(column: "distance_nm", as: Double?.self)
    {
      fields["distance_nm"] = .double((distance * 100).rounded() / 100)
    }
    if row.contains(column: "bearing_true_deg"),
      let bearing = try row.decode(column: "bearing_true_deg", as: Double?.self)
    {
      fields["bearing_true_deg"] = .int(Int(Geodesy.normalizedCourse(bearing.rounded())))
    }
    if row.contains(column: "intersects"),
      let intersects = try row.decode(column: "intersects", as: Bool?.self)
    {
      fields["intersects"] = .bool(intersects)
    }
    return fields
  }

  private static func geography(_ geometry: Value) throws -> SQLQueryString {
    "ST_GeomFromGeoJSON(\(bind: try Normalization.jsonText(geometry)))::geography"
  }
}

import SQLKit

/// Compares a requested MSL altitude with the vertical limits stored on airspace records.
///
/// Limits use the normalized altitude objects of `CIFPRestrictions.altitude`: ground and
/// unlimited references, MSL feet, surface AGL feet and flight levels are comparable; other
/// AGL limits and unknown references make a match uncertain.
enum AirspaceAltitude {
  /// The warning that accompanies every altitude comparison.
  static let limitation =
    "Altitude matches treat flight levels as 100 ft each without a pressure correction; "
    + "AGL and unpublished limits are reported as uncertain."

  /// `'inside'`, `'outside'` or `'uncertain'` for the record in each row.
  static func match(_ altitudeFeet: Double) -> SQLQueryString {
    let floor = limit("lower_limit", reference: "ground", bound: "-Infinity")
    let ceiling = limit("upper_limit", reference: "unlimited", bound: "Infinity")
    return """
      (CASE WHEN \(floor) > \(bind: altitudeFeet) OR \(ceiling) < \(bind: altitudeFeet)
        THEN 'outside'
        WHEN \(floor) IS NOT NULL AND \(ceiling) IS NOT NULL THEN 'inside'
        ELSE 'uncertain' END)
      """
  }

  private static func limit(_ field: String, reference: String, bound: String) -> SQLQueryString {
    let value: SQLQueryString = "(data->\(literal: field)->>'value')::double precision"
    return """
      (CASE WHEN data->\(literal: field)->>'reference' = \(literal: reference)
          THEN \(literal: bound)::double precision
        WHEN data->\(literal: field)->>'unit' = 'flight_level' THEN \(value) * 100
        WHEN data->\(literal: field)->>'datum' = 'MSL' THEN \(value)
        WHEN data->\(literal: field)->>'datum' = 'AGL' AND \(value) = 0
          THEN '-Infinity'::double precision
        END)
      """
  }
}

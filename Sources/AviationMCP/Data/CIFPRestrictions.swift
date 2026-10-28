import MCP
import SwiftCIFP

enum CIFPRestrictions {
  static func altitude(_ altitude: Altitude) -> Value {
    switch altitude {
    case .feet(let feet, let datum):
      .object(["value": .int(feet), "unit": "ft", "datum": .string(datum == .msl ? "MSL" : "AGL")])
    case .flightLevel(let level):
      .object(["value": .int(level), "unit": "flight_level", "datum": "standard_pressure"])
    case .ground: .object(["reference": "ground"])
    case .unknown: .object(["reference": "unknown"])
    case .unlimited: .object(["reference": "unlimited"])
    }
  }

  static func constraint(_ constraint: AltitudeConstraint) -> Value {
    var fields: [String: Value] = [
      "code": .string(String(constraint.descriptionCode)),
      "description": .string(constraint.description)
    ]
    switch constraint {
    case .at(let value), .atOrAbove(let value), .atOrBelow(let value),
      .glideSlopeIntercept(let value), .glidePathIntercept(let value):
      fields["altitude"] = altitude(value)
    case .between(let lower, let upper), .atOrAboveToAtOrBelow(let lower, let upper),
      .atOrAboveToAt(let lower, let upper), .atToAtOrBelow(let lower, let upper),
      .atToAtOrAbove(let lower, let upper), .atOrBelowToAtOrAbove(let lower, let upper):
      fields["lower"] = altitude(lower)
      fields["upper"] = altitude(upper)
    }
    return .object(fields)
  }

  static func leg(_ leg: ProcedureLeg, coordinate: Coordinate?) -> Value {
    Normalization.object([
      "sequence": .int(leg.sequenceNumber), "fix": leg.fixId.map(Value.string),
      "fix_icao_region": leg.fixICAO.map(Value.string),
      "path_terminator": leg.pathTerminator.map { .string($0.rawValue) },
      "turn_direction": leg.turnDirection.map { .string(String($0.rawValue)) },
      "turn_direction_required": .bool(leg.isTurnDirectionValid),
      "rnp_nm": leg.rnpNM.map(Value.double),
      "course_magnetic_deg": leg.magneticCourseDeg.map(Value.double),
      "altitude_constraint": leg.altitudeConstraint.map(constraint),
      "speed_constraint": leg.speedConstraint.map {
        .object(["code": .string(String($0.descriptionCode)), "knots": .int($0.knots)])
      },
      "transition_altitude_ft": leg.transitionAltitudeFt.map(Value.int),
      "vertical_angle_deg": leg.verticalAngleDeg.map(Value.double),
      "recommended_navaid": leg.recommendedNavaid.map(Value.string),
      "recommended_navaid_icao_region": leg.recommendedNavaidICAO.map(Value.string),
      "arc_radius_nm": leg.arcRadiusNM.map(Value.double),
      "theta_magnetic_deg": leg.thetaDeg.map(Value.double), "rho_nm": leg.rhoNM.map(Value.double),
      "distance_nm_or_time_minutes": leg.routeDistanceNMOrMinutes.map(Value.double),
      "center_fix": leg.centerFix.map(Value.string),
      "center_fix_icao_region": leg.centerFixICAO.map(Value.string),
      "is_initial_fix": .bool(leg.isInitialFix),
      "is_final_approach_fix": .bool(leg.waypointDescription?.isFAF ?? false),
      "is_missed_approach_point": .bool(leg.waypointDescription?.isMAP ?? false),
      "waypoint_description": leg.waypointDescription.map { code in
        .string(
          [
            code.position1?.rawValue, code.position2?.rawValue,
            code.position3?.rawValue, code.position4?.rawValue
          ].map { String($0 ?? " ") }.joined())
      },
      "position": coordinate.map {
        Normalization.point(latitude: $0.latitudeDeg, longitude: $0.longitudeDeg)
      }
    ])
  }
}

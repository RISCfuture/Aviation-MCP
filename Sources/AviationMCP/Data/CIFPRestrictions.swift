import Foundation
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
      .conditionalAtOrAbove(let value):
      fields["altitude"] = altitude(value)
    case .between(let lower, let upper):
      fields["lower"] = altitude(lower)
      fields["upper"] = altitude(upper)
    case .atWithGlideSlope(let value, let glideSlope),
      .atOrAboveWithGlideSlope(let value, let glideSlope):
      fields["altitude"] = altitude(value)
      fields["glide_slope_altitude"] = altitude(glideSlope)
    case .atWithGlideSlopeIntercept(let value, let intercept),
      .atOrAboveWithGlideSlopeIntercept(let value, let intercept):
      fields["altitude"] = altitude(value)
      fields["glide_slope_intercept_altitude"] = altitude(intercept)
    case .atWithVerticalPath(let value, let verticalPath),
      .atOrAboveWithVerticalPath(let value, let verticalPath),
      .atOrBelowWithVerticalPath(let value, let verticalPath):
      fields["altitude"] = altitude(value)
      fields["vertical_path_altitude"] = altitude(verticalPath)
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
      "course": leg.course.map(course),
      "altitude_constraint": leg.altitudeConstraint.map(constraint),
      "speed_constraint": leg.speedConstraint.map {
        .object(["code": .string(String($0.descriptionCode)), "knots": .int($0.knots)])
      },
      "transition_altitude_ft": leg.transitionAltitudeFt.map(Value.int),
      "vertical_angle_deg": leg.verticalAngleDeg.map(Value.double),
      "recommended_navaid": leg.recommendedNavaidId.map(Value.string),
      "recommended_navaid_icao_region": leg.recommendedNavaidICAO.map(Value.string),
      "arc_radius_nm": leg.arcRadiusNM.map(Value.double),
      "theta_magnetic_deg": leg.thetaDeg.map(Value.double), "rho_nm": leg.rhoNM.map(Value.double),
      "length": leg.length.map(length),
      "center_fix": leg.centerFixId.map(Value.string),
      "center_fix_icao_region": leg.centerFixICAO.map(Value.string),
      "is_initial_fix": .bool(leg.isInitialFix),
      "is_final_approach_fix": .bool(leg.waypointDescription?.isFAF ?? false),
      "is_missed_approach_point": .bool(leg.waypointDescription?.isMAP ?? false),
      "is_initial_approach_fix": .bool(leg.waypointDescription?.isIAF ?? false),
      "is_intermediate_fix": .bool(leg.waypointDescription?.isIntermediateFix ?? false),
      "is_final_approach_course_fix": .bool(leg.waypointDescription?.isFACF ?? false),
      "is_first_missed_approach_leg": .bool(
        leg.waypointDescription?.isFirstMissedApproachLeg ?? false),
      "is_flyover": .bool(leg.waypointDescription?.isFlyover ?? false),
      "waypoint_description": leg.waypointDescription.map { .string($0.code) },
      "position": coordinate.map {
        Normalization.point(latitude: $0.latitudeDeg, longitude: $0.longitudeDeg)
      }
    ])
  }

  static func routeType(_ type: Approach.RouteType) -> String {
    switch type {
    case .transition: "transition"
    case .finalApproach: "final_approach"
    case .missedApproach: "missed_approach"
    }
  }

  static func levels(_ levels: Approach.LevelsOfService) -> Value {
    Normalization.object([
      "sbas": levels.sbasServiceLevel.map { .string($0.rawValue) },
      "lnav_vnav_authorized": levels.isLNAVVNAVAuthorized.map(Value.bool),
      "lnav_authorized": levels.isLNAVAuthorized.map(Value.bool),
      "authorized_rnp_nm": .array(
        levels.authorizedRNP.map {
          .double($0.converted(to: .nauticalMiles).value)
        })
    ])
  }

  private static func course(_ course: Course) -> Value {
    .object([
      "degrees": .double(course.degrees),
      "reference": .string(course.reference == .magnetic ? "magnetic" : "true")
    ])
  }

  private static func length(_ length: ProcedureLeg.Length) -> Value {
    switch length {
    case .distance(let distance):
      .object(["value": .double(distance.converted(to: .nauticalMiles).value), "unit": "NM"])
    case .time(let duration):
      .object(["value": .double(duration.converted(to: .minutes).value), "unit": "min"])
    }
  }

}

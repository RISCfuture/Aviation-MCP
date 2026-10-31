import SwiftCIFP

/// Readable names for ARINC 424 procedure codes.
enum CIFPNames {
  /// The chart-style name the coding describes, such as "RNAV (GPS) Y RWY 30" or "VOR/DME-A".
  /// Chart titles can add alternatives the coding omits, such as "ILS OR LOC".
  static func approachName(_ approach: Approach) -> String {
    let parts = approach.identifier.split(separator: "-", maxSplits: 1)
    let suffix = parts.count > 1 ? String(parts[1]) : approach.multipleIndicator
    guard let runway = approach.runwayId else {
      return [approachLabel(approach), suffix].compactMap { $0 }.joined(separator: "-")
    }
    return [approachLabel(approach), suffix, "RWY", runwayDesignation(runway)]
      .compactMap { $0 }.joined(separator: " ")
  }

  /// A departure or arrival route type's case name in snake case, such as "runway_transition".
  static func routeType(_ type: some RawRepresentable<Character>) -> String {
    String(describing: type).reduce(into: "") { name, character in
      if character.isUppercase { name += "_" }
      name += character.lowercased()
    }
  }

  private static func approachLabel(_ approach: Approach) -> String {
    switch approach.approachType {
    case .rnav: approach.navigationRequirement == .rnpAR ? "RNAV (RNP)" : "RNAV (GPS)"
    case .rnpAR: "RNAV (RNP)"
    default: approach.approachType.description
    }
  }

  /// "RW04R" as charted: "4R".
  private static func runwayDesignation(_ runway: String) -> String {
    let designation = runway.dropFirst(2)
    return String(designation.first == "0" ? designation.dropFirst() : designation)
  }
}

extension Approach.NavigationRequirement {
  /// The requirement in snake case, such as "gps_required".
  var name: String {
    switch self {
    case .dmeRequired: "dme_required"
    case .rnpAR: "rnp_authorization_required"
    case .gpsRequiredDMEDMENotAuthorized: "gps_required_dme_dme_not_authorized"
    case .gbas: "gbas"
    case .dmeNotRequired: "dme_not_required"
    case .gpsRequired: "gps_required"
    case .gpsOrDMEDMERequired: "gps_or_dme_dme_required"
    case .dmeDMERequired: "dme_dme_required"
    case .rnavSensorNotSpecified: "rnav_sensor_not_specified"
    case .vorDMERNAV: "vor_dme_rnav"
    case .sbas: "sbas"
    }
  }
}

extension Approach.Landing {
  /// The kind of minimums in snake case, such as "straight_in".
  var name: String {
    switch self {
    case .straightIn: "straight_in"
    case .circleToLand: "circle_to_land"
    case .helipad: "helipad"
    }
  }
}

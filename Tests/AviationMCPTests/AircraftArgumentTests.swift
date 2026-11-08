import AircraftPerformance
import Foundation
import MCP
import Testing

@testable import AviationMCP

@Suite
struct `Aircraft argument and capability gating` {
  @Test
  func `reads every aircraft back from the object it echoes, refusing what it does not name`()
    throws
  {
    for aircraft in AircraftArgument.all {
      #expect(
        try AircraftArgument.parse(.object(AircraftArgument.description(aircraft))) == aircraft)
    }
    #expect(
      try AircraftArgument.parse(["type": "sf50", "generation": "g2_updated_thrust"])
        == .sf50(.g2(updatedThrustSchedule: true)))
    #expect(
      try AircraftArgument.parse([
        "type": "sr22", "hartzell_propeller": true, "turbonormalized": false
      ]) == .sr22(SR22Options(hartzellPropeller: true, turbonormalized: false)))
    let refused: [MCP.Value] = [
      "sf50", ["generation": "g1"], ["type": "c172"], ["type": "sf50"],
      ["type": "sf50", "generation": "g4"], ["type": "sf50", "generation": "g1", "turbo": true],
      ["type": "sr22", "hartzell_propeller": true],
      ["type": "sr22", "hartzell_propeller": true, "turbonormalized": "yes"],
      ["type": "sr22", "hartzell_propeller": true, "turbonormalized": true, "generation": "g1"]
    ]
    for value in refused {
      #expect(throws: (any Error).self, "\(value)") { try AircraftArgument.parse(value) }
    }
  }

  @Test
  func `gives the SF50 contamination, every flap setting and every climb schedule`()
    throws
  {
    let sf50 = try PerformanceFixtures.aircraft(["type": "sf50", "generation": "g2_plus"])
    let turf = PerformanceFixtures.runway(surface: .turf)
    try PerformanceContamination.check(
      .waterOrSlush(depth: .init(value: 0.25, unit: .inches)), aircraft: sf50, runway: turf,
      operation: .landing)
    #expect(throws: ToolInputError.self) {
      try PerformanceContamination.check(
        .wetRunway, aircraft: sf50, runway: turf, operation: .takeoff)
    }
    #expect(try sf50.landingFlapSetting(ToolArguments(["flaps": "up_ice"])) == .flapsUpIce)
    #expect(try sf50.landingFlapSetting(ToolArguments()) == .flaps100)
    #expect(sf50.unavailable([("vref_kt", .vref)]) == nil)
    #expect(ClimbReport.unavailableSchedules(for: sf50.aircraft).isEmpty)
    #expect(
      ClimbReport.schedules(for: sf50.aircraft).map(\.name) == [
        "takeoff", "enroute_obstacle", "enroute_obstacle_ice", "enroute", "enroute_ice"
      ])
  }

  @Test
  func `limits the SR22 to wet turf, flaps 100 and its own outputs`() throws {
    let sf50 = try PerformanceFixtures.aircraft(["type": "sf50", "generation": "g2_plus"])
    let turf = PerformanceFixtures.runway(surface: .turf)
    let sr22 = try PerformanceFixtures.aircraft([
      "type": "sr22", "hartzell_propeller": false, "turbonormalized": true
    ])
    try PerformanceContamination.check(
      .wetRunway, aircraft: sr22, runway: turf, operation: .takeoff)
    for (contamination, surface) in [
      (Contamination.wetRunway, SurfaceType.paved), (.compactSnow, .turf)
    ] {
      #expect(throws: ToolInputError.self) {
        try PerformanceContamination.check(
          contamination, aircraft: sr22, runway: PerformanceFixtures.runway(surface: surface),
          operation: .landing)
      }
    }
    #expect(throws: ToolInputError.self) {
      try sr22.landingFlapSetting(ToolArguments(["flaps": "50"]))
    }
    #expect(throws: ToolInputError.self) {
      try PerformanceAircraft(
        ToolArguments([
          "aircraft": .object(AircraftArgument.description(sr22.aircraft)),
          "vref_additive_kt": 5
        ]), through: .current, requiringWeight: false)
    }
    #expect(try sr22.airConditioner(ToolArguments(["air_conditioner": true])))
    #expect(throws: ToolInputError.self) {
      try sf50.airConditioner(ToolArguments(["air_conditioner": true]))
    }
    let unavailable = try #require(sr22.unavailable(Self.landingOutputs)?.arrayValue)
    #expect(unavailable.compactMap { $0.objectValue?["output"]?.stringValue } == ["vref_kt"])
    #expect(ClimbReport.schedules(for: sr22.aircraft).map(\.name) == ["takeoff", "enroute"])
    #expect(
      ClimbReport.unavailableSchedules(for: sr22.aircraft).map(\.output) == [
        "schedules.enroute_obstacle", "schedules.enroute_obstacle_ice", "schedules.enroute_ice"
      ])
  }

  private static let landingOutputs: [(output: String, capability: PerformanceCapability)] = [
    ("vref_kt", .vref), ("balked_landing_climb_gradient_ft_per_nm", .balkedLandingClimb)
  ]
}

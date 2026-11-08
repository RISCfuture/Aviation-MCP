import AircraftPerformance
import Foundation
import MCP

/// The airport a calculation is for, if any, and the NASR cycle it came from.
struct PerformanceSite: Sendable {
  var airport: PerformanceAirport?
  var sources: [SourceStamp] = []
  var warnings: [String] = []

  /// The runway end the arguments name, refusing a calculation that lacks a distance it needs.
  ///
  /// - Parameters:
  ///   - distanceArgument: The argument that supplies the needed distance.
  ///   - distance: Reads the needed distance from the resolved runway.
  func runway(
    _ arguments: ToolArguments, requiring distanceArgument: String,
    distance: (ResolvedRunway) -> Sourced<Double>?
  ) throws -> ResolvedRunway {
    let runway = try runway(arguments, name: arguments.string("runway"))
    guard distance(runway) != nil else {
      throw ToolInputError(
        reason: "The runway's available distance is unknown; supply \(distanceArgument).")
    }
    return runway
  }

  /// The runway end `name`, or the runway the overrides describe when there is no airport.
  func runway(_ arguments: ToolArguments, name: String?) throws -> ResolvedRunway {
    let overrides = try RunwayOverrides(arguments)
    guard let airport else {
      var runway = try ResolvedRunway.resolve(airport: nil, end: nil, overrides: overrides)
      runway.name = name
      return runway
    }
    guard let name else { throw ToolInputError(reason: "runway is required with airport.") }
    return try ResolvedRunway.resolve(
      airport: airport, end: airport.end(name), overrides: overrides)
  }

  /// Every input echoed with its origin.
  func inputs(
    runway: ResolvedRunway, weather: ResolvedWeather, pressureAltitude: Measurement<UnitLength>
  ) throws -> [String: MCP.Value] {
    var inputs = try runway.provenance().merging(
      weather.provenance(pressureAltitude: pressureAltitude)
    ) { $1 }
    inputs["airport"] = airport?.description
    return inputs
  }
}

extension MCP.Value {
  /// The object with `fields` added, replacing any of the same name.
  func merging(_ fields: [String: Self]) -> Self {
    .object((objectValue ?? [:]).merging(fields) { $1 })
  }
}

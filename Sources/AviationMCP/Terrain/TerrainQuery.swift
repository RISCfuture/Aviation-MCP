import Foundation
import MCP

struct TerrainQuery: Sendable {
  let route: Value
  let start: Value
  let halfWidthMeters: Double
  let climb: [String: Value]?

  init(_ arguments: ToolArguments) throws {
    guard let coordinates = arguments.values["route"]?.arrayValue,
      (2...20).contains(coordinates.count),
      let width = try arguments.number("half_width_nm", range: 0.05...2)
    else {
      throw MCPError.invalidParams(
        "Terrain requires 2–20 route points and half_width_nm from 0.05 to 2")
    }
    for point in coordinates {
      guard let pair = point.arrayValue, pair.count == 2 else {
        throw MCPError.invalidParams("Terrain coordinates must be [longitude, latitude] pairs")
      }
      _ = try ToolArguments(["longitude": pair[0], "latitude": pair[1]]).coordinate()
    }
    route = .object(["type": "LineString", "coordinates": .array(coordinates)])
    start = coordinates[0]
    halfWidthMeters = width * 1852 * 1.002 + 10
    let altitude = try arguments.number("starting_altitude_ft", range: -1500...60000)
    let gradient = try arguments.number("gradient_ft_per_nm", range: 0...2000)
    let clearance = try arguments.number("clearance_ft", range: 0...10000)
    let datum = try arguments.string("vertical_datum")
    if altitude == nil, gradient == nil, clearance == nil, datum == nil {
      climb = nil
    } else {
      guard let altitude, let gradient, let clearance, datum == "EGM2008" else {
        throw MCPError.invalidParams(
          "Climb comparison requires starting_altitude_ft, gradient_ft_per_nm, clearance_ft and vertical_datum EGM2008"
        )
      }
      climb = [
        "starting_altitude_ft": .double(altitude), "gradient_ft_per_nm": .double(gradient),
        "clearance_ft": .double(clearance)
      ]
    }
  }
}

struct TerrainFailure: LocalizedError {
  let reason: String
  var errorDescription: String? { "Terrain analysis is unavailable." }
  var failureReason: String? { reason }
}

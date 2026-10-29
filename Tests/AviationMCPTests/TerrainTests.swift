import Foundation
import MCP
import SQLKit
import Testing

@testable import AviationMCP

@Suite
struct `Bounded terrain requests` {
  @Test
  func `requires complete climb assumptions in the terrain vertical datum`() throws {
    let route: Value = .array([.array([-122.4, 37.6]), .array([-122.15, 37.15])])
    let base: [String: Value] = ["route": route, "half_width_nm": 1]
    #expect(try TerrainQuery(ToolArguments(base)).climb == nil)
    var values = base
    values["starting_altitude_ft"] = 1000
    #expect(throws: MCPError.self) { try TerrainQuery(ToolArguments(values)) }
    values["gradient_ft_per_nm"] = 200
    values["clearance_ft"] = 100
    values["vertical_datum"] = "NAVD88"
    #expect(throws: MCPError.self) { try TerrainQuery(ToolArguments(values)) }
    values["vertical_datum"] = "EGM2008"
    #expect(
      try TerrainQuery(ToolArguments(values)).climb?["gradient_ft_per_nm"]?.doubleValue == 200)
  }

  @Test
  func `parses catalog coordinates strictly and rejects duplicate or invalid cells`() throws {
    let name = "Copernicus_DSM_COG_10_S01_00_W123_00_DEM"
    let cells = try TerrainCatalog.parse(name + "\n", product: "glo30")
    #expect(cells.first?.latitude == -1)
    #expect(cells.first?.longitude == -123)
    #expect(throws: StorageError.self) {
      try TerrainCatalog.parse(name + "\n" + name, product: "glo30")
    }
    #expect(throws: StorageError.self) {
      try TerrainCatalog.parse("Copernicus_DSM_COG_10_N90_00_W123_00_DEM", product: "glo30")
    }
    #expect(throws: StorageError.self) {
      try TerrainCatalog.parse(name + "\nmalformed", product: "glo30")
    }
  }
}

extension `Transactional publication` {
  @Test
  func `publishes terrain catalogs atomically and splits antimeridian corridors`() async throws {
    try await withDatabase { store in
      try await TerrainSchema().prepare(on: store.database)
      let names = (-40..<40).flatMap { latitude in
        (-160..<160).map { longitude in
          String(
            format: "Copernicus_DSM_COG_10_%@%02d_00_%@%03d_00_DEM",
            latitude < 0 ? "S" : "N", abs(latitude), longitude < 0 ? "W" : "E", abs(longitude))
        }
      }
      let fine = names.joined(separator: "\n")
      let coarse =
        fine.replacingOccurrences(of: "COG_10_", with: "COG_30_")
        + "\nCopernicus_DSM_COG_30_N00_00_E179_00_DEM"
      let catalog = TerrainCatalog(database: store.database)
      try await catalog.publish(glo30: fine, glo90: coarse)
      let status = try await catalog.status()
      #expect(status.objectValue?["counts"]?.objectValue?["glo90"] == 1)
      await #expect(throws: StorageError.self) {
        try await catalog.publish(glo30: "incomplete", glo90: coarse)
      }
      #expect(try await catalog.status() == status)
      let query = try TerrainQuery(
        ToolArguments([
          "route": .array([.array([179.98, 0.5]), .array([-179.98, 0.5])]), "half_width_nm": 1
        ]))
      let request = try await catalog.request(query)
      let tiles = try #require(request["tiles"]?.arrayValue)
      #expect(tiles.contains { $0.objectValue?["product"] == "glo90" })
      #expect(tiles.contains { $0.objectValue?["product"] == "ocean" })
      let geometry = try #require(tiles.first?.objectValue?["geometry"])
      let json = String(data: try JSONEncoder().encode(geometry), encoding: .utf8)
      let sql = try store.database.sqlDatabase()
      let crossesGreenwich = try await sql.raw(
        """
        SELECT ST_Intersects(ST_SetSRID(ST_GeomFromGeoJSON(\(bind: json)),4326),
          ST_SetSRID(ST_MakePoint(0,0.5),4326)) AS crosses
        """
      ).first(decodingColumn: "crosses", as: Bool.self)
      #expect(crossesGreenwich == false)
      let tooLong = try TerrainQuery(
        ToolArguments([
          "route": .array([.array([0, 0]), .array([80, 0])]), "half_width_nm": 1
        ]))
      await #expect(throws: MCPError.self) { try await catalog.request(tooLong) }
    }
  }
}

extension `Bounded terrain requests` {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["TEST_TERRAIN_PYTHON"] != nil))
  func `cancels a running raster worker and cleans up its request files`() async throws {
    let python = try #require(ProcessInfo.processInfo.environment["TEST_TERRAIN_PYTHON"])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "terrain-test-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = directory.appendingPathComponent("wait.py")
    let started = directory.appendingPathComponent("started")
    let program =
      "import pathlib, sys, time\n"
      + "pathlib.Path(\(String(reflecting: started.path))).write_text(sys.argv[1])\ntime.sleep(60)\n"
    try program.write(to: script, atomically: true, encoding: .utf8)
    let worker = TerrainWorker(
      python: python, script: script.path, cacheDirectory: directory.path, cacheBytes: 1_048_576)
    let task = Task { try await worker.run(Data("{}".utf8)) }
    defer { task.cancel() }
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: started.path) {
      try await Task.sleep(for: .milliseconds(20))
    }
    let requestPath = try String(contentsOf: started, encoding: .utf8)
    let start = ContinuousClock.now
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(start.duration(to: .now) < .seconds(2))
    #expect(!FileManager.default.fileExists(atPath: requestPath))
  }
}

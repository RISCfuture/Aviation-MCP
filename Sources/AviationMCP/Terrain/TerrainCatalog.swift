import Fluent
import Foundation
import MCP
import SQLKit
import Vapor

struct TerrainCell: Codable, Sendable {
  let latitude: Int
  let longitude: Int
  let name: String
  let product: String
  var key: String { "\(latitude),\(longitude)" }
}

struct TerrainCatalog: Sendable {
  let database: any Database

  static func parse(_ text: String, product: String) throws -> [TerrainCell] {
    let resolution = product == "glo30" ? "10" : "30"
    var keys = Set<String>()
    return try text.split(whereSeparator: \.isNewline).map { line in
      let fields = line.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
      guard fields.count == 9, fields[0...2] == ["Copernicus", "DSM", "COG"],
        fields[3] == resolution, fields[5] == "00", fields[7] == "00", fields[8] == "DEM",
        fields[4].count == 3, fields[6].count == 4,
        ["N", "S"].contains(String(fields[4].prefix(1))),
        ["E", "W"].contains(String(fields[6].prefix(1))),
        let latitudeValue = Int(fields[4].dropFirst()), latitudeValue >= 0,
        let longitudeValue = Int(fields[6].dropFirst()), longitudeValue >= 0
      else { throw StorageError.invalidImport("Malformed Copernicus catalog entry.") }
      let latitude = latitudeValue * (fields[4].hasPrefix("S") ? -1 : 1)
      let longitude = longitudeValue * (fields[6].hasPrefix("W") ? -1 : 1)
      let cell = TerrainCell(
        latitude: latitude, longitude: longitude, name: String(line), product: product)
      guard (-90..<90).contains(latitude), (-180..<180).contains(longitude),
        keys.insert(cell.key).inserted
      else { throw StorageError.invalidImport("Duplicate or invalid Copernicus catalog cell.") }
      return cell
    }
  }

  func publish(glo30: String, glo90: String) async throws {
    let fine = try Self.parse(glo30, product: "glo30")
    let coarse = try Self.parse(glo90, product: "glo90")
    guard (25000...40000).contains(fine.count), (25000...40000).contains(coarse.count),
      Set(fine.map(\.key)).isSubset(of: Set(coarse.map(\.key)))
    else {
      throw StorageError.invalidImport(
        "Copernicus catalogs are incomplete or inconsistent; ocean cannot be inferred.")
    }
    let checksum = Normalization.checksum(Data((glo30 + "\nGLO90\n" + glo90).utf8))
    var selected = Dictionary(uniqueKeysWithValues: coarse.map { ($0.key, $0) })
    for cell in fine { selected[cell.key] = cell }
    let cells = (-90..<90).flatMap { latitude in
      (-180..<180).map { longitude in
        selected["\(latitude),\(longitude)"]
          ?? TerrainCell(
            latitude: latitude, longitude: longitude, name: "ocean:\(latitude),\(longitude)",
            product: "ocean")
      }
    }
    let data = try JSONEncoder().encode(cells)
    let json = String(data: data, encoding: .utf8)
    let counts =
      "{\"glo30\":\(fine.count),\"glo90\":\(coarse.count - fine.count),\"ocean\":\(cells.count - coarse.count)}"
    try await database.withSQLTransaction { connection in
      let sql = try connection.sqlDatabase()
      try await sql.raw("SELECT pg_advisory_xact_lock(742916)").run()
      let current = try await sql.raw("SELECT checksum FROM terrain_catalog").first(
        decodingColumn: "checksum", as: String.self)
      guard current != checksum else { return }
      try await sql.raw("DELETE FROM terrain_tiles").run()
      try await sql.raw(
        """
        INSERT INTO terrain_tiles(latitude,longitude,name,product,footprint)
        SELECT latitude,longitude,name,product,
          ST_MakeEnvelope(longitude,latitude,longitude+1,latitude+1,4326)::geography
        FROM jsonb_to_recordset(\(bind: json)::jsonb)
          AS x(latitude smallint,longitude smallint,name text,product text)
        """
      ).run()
      try await sql.raw(
        """
        INSERT INTO terrain_catalog(singleton,checksum,source_release,counts)
        VALUES(true,\(bind: checksum),'Copernicus DEM 2021 AWS public',\(bind: counts)::jsonb)
        ON CONFLICT(singleton) DO UPDATE SET checksum=excluded.checksum,
          imported_at=now(),source_release=excluded.source_release,counts=excluded.counts
        """
      ).run()
      try await sql.raw("ANALYZE terrain_tiles").run()
    }
  }

  func status() async throws -> Value {
    let sql = try database.sqlDatabase()
    guard
      let row = try await sql.raw(
        """
        SELECT checksum,source_release,imported_at::text,counts::text AS counts FROM terrain_catalog
        """
      ).first()
    else { return .object(["source": "terrain", "status": "unavailable"]) }
    return .object([
      "source": "terrain", "status": "available",
      "catalog_checksum": .string(try row.decode(column: "checksum", as: String.self)),
      "source_release": .string(try row.decode(column: "source_release", as: String.self)),
      "catalog_retrieved_at": .string(try row.decode(column: "imported_at", as: String.self)),
      "counts": try JSONDecoder().decode(
        Value.self, from: Data(row.decode(column: "counts", as: String.self).utf8)),
      "vertical_datum": "EGM2008"
    ])
  }

  func request(_ query: TerrainQuery) async throws -> [String: Value] {
    let route = String(data: try JSONEncoder().encode(query.route), encoding: .utf8)
    return try await database.withSQLTransaction { connection in
      let sql = try connection.sqlDatabase()
      try await sql.raw("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY").run()
      try await sql.raw("SET LOCAL statement_timeout = '8s'").run()
      let metadata = try await TerrainCatalog(database: connection).status()
      guard metadata.objectValue?["status"] == "available" else {
        throw TerrainFailure(reason: "The terrain catalog has not been published.")
      }
      let length = try await sql.raw(
        """
        SELECT ST_Length(ST_SetSRID(ST_GeomFromGeoJSON(\(bind: route)),4326)::geography) AS length
        """
      ).first(decodingColumn: "length", as: Double.self)
      guard let length, length > 1, length <= 500 * 1852 else {
        throw MCPError.invalidParams(
          "Terrain route length must be greater than one meter and at most 500 NM")
      }
      let rows = try await sql.raw(
        """
        WITH route AS MATERIALIZED (
          SELECT ST_SetSRID(ST_GeomFromGeoJSON(\(bind: route)),4326)::geography AS line),
        segments AS (
          SELECT (ST_DumpSegments(ST_Segmentize(line,1000)::geometry)).geom AS line FROM route),
        buffers AS (
          SELECT ST_Buffer(line::geography,\(bind: query.halfWidthMeters),'quad_segs=16')::geometry AS shape
          FROM segments),
        corridor AS MATERIALIZED (
          SELECT ST_UnaryUnion(ST_Collect(CASE WHEN ST_XMax(shape)-ST_XMin(shape)>180
            THEN ST_WrapX(ST_ShiftLongitude(shape),180,-360) ELSE shape END)) AS shape FROM buffers)
        SELECT t.name,t.product,ST_AsGeoJSON(c.shape,12) AS geometry
        FROM terrain_tiles t CROSS JOIN route r CROSS JOIN corridor c
        WHERE ST_DWithin(t.footprint,r.line,\(bind: query.halfWidthMeters + 200))
          AND (t.product <> 'ocean' OR ST_Intersects(t.footprint::geometry,c.shape))
        ORDER BY t.latitude,t.longitude LIMIT 33
        """
      ).all()
      guard !rows.isEmpty, rows.count <= 32 else {
        throw TerrainFailure(
          reason: "Terrain queries cover at most 32 degree tiles; shorten the route.")
      }
      let tiles = try Self.tiles(rows)
      var request: [String: Value] = [
        "tiles": .array(tiles), "catalog": metadata,
        "start": query.start, "half_width_m": .double(query.halfWidthMeters),
        "route_distance_nm": .double(length / 1852)
      ]
      request["climb"] = query.climb.map(Value.object)
      return request
    }
  }
  private static func tiles(_ rows: [any SQLRow]) throws -> [Value] {
    try rows.map { row in
      let geometry = try row.decode(column: "geometry", as: String.self)
      return .object([
        "name": .string(try row.decode(column: "name", as: String.self)),
        "product": .string(try row.decode(column: "product", as: String.self)),
        "geometry": try JSONDecoder().decode(Value.self, from: Data(geometry.utf8))
      ])
    }
  }

}

struct ImportTerrainCommand: AsyncCommand {
  struct Signature: CommandSignature {}
  var help: String {
    "Validate and atomically publish the public Copernicus terrain tile catalogs."
  }

  func run(using context: CommandContext, signature: Signature) async throws {
    let fine = try await download("30m", app: context.application)
    let coarse = try await download("90m", app: context.application)
    try await TerrainCatalog(database: context.application.db).publish(glo30: fine, glo90: coarse)
    context.console.info("Published the terrain catalog; elevation files remain on demand.")
  }

  private func download(_ resolution: String, app: Application) async throws -> String {
    let response = try await app.client.get(
      URI(string: "https://copernicus-dem-\(resolution).s3.amazonaws.com/tileList.txt"))
    guard response.status == .ok, let body = response.body, body.readableBytes <= 8 * 1024 * 1024,
      let text = body.getString(at: body.readerIndex, length: body.readableBytes)
    else { throw StorageError.invalidImport("Could not download a complete Copernicus catalog.") }
    return text
  }
}

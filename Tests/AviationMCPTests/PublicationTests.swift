import Fluent
import FluentPostgresDriver
import Foundation
import MCP
import PostgresKit
import SQLKit
import Testing
import Vapor
import VaporTesting

@testable import AviationMCP

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TEST_DATABASE_URL"] != nil))
struct `Transactional publication` {
  @Test
  func `repairs an invalid identifier index and preserves a valid one`() async throws {
    try await withDatabase { store in
      let sql = try await Self.makeInvalidIdentifierIndex(store)
      #expect(try await Self.identifierIndexState(sql).valid == false)
      try await IdentifierLookupIndex().prepare(on: store.database)
      let repaired = try await Self.identifierIndexState(sql)
      #expect(repaired.valid)
      try await IdentifierLookupIndex().prepare(on: store.database)
      #expect(try await Self.identifierIndexState(sql).oid == repaired.oid)
    }
  }

  @Test
  func `keeps the service ready while individual datasets are unavailable`() async throws {
    try await withDatabase { store in
      try await withApp { app in
        registerOperations(app, store: store, groups: [.airports], metrics: ServerMetrics())
        try await app.testing().test(.GET, "/ready") { response in
          #expect(response.status == .ok)
          let body = try response.content.decode([String: String].self)
          #expect(body["status"] == "ready")
          #expect(body["data_status"] == "degraded")
          #expect(body["unavailable_sources"] == "nasr")
        }
        let nasr = Self.version(.nasr)
        let cifp = Self.version(.cifp)
        try await store.publish([nasr, cifp], records: [.fixture(nasr), .fixture(cifp)])
        try await app.testing().test(.GET, "/ready") { response in
          #expect(response.status == .ok)
          let body = try response.content.decode([String: String].self)
          #expect(body["data_status"] == "available")
          #expect(body["unavailable_sources"] == "")
        }
      }
    }
  }

  @Test(arguments: [(true, 2), (false, 2), (true, 100)])
  func `retries acquisition at most three times without replaying queries`(
    beforeQuery: Bool, failures: Int
  ) async throws {
    let attempts = ConnectionAttempts()
    var value: Int?
    do {
      value = try await SQLConnectionAcquisition.run {
        let attempt = await attempts.advance()
        guard attempt <= failures else { return .success(42) }
        if beforeQuery { throw ChannelError.ioOnClosedChannel }
        return .failure(ChannelError.ioOnClosedChannel)
      }
    } catch {
      #expect(error is ChannelError)
    }
    #expect(await attempts.count == (beforeQuery ? 3 : 1))
    #expect(value == (beforeQuery && failures == 2 ? 42 : nil))
  }

  @Test
  func `returns the original failure when rollback loses its connection`() async throws {
    try await withDatabase { store async throws in
      do {
        try await store.database.withSQLTransaction { database in
          let postgres = try #require(database as? any PostgresDatabase)
          try await postgres.withConnection { $0.close() }.get()
          let sql = try database.sqlDatabase()
          await #expect(throws: ChannelError.self) {
            try await sql.raw("SELECT 1").run()
          }
          throw CancellationError()
        }
        Issue.record("A failed transaction returned successfully")
      } catch {
        #expect(error is CancellationError)
      }
      let snapshot = try await store.snapshot()
      #expect(snapshot.versions.isEmpty)
    }
  }

  @Test
  func `publishes complete source pairs and rolls back invalid batches`() async throws {
    try await withDatabase { store in
      var nasr = Self.version(.nasr)
      nasr.validation = ["download": .object(["dateBasis": "published release schedule"])]
      let cifp = Self.version(.cifp)
      try await store.publish([nasr, cifp], records: [.fixture(nasr), .fixture(cifp)])
      let snapshot = try await store.snapshot()
      #expect(snapshot.versions[.nasr]?.id == nasr.id)
      #expect(snapshot.versions[.cifp]?.id == cifp.id)
      let sql = try store.database.sqlDatabase()
      let validation = try await sql.raw(
        "SELECT validation FROM source_versions WHERE id = \(bind: nasr.id)"
      ).first(decodingColumn: "validation", as: [String: Value].self)
      #expect(validation?["record_counts"]?.objectValue?["fixture"] == 1)
      #expect(validation?["download"] == nasr.validation?["download"])
      await #expect(throws: StorageError.self) {
        try await store.publish([Self.version(.nasr)], records: [])
      }
      let failedNASR = Self.version(.nasr)
      let failedCIFP = Self.version(.cifp)
      let ingestion = IngestionService(store: store)
      await #expect(throws: (any Error).self) {
        try await ingestion.ingest(
          source: "nasr+cifp", checksum: failedNASR.checksum, parserRevision: "fixture"
        ) {
          StagedImport(
            versions: [failedNASR, failedCIFP],
            records: [.fixture(failedNASR), .fixture(failedNASR), .fixture(failedCIFP)])
        }
      }
      #expect(
        try await IngestionRun.query(on: store.database).filter(\.$outcome == "failed").count() == 1
      )
      #expect(try await store.snapshot().token == snapshot.token)
      let metrics = try await DatabaseMetrics(database: store.database).render()
      #expect(
        metrics.contains("aviation_ingestion_runs{source=\"nasr+cifp\",outcome=\"failed\"} 1"))
    }
  }

  @Test
  func `reports spatial coverage limitations even when no boundary points match`() async throws {
    try await withDatabase { store in
      var nasr = Self.version(.nasr)
      nasr.validation = [
        "parse_errors": .object([
          "count": 1,
          "samples": .array([
            .object([
              "kind": "artcc_boundary", "record_id": "ZOA/missing", "message": "Invalid position"
            ])
          ])
        ])
      ]
      let cifp = Self.version(.cifp)
      var boundary = AviationRecord(
        versionID: nasr.id, kind: "artcc_boundary", id: "ZOA/1", identifier: "ZOA", name: "Oakland")
      boundary.geometry = Normalization.point(latitude: 38, longitude: -123)
      boundary.data["geometry_limitations"] = .array([
        "Boundary points do not define coverage polygons."
      ])
      try await store.publish([nasr, cifp], records: [boundary, .fixture(cifp)])
      let result = try await PeriodicQueries(store: store).search(
        kinds: ["artcc_boundary"], sources: [.nasr],
        arguments: ToolArguments(["latitude": 37, "longitude": -122, "radius_nm": 1]))
      #expect(result.results.isEmpty)
      #expect(result.completeness == "partial")
      #expect(result.warnings.contains { $0.contains("coverage polygons") })
      let unmatched = try await PeriodicQueries(store: store).search(
        kinds: ["artcc_boundary"], sources: [.nasr],
        arguments: ToolArguments(["identifier": "missing"]))
      #expect(unmatched.results.isEmpty)
      #expect(unmatched.completeness == "partial")
      #expect(unmatched.warnings.contains { $0.contains("could not be parsed") })
      let published = try await store.snapshot().versions[.nasr]
      #expect(published?.parseErrorCount == 1)
      #expect(published?.validation?["outcome"] == "partial")
    }
  }

  @Test
  func `preserves independent publications under concurrency`() async throws {
    try await withDatabase { store in
      let dof = Self.version(.dof)
      let aircraft = Self.version(.aircraft)
      async let first: Void = store.publish([dof], records: [.fixture(dof)])
      async let second: Void = store.publish([aircraft], records: [.fixture(aircraft)])
      _ = try await (first, second)
      let snapshot = try await store.snapshot()
      #expect(snapshot.versions[.dof]?.id == dof.id)
      #expect(snapshot.versions[.aircraft]?.id == aircraft.id)
    }
  }

  @Test
  func `orders obstacles by MSL and binds pagination to source versions`() async throws {
    try await withDatabase { store in
      try await Self.publishObstacles(store)
      let queries = PeriodicQueries(store: store)
      for context: [String: Value] in [
        ["airport": "KOAK", "radius_nm": 5],
        ["airport": "KOAK", "latitude": 37.7, "longitude": -122.2, "radius_nm": 5]
      ] {
        await #expect(throws: MCPError.self) {
          try await queries.search(
            kinds: ["obstacle"], sources: [.dof], arguments: ToolArguments(context))
        }
      }
      var args: [String: Value] = [
        "latitude": .double(37.7), "longitude": .double(-122.2),
        "radius_nm": 5, "order": "highest", "limit": 1
      ]
      let first = try await queries.search(
        kinds: ["obstacle"], sources: [.dof], arguments: ToolArguments(args))
      #expect(first.results.first?.objectValue?["identifier"]?.stringValue == "HIGH")
      args["cursor"] = .string(try #require(first.nextCursor))
      let second = try await queries.search(
        kinds: ["obstacle"], sources: [.dof], arguments: ToolArguments(args))
      #expect(second.results.first?.objectValue?["identifier"]?.stringValue == "LOW")
      try await Self.publishDepartureAirport(store)
      let departure = try await queries.search(
        kinds: ["obstacle"], sources: [.dof, .nasr],
        arguments: ToolArguments(["airport": "KOAK", "runway": "29", "radius_nm": 5]))
      #expect(departure.results.compactMap { $0.objectValue?["identifier"] } == ["HIGH", "LOW"])
      let highest = try #require(departure.results.first?.objectValue)
      #expect(highest["bearing_true_deg"] == 270)
      #expect((0.46...0.49).contains(try #require(highest["distance_nm"]?.doubleValue)))
      #expect(Set(departure.sources.map(\.source)) == ["dof", "nasr"])
      let circle = try await queries.search(
        kinds: ["obstacle"], sources: [.dof, .nasr],
        arguments: ToolArguments([
          "airport": "KOAK", "runway": "29", "radius_nm": 5, "departure_area": "circle"
        ]))
      #expect(circle.results.count == 3)
      let replacement = Self.version(.dof)
      try await store.publish([replacement], records: [.fixture(replacement)])
      let resumed = args
      await #expect(throws: StorageError.self) {
        try await queries.search(
          kinds: ["obstacle"], sources: [.dof], arguments: ToolArguments(resumed))
      }
    }
  }

  @Test
  func `admits only the shared burst under concurrent requests`() async throws {
    try await withDatabase { store in
      let admission = AdmissionLimiter(
        database: store.database, requestsPerMinute: 0.001, burst: 20)
      let outcomes = try await withThrowingTaskGroup(of: AdmissionDecision.self) { group in
        for _ in 0..<25 {
          group.addTask { try await admission.admit(key: "192.0.2.1") }
        }
        var decisions: [AdmissionDecision] = []
        for try await decision in group { decisions.append(decision) }
        return decisions
      }
      #expect(outcomes.filter(\.allowed).count == 20)
      #expect(outcomes.filter { !$0.allowed }.allSatisfy { $0.retryAfterSeconds > 0 })
      #expect(try await admission.admit(key: "192.0.2.2").allowed)
    }
  }

  @Test
  func `computes the short route across the antimeridian`() async throws {
    try await withDatabase { store in
      let geometry = GeometryTools(database: store.database)
      let result = try await geometry.compute(
        ToolArguments([
          "operation": "route", "coordinates": .array([.array([179, 0]), .array([-179, 0])])
        ]))
      let route = try #require(result.results.first?.objectValue)
      let distance = try #require(route["distance_nm"]?.doubleValue)
      #expect((120...121).contains(distance))
      #expect(route["geometry"]?.objectValue?["type"] == "MultiLineString")
    }
  }

}

extension `Transactional publication` {
  @Test
  func `resolves station coordinates from the active cycle without guessing ambiguous airports`()
    async throws
  {
    try await withDatabase { store in
      let nasr = Self.version(.nasr)
      let cifp = Self.version(.cifp)
      var airport = AviationRecord(
        versionID: nasr.id, kind: "airport", id: "OAK", identifier: "KOAK", name: "Oakland")
      airport.geometry = Normalization.point(latitude: 37.7, longitude: -122.2)
      try await store.publish([nasr, cifp], records: [airport, .fixture(cifp)])
      let query = try WeatherQuery(arguments: ToolArguments(["station": "KOAK"]))
      let resolved = try await WeatherLocation(store: store).resolve(query)
      #expect(resolved.latitude == 37.7)
      #expect(resolved.longitude == -122.2)
      #expect(resolved.locationSource?.cycle == nasr.cycle)
      let sql = try store.database.sqlDatabase()
      try await sql.raw(
        """
        INSERT INTO aviation_records (version_id, kind, id, identifier, name, data, geometry)
        SELECT version_id, kind, 'ambiguous', identifier, name, data,
          ST_SetSRID(ST_MakePoint(-123,38),4326)::geography
        FROM aviation_records WHERE id = 'OAK'
        """
      ).run()
      let ambiguous = try await WeatherLocation(store: store).resolve(query)
      #expect(ambiguous.latitude == nil)
      #expect(ambiguous.locationProblem != nil)
    }
  }

}

extension `Transactional publication` {
  @Test
  func `omits disabled domains and returns structured source availability errors`() async throws {
    try await withDatabase { store in
      let catalog = ToolCatalog(
        store: store, groups: [.airports, .status],
        weather: WeatherService(awc: nil, openMeteo: nil), notams: nil)
      #expect(Set(catalog.tools.map(\.name)) == ["find_airports", "get_airport", "get_data_status"])
      let result = try await catalog.call(
        .init(name: "get_airport", arguments: ["identifier": "KOAK"]))
      #expect(result.isError == true)
      #expect(result.structuredContent?.objectValue?["completeness"] == "unavailable")
      await #expect(throws: MCPError.self) {
        try await catalog.call(.init(name: "get_weather", arguments: ["station": "KOAK"]))
      }
      let versions = [Self.version(.nasr), Self.version(.cifp)]
      let airport = Self.airportWithMixedRunways(versions[0])
      let procedure = AviationRecord(
        versionID: versions[1].id, kind: "procedure", id: "I29",
        identifier: "I29", name: "ILS 29")
      try await store.publish(versions, records: [airport, procedure])
      let runwayFilter: [String: Value] = [
        "public_use": true, "facility_type": "AIRPORT",
        "minimum_runway_length_ft": 5000, "paved": true
      ]
      let filtered = try await catalog.call(.init(name: "find_airports", arguments: runwayFilter))
      #expect(filtered.structuredContent?.objectValue?["results"]?.arrayValue?.isEmpty == true)
      var unpaved = runwayFilter
      unpaved["paved"] = false
      let matching = try await catalog.call(.init(name: "find_airports", arguments: unpaved))
      #expect(matching.structuredContent?.objectValue?["results"]?.arrayValue?.count == 1)
      let spatial = try await catalog.call(
        .init(
          name: "find_airports",
          arguments: [
            "latitude": 37, "longitude": -122
          ]))
      #expect(spatial.isError == true)
      let mixed = try await PeriodicQueries(store: store).search(
        kinds: ["airport", "hold"], sources: [.nasr], arguments: ToolArguments([:]))
      #expect(mixed.results.count == 1)
      #expect(mixed.completeness == "partial")
      #expect(mixed.warnings.contains { $0.contains("hold") })
      await #expect(throws: StorageError.self) {
        try await PeriodicQueries(store: store).search(
          kinds: ["hold"], sources: [.nasr], arguments: ToolArguments([:]))
      }

    }
  }

}

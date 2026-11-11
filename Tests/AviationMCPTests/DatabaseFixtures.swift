import Fluent
import FluentPostgresDriver
import Foundation
import MCP
import SQLKit
import Testing
import VaporTesting

@testable import AviationMCP

actor ConnectionAttempts {
  private(set) var count = 0

  func advance() -> Int {
    count += 1
    return count
  }
}

/// Runs a task's jobs on an event loop, so the task leases that loop's pooled connections in place.
final class EventLoopTaskExecutor: TaskExecutor {
  let loop: any EventLoop

  init(_ loop: any EventLoop) {
    self.loop = loop
  }

  func enqueue(_ job: consuming ExecutorJob) {
    let job = UnownedJob(job)
    loop.execute { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
  }
}

extension AviationRecord {
  static func fixture(_ version: SourceVersion) -> Self {
    Self(
      versionID: version.id, kind: "fixture", id: "fixture", identifier: "FIXTURE", name: "Fixture")
  }
}

extension `Transactional publication` {
  struct IdentifierIndexState: Decodable {
    let oid: String
    let valid: Bool
  }

  static func identifierIndexState(_ sql: any SQLDatabase) async throws -> IdentifierIndexState {
    try #require(
      try await sql.raw(
        """
        SELECT indexrelid::text AS oid, indisvalid AS valid
        FROM pg_index WHERE indexrelid = 'aviation_faa_lid'::regclass
        """
      ).first(decoding: IdentifierIndexState.self))
  }

  static func makeInvalidIdentifierIndex(_ store: AviationStore) async throws -> any SQLDatabase {
    let nasr = Self.version(.nasr)
    let cifp = Self.version(.cifp)
    try await store.publish([nasr, cifp], records: [.fixture(nasr), .fixture(cifp)])
    let sql = try store.database.sqlDatabase()
    try await sql.raw("DROP INDEX aviation_faa_lid").run()
    await #expect(throws: (any Error).self) {
      try await sql.raw(
        "CREATE UNIQUE INDEX CONCURRENTLY aviation_faa_lid ON aviation_records(kind)"
      ).run()
    }
    return sql
  }

  static func publishObstacles(_ store: AviationStore) async throws {
    let version = Self.version(.dof)
    let position = Normalization.point(latitude: 37.7, longitude: -122.2)
    var low = AviationRecord(
      versionID: version.id, kind: "obstacle", id: "low", identifier: "LOW", name: "Low")
    low.elevationMSLFeet = 100
    low.heightAGLFeet = 90
    low.geometry = position
    var high = AviationRecord(
      versionID: version.id, kind: "obstacle", id: "high", identifier: "HIGH", name: "High")
    high.elevationMSLFeet = 200
    high.heightAGLFeet = 20
    high.geometry = position
    var behind = AviationRecord(
      versionID: version.id, kind: "obstacle", id: "behind", identifier: "BEHIND", name: "Behind")
    behind.elevationMSLFeet = 50
    behind.geometry = Normalization.point(latitude: 37.7, longitude: -122.18)
    try await store.publish([version], records: [low, high, behind])
  }

  /// Publishes KOAK with runway 29 departing west from a departure end 0.47 NM east of the
  /// obstacles.
  static func publishDepartureAirport(_ store: AviationStore) async throws {
    let nasr = Self.version(.nasr)
    let cifp = Self.version(.cifp)
    var airport = AviationRecord(
      versionID: nasr.id, kind: "airport", id: "OAK",
      identifier: "KOAK", name: "Oakland")
    airport.data["runways"] = .array([
      .object([
        "ends": .array([
          .object([
            "identifier": "29",
            "threshold": Normalization.point(latitude: 37.7, longitude: -122.17),
            "departure_end": Normalization.point(latitude: 37.7, longitude: -122.19)
          ])
        ])
      ])
    ])
    try await store.publish([nasr, cifp], records: [airport, .fixture(cifp)])
  }

  func withDatabase(_ operation: @Sendable (AviationStore) async throws -> Void) async throws {
    let url = try #require(ProcessInfo.processInfo.environment["TEST_DATABASE_URL"])
    try await withApp { app in
      app.databases.use(try .postgres(url: url), as: .psql)
      let sql = try app.db.sqlDatabase()
      try await Self.requireDisposableDatabase(sql)
      try await sql.raw("DROP SCHEMA public CASCADE").run()
      try await sql.raw("CREATE SCHEMA public").run()
      try await AviationSchema().prepare(on: app.db)
      try await IdentifierLookupIndex().prepare(on: app.db)
      try await SearchIndexes().prepare(on: app.db)
      try await operation(AviationStore(database: app.db))
    }
  }

  /// Refuses to reset any database whose name does not mark it as a test database.
  static func requireDisposableDatabase(_ sql: any SQLDatabase) async throws {
    struct CurrentDatabase: Decodable { let name: String }
    let database = try #require(
      try await sql.raw("SELECT current_database() AS name").first(decoding: CurrentDatabase.self))
    try #require(
      database.name.lowercased().contains("test"),
      "TEST_DATABASE_URL names \(database.name); its schema is reset only when the name contains “test”."
    )
  }

  private static let terminationTimeoutMilliseconds = 5000

  static func backendID(_ database: any Database) async throws -> Int32 {
    try #require(
      try await database.sqlDatabase().raw("SELECT pg_backend_pid() AS pid")
        .first(decodingColumn: "pid", as: Int32.self))
  }

  /// Holds `loop` while the server terminates `backend`, then runs `operation` on the loop before it
  /// reads the termination, as a process resuming from suspend finds a connection the server closed
  /// while it slept.
  static func resuming<Value: Sendable>(
    _ loop: any EventLoop, afterTerminating backend: Int32,
    _ operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    let release = DispatchSemaphore(value: 0)
    await withCheckedContinuation { held in
      loop.execute {
        held.resume()
        release.wait()
      }
    }
    do {
      try await terminate(backend, avoiding: loop)
    } catch {
      release.signal()
      throw error
    }
    let resumed = Task(executorPreference: EventLoopTaskExecutor(loop), operation: operation)
    release.signal()
    return try await resumed.value
  }

  /// Terminates its connection's backend after the first statement of its first run.
  static func terminatingFirstAttempt(
    counting attempts: ConnectionAttempts
  ) -> @Sendable (any Database) async throws -> Int32 {
    { database in
      let backend = try await backendID(database)
      if await attempts.advance() == 1 {
        try await terminate(backend, avoiding: database.eventLoop)
      }
      return try await backendID(database)
    }
  }

  private static func terminate(_ backend: Int32, avoiding loop: any EventLoop) async throws {
    let url = try #require(ProcessInfo.processInfo.environment["TEST_DATABASE_URL"])
    let other = try #require(
      MultiThreadedEventLoopGroup.singleton.makeIterator().first { $0 !== loop })
    let connection = try await PostgresConnection.connect(
      on: other, configuration: try SQLPostgresConfiguration(url: url).coreConfiguration, id: 0,
      logger: Logger(label: "terminate"))
    let terminated: Bool?
    do {
      terminated = try await connection.query(
        "SELECT pg_terminate_backend(\(backend), \(terminationTimeoutMilliseconds))",
        logger: connection.logger
      ).collect().first?.decode(Bool.self)
    } catch {
      try? await connection.close()
      throw error
    }
    try await connection.close()
    try #require(terminated == true, "The server did not terminate backend \(backend).")
  }

  static func version(_ source: SourceName) -> SourceVersion {
    let id = UUID()
    return SourceVersion(
      id: id, source: source, cycle: "fixture",
      effectiveFrom: Date(timeIntervalSince1970: 0),
      effectiveUntil: source == .aircraft ? nil : Date(timeIntervalSince1970: 4_000_000_000),
      checksum: Normalization.checksum(Data(id.uuidString.utf8)), parserRevision: "fixture",
      validated: true)
  }

  static func airportWithMixedRunways(_ version: SourceVersion) -> AviationRecord {
    var airport = AviationRecord(
      versionID: version.id, kind: "airport", id: "OAK", identifier: "KOAK", name: "Oakland")
    airport.data = [
      "public_use": true, "facility_type": "AIRPORT", "maximum_runway_length_ft": 10000,
      "runways": .array([
        .object(["length_ft": 10000, "paved": false]),
        .object(["length_ft": 1000, "paved": true])
      ])
    ]
    return airport
  }

  /// The mixed-runway airport with a paved runway 10L/28R as well. 28R publishes its elevation,
  /// heading, slope and declared distances; 10L publishes only its threshold, so its heading,
  /// slope and distances are derived.
  static func airportWithRunwayEnds(_ version: SourceVersion) -> AviationRecord {
    var airport = airportWithMixedRunways(version)
    airport.elevationMSLFeet = 9
    airport.geometry = Normalization.point(latitude: 37.72, longitude: -122.22)
    let east = Normalization.point(latitude: 37.70, longitude: -122.20)
    let west = Normalization.point(latitude: 37.71, longitude: -122.23)
    let runway: Value = .object([
      "identifier": "10L/28R", "length_ft": 10_000, "paved": true, "materials": ["ASPH"],
      "ends": [
        .object([
          "identifier": "28R", "threshold": east, "departure_end": west,
          "threshold_elevation_msl_ft": 6, "heading_true_deg": 295, "gradient_percent": 0.1,
          "tora_ft": 10_000, "toda_ft": 10_500, "lda_ft": 9_000
        ]),
        .object([
          "identifier": "10L", "threshold": west, "departure_end": east,
          "threshold_elevation_msl_ft": 16
        ])
      ]
    ])
    airport.data["runways"] = .array((airport.data["runways"]?.arrayValue ?? []) + [runway])
    return airport
  }
}

extension `Transactional publication` {
  static func prepareNOTAMs(on sql: any SQLDatabase) async throws {
    try await sql.raw(
      """
      CREATE TABLE notams(notam_id text, icao_location text, effective_start timestamptz,
        effective_end timestamptz, schedule text, notam_text text, scope text,
        updated_at timestamptz DEFAULT now(), q_line jsonb)
      """
    ).run()
    try await sql.raw(
      """
      CREATE TABLE ingestion_state(key text, value text, updated_at timestamptz DEFAULT now())
      """
    ).run()
    try await sql.raw(
      """
      INSERT INTO notams VALUES
        ('A','KSFO','2026-10-28','2026-10-30','DAILY 0800-1000','RWY 28L CLOSED','A',now(),NULL),
        ('B','KSFO','2026-10-28',NULL,NULL,'APRON CONSTRUCTION',NULL,now(),NULL),
        ('C','KSFO','2026-10-30',NULL,NULL,'FUTURE WORK','A',now(),NULL),
        ('D','ZOA','2026-10-28',NULL,NULL,'TEMPORARY FLIGHT RESTRICTIONS','W',now(),
          '{"coordinates":"3737N12223W"}'),
        ('E','ZOA','2026-10-28',NULL,NULL,'DISTANT AIRSPACE','W',now(),
          '{"coordinates":"4000N11500W"}')
      """
    ).run()
    let timestamp = ISO8601DateFormatter()
    timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    try await sql.raw(
      "INSERT INTO ingestion_state(key,value) VALUES ('last_poll_time',\(bind: timestamp.string(from: .now)))"
    ).run()
  }
}

import Fluent
import FluentPostgresDriver
import Foundation
import MCP
public import Vapor

/// Configures database pools, domain tools and the stateless MCP HTTP endpoint from the environment.
public func configure(_ app: Application) throws {
  if Environment.get("APP_ROLE") == "stage" {
    app.asyncCommands.use(StageDOFCommand(), as: "stage-dof")
    app.asyncCommands.use(StageAircraftCommand(), as: "stage-aircraft")
    app.asyncCommands.use(StageCIFPCommand(), as: "stage-cifp")
    app.asyncCommands.use(StageNASRCommand(), as: "stage-nasr")
    return
  }
  let settings = try ServerSettings()
  app.databases.use(
    try .postgres(
      url: settings.databaseURL, maxConnectionsPerEventLoop: 2,
      connectionPoolTimeout: .seconds(Int64(settings.databaseWaitSeconds)),
      pruneInterval: settings.role == "serve" ? .seconds(30) : nil,
      maxIdleTimeBeforePruning: .seconds(60)), as: .psql)
  app.migrations.add(AviationSchema())
  app.migrations.add(TerrainSchema())
  app.migrations.add(IdentifierLookupIndex())
  app.migrations.add(DropSupplementalRecords())
  guard settings.role == "serve" else {
    app.asyncCommands.use(RemoteIngestionCommand(), as: "ingest-sources")
    app.asyncCommands.use(PublishCommand(), as: "publish-bundle")
    app.asyncCommands.use(PurgeCommand(), as: "purge")
    app.asyncCommands.use(ImportTerrainCommand(), as: "import-terrain")
    return
  }
  app.http.server.configuration.hostname = "0.0.0.0"
  app.http.server.configuration.port = Environment.get("PORT").flatMap(Int.init) ?? 8080
  let store = AviationStore(database: app.db)
  let notams = try configureNOTAMs(app, settings: settings)
  let weather = configureWeather(app, settings: settings)
  let terrain =
    settings.groups.contains(.terrain)
    ? TerrainService(
      catalog: TerrainCatalog(database: app.db),
      worker: TerrainWorker(
        python: settings.terrainPython, script: settings.terrainScript,
        cacheDirectory: settings.terrainCacheDirectory, cacheBytes: settings.terrainCacheBytes))
    : nil
  let catalog = ToolCatalog(
    store: store, groups: settings.groups, weather: weather, notams: notams, terrain: terrain)
  registerMCP(app, catalog: catalog, settings: settings)
}

private func registerMCP(_ app: Application, catalog: ToolCatalog, settings: ServerSettings) {
  let metrics = ServerMetrics()
  app.middleware.use(
    AdmissionMiddleware(
      limiter: AdmissionLimiter(
        database: app.db,
        requestsPerMinute: settings.requestsPerMinute, burst: settings.burst),
      trustFlyProxy: Environment.get("FLY_APP_NAME") != nil,
      edgeIdentity: EdgeClientIdentity(secret: Environment.get("EDGE_PROXY_SECRET"))))
  MCPGateway(
    origins: settings.origins, timeout: .seconds(settings.timeout), tools: catalog.tools
  ) { parameters in
    let start = ContinuousClock.now
    do {
      let result = try await catalog.call(parameters)
      await metrics.record(
        tool: parameters.name, duration: start.duration(to: .now), failed: result.isError == true)
      return result
    } catch {
      await metrics.record(tool: parameters.name, duration: start.duration(to: .now), failed: true)
      throw error
    }
  }.register(on: app)
  registerOperations(app, store: catalog.store, groups: settings.groups, metrics: metrics)
}

private func configureWeather(_ app: Application, settings: ServerSettings) -> WeatherService {
  let cache = WeatherCache(database: app.db, freshness: settings.cacheSeconds)
  let http = WeatherHTTP(cache: cache, budgets: ProviderBudgets(database: app.db)) { request in
    try await app.client.send(request).get()
  }
  let providers = WeatherProviders(
    http: http, openMeteoEndpoint: settings.openMeteoEndpoint,
    openMeteoKey: settings.openMeteoKey, openMeteoLimits: settings.openMeteoLimits)
  let awc: WeatherService.Provider = { try await providers.awc($0) }
  let location = WeatherLocation(store: AviationStore(database: app.db))
  let openMeteo: WeatherService.Provider = { query in
    let resolved = try await location.resolve(query)
    var sample = try await providers.openMeteo(resolved.query)
    sample.sources = resolved.source.map { [$0] } ?? []
    return sample
  }
  return WeatherService(
    awc: settings.weatherSources.contains("awc") ? awc : nil,
    openMeteo: settings.weatherSources.contains("open_meteo")
      ? openMeteo : nil)
}

private func configureNOTAMs(_ app: Application, settings: ServerSettings) throws -> NOTAMQueries? {
  guard settings.groups.contains(.notams) else { return nil }
  guard let url = settings.notamDatabaseURL else {
    throw StorageError.invalidImport(
      "NOTAM_DATABASE_URL is required when the NOTAM domain is enabled.")
  }
  let id = DatabaseID(string: "notams")
  app.databases.use(
    try .postgres(
      url: url, maxConnectionsPerEventLoop: 1,
      connectionPoolTimeout: .seconds(5)), as: id)
  let notams = NOTAMQueries(database: app.db(id))
  app.lifecycle.use(NOTAMRoleCheck(queries: notams))
  return notams
}

func registerOperations(
  _ app: Application, store: AviationStore, groups: Set<DomainGroup>, metrics: ServerMetrics
) {
  let required = Set(
    ToolDefinition.allCases.filter { groups.contains($0.group) }.flatMap(\.periodicSources))
  app.get("health") { _ in ["status": "ok"] }
  app.get("ready") { _ async throws -> [String: String] in
    let snapshot = try await store.snapshot()
    var unavailable = required.subtracting(snapshot.versions.keys).map(\.rawValue)
    if groups.contains(.terrain) {
      let terrain = try await TerrainCatalog(database: store.database).status()
      if terrain.objectValue?["status"] != "available" {
        unavailable.append("terrain")
      }
    }
    return [
      "status": "ready", "data_status": unavailable.isEmpty ? "available" : "degraded",
      "unavailable_sources": unavailable.sorted().joined(separator: ",")
    ]
  }
  app.get("metrics") { _ async throws -> Vapor.Response in
    let snapshot = try await store.snapshot()
    var body = await metrics.render()
    body += try await DatabaseMetrics(database: app.db).render()
    for source in SourceName.allCases {
      body +=
        "aviation_source_available{source=\"\(source.rawValue)\"} \(snapshot.versions[source] == nil ? 0 : 1)\n"
    }
    return Vapor.Response(
      status: .ok, headers: ["Content-Type": "text/plain; version=0.0.4"], body: .init(string: body)
    )
  }
}

private struct NOTAMRoleCheck: LifecycleHandler {
  let queries: NOTAMQueries
  func willBootAsync(_ application: Application) async throws {
    try await queries.verifyReadOnlyRole()
  }
}

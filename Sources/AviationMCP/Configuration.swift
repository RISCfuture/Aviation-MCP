import Fluent
import FluentPostgresDriver
import Foundation
import MCP
import SQLKit
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
    try settings.postgres(connectionsPerEventLoop: settings.databaseConnectionsPerEventLoop),
    as: .psql)
  app.migrations.add(AviationSchema())
  app.migrations.add(TerrainSchema())
  app.migrations.add(IdentifierLookupIndex())
  app.migrations.add(SearchIndexes())
  guard settings.role == "serve" else {
    app.asyncCommands.use(RemoteIngestionCommand(), as: "ingest-sources")
    app.asyncCommands.use(PublishCommand(), as: "publish-bundle")
    app.asyncCommands.use(PurgeCommand(), as: "purge")
    app.asyncCommands.use(ImportTerrainCommand(), as: "import-terrain")
    return
  }
  app.http.server.configuration.hostname = "0.0.0.0"
  app.http.server.configuration.port = Environment.get("PORT").flatMap(Int.init) ?? 8080
  app.lifecycle.use(ServingRoleCheck(database: app.db))
  let store = AviationStore(database: app.db)
  let notams = try configureNOTAMs(app, settings: settings)
  let weather = try configureWeather(app, settings: settings)
  let terrain =
    settings.groups.contains(.terrain)
    ? TerrainService(
      catalog: TerrainCatalog(database: app.db),
      worker: TerrainWorker(
        python: settings.terrainPython, script: settings.terrainScript,
        cacheDirectory: settings.terrainCacheDirectory, cacheBytes: settings.terrainCacheBytes,
        logger: app.logger))
    : nil
  let catalog = ToolCatalog(
    store: store, groups: settings.groups, weather: weather, notams: notams, terrain: terrain)
  registerMCP(app, catalog: catalog, settings: settings)
}

private func registerMCP(_ app: Application, catalog: ToolCatalog, settings: ServerSettings) {
  let metrics = ServerMetrics()
  registerEdgeGate(app, settings: settings, metrics: metrics)
  app.middleware.use(
    AdmissionMiddleware(
      limiter: AdmissionLimiter(settings: settings.admission),
      clients: ClientAddressResolver(
        edgeIdentity: settings.edgeIdentity, trustFlyProxy: settings.runsOnFly)))
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

private func registerEdgeGate(
  _ app: Application, settings: ServerSettings, metrics: ServerMetrics
) {
  guard settings.runsOnFly else { return }
  guard settings.edgeIdentity.isConfigured else {
    app.logger.warning(
      "EDGE_PROXY_SECRET is not configured; the fly.dev origin accepts all requests")
    return
  }
  app.middleware.use(EdgeGateMiddleware(identity: settings.edgeIdentity, metrics: metrics))
}

private func configureWeather(
  _ app: Application, settings: ServerSettings
) throws -> WeatherService {
  app.databases.use(
    try settings.postgres(connectionsPerEventLoop: weatherConnectionsPerEventLoop), as: .weather)
  let cache = WeatherCache(database: app.db(.weather), freshness: settings.cacheSeconds)
  let budgets = ProviderBudgets(database: app.db(.weather))
  let http = WeatherHTTP(cache: cache, budgets: budgets) { request in
    try await app.client.send(request).get()
  }
  let providers = WeatherProviders(
    http: http, openMeteoEndpoint: settings.openMeteoEndpoint,
    openMeteoKey: settings.openMeteoKey, openMeteoLimits: settings.openMeteoLimits)
  let awc: WeatherService.Provider = { try await providers.awc($0) }
  let openMeteo: WeatherService.Provider = { try await providers.openMeteo($0) }
  let location = WeatherLocation(store: AviationStore(database: app.db))
  return WeatherService(
    awc: settings.weatherSources.contains("awc") ? awc : nil,
    openMeteo: settings.weatherSources.contains("open_meteo")
      ? openMeteo : nil,
    locate: { try await location.resolve($0) })
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
  _ app: Application, store: AviationStore, groups: Set<DomainGroup>, metrics: ServerMetrics,
  readinessLifetime: Duration = .seconds(30)
) {
  let readiness = ExpiringValue(lifetime: readinessLifetime) {
    try await readinessReport(store: store, groups: groups)
  }
  let databaseMetrics = TrafficGatedMetrics { try await databaseMetricsReport(store: store) }
  app.get("health") { _ in ["status": "ok"] }
  app.get("ready") { _ async throws -> [String: String] in try await readiness.current() }
  app.get("metrics") { _ async -> Vapor.Response in
    let body =
      await metrics.render()
      + (await databaseMetrics.render(afterCalls: await metrics.totalCalls))
    return Vapor.Response(
      status: .ok, headers: ["Content-Type": "text/plain; version=0.0.4"], body: .init(string: body)
    )
  }
}

private func readinessReport(store: AviationStore, groups: Set<DomainGroup>) async throws
  -> [String: String]
{
  let required = Set(
    ToolDefinition.allCases.filter { groups.contains($0.group) }.flatMap(\.periodicSources))
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

private func databaseMetricsReport(store: AviationStore) async throws -> String {
  let snapshot = try await store.snapshot()
  var body = try await DatabaseMetrics(database: store.database).render()
  for source in SourceName.allCases {
    body +=
      "aviation_source_available{source=\"\(source.rawValue)\"} \(snapshot.versions[source] == nil ? 0 : 1)\n"
  }
  return body
}

private struct NOTAMRoleCheck: LifecycleHandler {
  let queries: NOTAMQueries
  func willBootAsync(_ application: Application) async throws {
    try await queries.verifyReadOnlyRole()
  }
}

/// Refuses to serve when `DATABASE_URL` carries write or DDL privileges on aviation data.
private struct ServingRoleCheck: LifecycleHandler {
  let database: any Database

  func willBootAsync(_ application: Application) async throws {
    let privileged = try await database.sqlDatabase().raw(
      """
      SELECT has_table_privilege(current_user, 'aviation_records', 'INSERT,UPDATE,DELETE,TRUNCATE')
        OR has_schema_privilege(current_user, 'public', 'CREATE') AS privileged
      """
    ).first(decodingColumn: "privileged", as: Bool.self)
    guard privileged == false else {
      throw StorageError.invalidImport(
        "DATABASE_URL must use the serving role, which cannot modify aviation data.")
    }
  }
}

private let weatherConnectionsPerEventLoop = 2

extension DatabaseID {
  /// The pool for weather cache leases and provider budgets, kept apart from tool queries.
  fileprivate static let weather = DatabaseID(string: "weather")
}

extension ServerSettings {
  fileprivate func postgres(connectionsPerEventLoop: Int) throws -> DatabaseConfigurationFactory {
    try .postgres(
      url: databaseURL, maxConnectionsPerEventLoop: connectionsPerEventLoop,
      connectionPoolTimeout: .seconds(Int64(databaseWaitSeconds)),
      pruneInterval: role == "serve" ? .seconds(30) : nil,
      maxIdleTimeBeforePruning: .seconds(60))
  }
}

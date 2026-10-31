import Foundation
import Vapor

struct ServerSettings: Sendable {
  let terrainPython: String
  let terrainScript: String
  let terrainCacheDirectory: String
  let terrainCacheBytes: Int
  let role: String
  let databaseURL: String
  let databaseWaitSeconds: Double
  let databaseConnectionsPerEventLoop: Int
  let notamDatabaseURL: String?
  let groups: Set<DomainGroup>
  let weatherSources: Set<String>
  let origins: [String]
  let timeout: Double
  let admission: AdmissionSettings
  let edgeIdentity: EdgeClientIdentity
  let runsOnFly: Bool
  let cacheSeconds: Double
  let openMeteoEndpoint: String
  let openMeteoKey: String?
  let openMeteoLimits: [BudgetLimit]

  init() throws {
    terrainPython = Environment.get("TERRAIN_PYTHON") ?? "/opt/terrain/bin/python"
    terrainScript = Environment.get("TERRAIN_SCRIPT") ?? "/app/terrain/worker.py"
    terrainCacheDirectory =
      Environment.get("TERRAIN_CACHE_DIRECTORY") ?? "/tmp/aviation-terrain-cache"
    terrainCacheBytes = Int(
      try Self.number(
        "TERRAIN_CACHE_BYTES", default: 536_870_912, range: 1_048_576...21_474_836_480))
    role = Environment.get("APP_ROLE") ?? "serve"
    guard ["serve", "ingest"].contains(role) else { throw Self.invalid("APP_ROLE") }
    let databaseKey = role == "ingest" ? "INGEST_DATABASE_URL" : "DATABASE_URL"
    guard let url = Environment.get(databaseKey), !url.isEmpty else {
      throw Self.invalid(databaseKey)
    }
    databaseURL = url
    databaseWaitSeconds = try Self.number("DATABASE_WAIT_SECONDS", default: 15, range: 1...30)
    databaseConnectionsPerEventLoop = Int(
      try Self.number(
        "DATABASE_CONNECTIONS_PER_EVENT_LOOP", default: role == "serve" ? 6 : 2, range: 1...32))
    notamDatabaseURL = Environment.get("NOTAM_DATABASE_URL")
    let selectedGroups = Self.list("AVIATION_GROUPS", default: DomainGroup.allCases.map(\.rawValue))
    guard selectedGroups.allSatisfy({ DomainGroup(rawValue: $0) != nil }) else {
      throw Self.invalid("AVIATION_GROUPS")
    }
    groups = Set(selectedGroups.compactMap(DomainGroup.init(rawValue:)))
    weatherSources = Set(Self.list("WEATHER_SOURCES", default: ["awc", "open_meteo"]))
    guard weatherSources.isSubset(of: ["awc", "open_meteo"]) else {
      throw Self.invalid("WEATHER_SOURCES")
    }
    origins = Self.list("MCP_ALLOWED_ORIGINS", default: ["https://aviation-mcp.org"])
    timeout = try Self.number("MCP_TIMEOUT_SECONDS", default: 30, range: 1...60)
    admission = try Self.admission()
    edgeIdentity = EdgeClientIdentity(secret: Environment.get("EDGE_PROXY_SECRET"))
    runsOnFly = Environment.get("FLY_APP_NAME") != nil
    cacheSeconds = try Self.number("WEATHER_CACHE_SECONDS", default: 900, range: 1...86400)
    openMeteoEndpoint =
      Environment.get("OPEN_METEO_ENDPOINT") ?? "https://api.open-meteo.com/v1/forecast"
    openMeteoKey = Environment.get("OPEN_METEO_API_KEY")
    openMeteoLimits = try BudgetLimit.openMeteo.map { limit in
      BudgetLimit(
        period: limit.period,
        units: try Self.number(
          "OPEN_METEO_\(limit.period.rawValue.uppercased())_LIMIT", default: limit.units,
          range: 1...1_000_000_000))
    }
  }

  private static func admission() throws -> AdmissionSettings {
    let defaults = AdmissionSettings()
    let networks = list("CONNECTOR_EGRESS_RANGES", default: []).filter { !$0.isEmpty }
    let connectorNetworks = networks.compactMap { IPNetwork(cidr: $0) }
    guard connectorNetworks.count == networks.count else {
      throw invalid("CONNECTOR_EGRESS_RANGES")
    }
    return AdmissionSettings(
      client: try policy("PUBLIC", default: defaults.client),
      connector: try policy("CONNECTOR", default: defaults.connector),
      connectorNetworks: connectorNetworks,
      global: try rate("GLOBAL", default: defaults.global))
  }

  private static func policy(_ prefix: String, default fallback: AdmissionPolicy) throws
    -> AdmissionPolicy
  {
    AdmissionPolicy(
      rate: try rate(prefix, default: fallback.rate),
      concurrency: Int(
        try number(
          "\(prefix)_CONCURRENCY", default: Double(fallback.concurrency), range: 1...1_000)))
  }

  private static func rate(_ prefix: String, default fallback: AdmissionRate) throws
    -> AdmissionRate
  {
    AdmissionRate(
      requestsPerMinute: try number(
        "\(prefix)_RATE_PER_MINUTE", default: fallback.requestsPerMinute, range: 1...100_000),
      burst: try number("\(prefix)_RATE_BURST", default: fallback.burst, range: 1...10_000))
  }

  private static func list(_ key: String, default fallback: [String]) -> [String] {
    Environment.get(key).map {
      $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    } ?? fallback
  }

  private static func number(_ key: String, default fallback: Double, range: ClosedRange<Double>)
    throws -> Double
  {
    guard let text = Environment.get(key) else { return fallback }
    guard let value = Double(text), value.isFinite, range.contains(value) else {
      throw invalid(key)
    }
    return value
  }

  private static func invalid(_ key: String) -> StorageError {
    .invalidImport("Missing or invalid configuration: \(key).")
  }
}

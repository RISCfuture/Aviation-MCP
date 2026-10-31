import Foundation
import MCP

struct ToolCatalog: Sendable {
  let store: AviationStore
  let groups: Set<DomainGroup>
  let weather: WeatherService
  let notams: NOTAMQueries?
  var terrain: TerrainService?

  var tools: [Tool] { ToolDefinition.allCases.filter { groups.contains($0.group) }.map(\.tool) }

  func call(_ parameters: CallTool.Parameters) async throws -> CallTool.Result {
    guard let tool = ToolDefinition(rawValue: parameters.name), groups.contains(tool.group) else {
      throw MCPError.invalidParams("Unknown or disabled tool")
    }
    do {
      let arguments = ToolArguments(parameters.arguments)
      try ToolSchemas.validate(arguments, for: tool)
      return try await execute(tool, arguments: arguments).response()
    } catch let error as TerrainFailure {
      return try Self.failure("terrain_unavailable", message: error.reason)
    } catch let error as WeatherFailure {
      var details = try Value.encoded(error).objectValue ?? [:]
      details["code"] = "weather_unavailable"
      return try ToolResult(
        results: [], completeness: "unavailable",
        rateLimits: try error.rateLimits.map(Value.encoded), error: .object(details)
      ).response()
    } catch let error as ToolInputError {
      return try Self.failure("invalid_argument", message: error.reason)
    } catch MCPError.invalidParams(let message) {
      return try Self.failure("invalid_argument", message: message ?? "Invalid arguments.")
    } catch StorageError.expiredCursor {
      return try Self.failure(
        "cursor_expired", message: StorageError.expiredCursor.failureReason ?? "")
    } catch let error as StorageError {
      return try Self.failure(
        "data_unavailable", message: error.failureReason ?? "Data unavailable")
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as MCPError {
      throw error
    } catch {
      return try Self.failure("service_failure", message: "The request could not be completed.")
    }
  }

  private static func failure(_ code: String, message: String) throws -> CallTool.Result {
    try ToolResult(
      results: [], completeness: "unavailable",
      error: .object(["code": .string(code), "message": .string(message)])
    ).response()
  }

  private func execute(
    _ tool: ToolDefinition, arguments: ToolArguments
  ) async throws -> ToolResult {
    switch tool {
    case .getDataStatus: return try await status()
    case .queryTerrain:
      guard let terrain else { throw TerrainFailure(reason: "Terrain is not configured.") }
      return try await terrain.query(arguments)
    case .convertCoordinates: return try GeometryTools.convert(arguments)
    case .computeGeometry:
      return try await GeometryTools(database: store.database).compute(arguments)
    case .parseWeather: return try await WeatherParsing.parse(arguments)
    case .getWeather: return try await weather.weather(WeatherQuery(arguments: arguments))
    case .queryNOTAMs:
      guard let notams else {
        throw StorageError.invalidImport("The NOTAM database is not configured.")
      }
      return try await notams.search(arguments, area: NOTAMArea.resolve(arguments, store: store))
    default: return try await periodic(tool, arguments: arguments)
    }
  }

  private func periodic(
    _ tool: ToolDefinition, arguments: ToolArguments
  ) async throws -> ToolResult {
    let kinds = try arguments.strings("kinds") ?? tool.kinds
    guard !kinds.isEmpty, Set(kinds).isSubset(of: Set(tool.kinds)) else {
      throw MCPError.invalidParams("Unsupported record kinds")
    }
    var values = arguments.values
    if tool == .queryObstacles, values["order"] == nil { values["order"] = "highest" }
    // ProcedureExpansion selects the transition, so it can list every published one.
    if tool == .getProcedure { values["transition"] = nil }
    var sources = tool.periodicSources
    if tool == .queryObstacles {
      if values["runway"] != nil { sources.append(.nasr) }
      if values["procedure_id"] != nil { sources.append(.cifp) }
    }
    let result = try await PeriodicQueries(store: store).search(
      kinds: kinds,
      sources: sources, arguments: ToolArguments(values))
    return try Self.shape(result, for: tool, arguments: arguments)
  }

  private static func shape(
    _ found: ToolResult, for tool: ToolDefinition, arguments: ToolArguments
  ) throws -> ToolResult {
    var result = found
    switch tool {
    case .getAirway: result = try AirwayExpansion.apply(result, arguments: arguments)
    case .getProcedure:
      result = try ProcedureExpansion.apply(
        result, transition: arguments.string("transition"),
        includeGeometry: arguments.boolean("include_geometry") ?? false)
    case .findProcedures: result.results = result.results.map(ProcedureSummary.summary)
    default: break
    }
    if [.getAirport, .getAirway, .getProcedure].contains(tool), result.results.count > 1 {
      result.completeness = "partial"
      result.warnings.append(
        "The identifier matches several records; call again with record_id set to one candidate's id."
      )
    }
    return result
  }

  private func status() async throws -> ToolResult {
    let snapshot = try await store.snapshot()
    var values: [Value] = try SourceName.allCases.map { source in
      var value: [String: Value] = ["source": .string(source.rawValue)]
      if let version = snapshot.versions[source] {
        value["status"] = "available"
        value["coverage"] = version.parseErrorCount > 0 ? "partial" : "complete"
        value["version"] = try .encoded(SourceProvenance(version))
      } else {
        value["status"] = "unavailable"
        value["reason"] = snapshot.unavailability(of: source).map(Value.string)
      }
      value["nextVersion"] = try snapshot.next[source].map { try .encoded(SourceProvenance($0)) }
      return .object(value)
    }
    if groups.contains(.terrain) {
      values.append(try await TerrainCatalog(database: store.database).status())
    }
    let warnings = (Array(snapshot.versions.values) + Array(snapshot.next.values))
      .flatMap(\.coverageWarnings)
    return ToolResult(
      results: values, sources: snapshot.versions.values.map(SourceStamp.init),
      completeness: warnings.isEmpty ? "complete" : "partial", warnings: warnings)
  }
}

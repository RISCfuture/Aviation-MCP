import Foundation
import MCP

actor TerrainService {
  private let catalog: TerrainCatalog
  private let worker: TerrainWorker
  private var jobs: [String: Job] = [:]
  private var allowance = WorkerTimeAllowance()

  init(catalog: TerrainCatalog, worker: TerrainWorker) {
    self.catalog = catalog
    self.worker = worker
  }

  func query(_ arguments: ToolArguments) async throws -> ToolResult {
    let query = try TerrainQuery(arguments)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let key = Normalization.checksum(try encoder.encode(arguments.values))
    let waiter = UUID()
    let task: Task<ToolResult, any Error>
    if var job = jobs[key] {
      job.waiters.insert(waiter)
      jobs[key] = job
      task = job.task
    } else {
      guard jobs.isEmpty else {
        throw TerrainFailure(reason: "Terrain worker is busy; retry shortly.")
      }
      let client = RequestClient.key
      try requireAllowance(for: client)
      task = Task { try await self.perform(query, chargingTo: client) }
      jobs[key] = Job(task: task, waiters: [waiter])
    }
    defer { release(key, waiter: waiter) }
    return try await withTaskCancellationHandler {
      let result = try await task.value
      try Task.checkCancellation()
      return result
    } onCancel: {
      Task { await self.release(key, waiter: waiter) }
    }
  }

  private func requireAllowance(for client: IPNetwork?) throws {
    guard let client, let wait = allowance.wait(for: client, at: .now) else { return }
    let seconds = Int((wait / .seconds(1)).rounded(.up))
    throw TerrainFailure(
      reason: "This client has used its share of the terrain worker; retry in \(seconds) seconds.")
  }

  private func release(_ key: String, waiter: UUID) {
    guard var job = jobs[key], job.waiters.remove(waiter) != nil else { return }
    if job.waiters.isEmpty {
      job.task.cancel()
      jobs.removeValue(forKey: key)
    } else {
      jobs[key] = job
    }
  }

  private func perform(_ query: TerrainQuery, chargingTo client: IPNetwork?) async throws
    -> ToolResult
  {
    let start = ContinuousClock.now
    defer {
      if let client { allowance.charge(client, for: start.duration(to: .now), at: .now) }
    }
    return try await perform(query)
  }

  private func perform(_ query: TerrainQuery) async throws -> ToolResult {
    let request = try await catalog.request(query)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let input = try encoder.encode(request)
    guard input.count <= 2 * 1024 * 1024 else {
      throw TerrainFailure(reason: "Terrain corridor geometry exceeds the request limit.")
    }
    let data = try await worker.run(input)
    var value = try JSONDecoder().decode([String: Value].self, from: data)
    value["catalog"] = request["catalog"]
    value["route_distance_nm"] = request["route_distance_nm"]
    value["analyzed_half_width_m"] = request["half_width_m"]
    value["attribution"] =
      "Copernicus DEM 2021; European Union/ESA, DLR and Airbus. https://registry.opendata.aws/copernicus-dem/"
    let complete = value["coverage"]?.objectValue?["complete"] == true
    let unavailable = value["maximum"] == .null || value["maximum"] == nil
    var warnings = [
      "Native surface-model cells use all-touched coverage and a 0.2% plus 10 m corridor allowance. "
        + "This is not certified obstacle clearance.",
      "Buildings and vegetation may be included in the DEM; "
        + "current obstacle and NOTAM coverage is not part of this terrain result."
    ]
    if !complete {
      warnings.append(
        "Some terrain is unknown. The available maximum does not establish the maximum over the entire corridor."
      )
    }
    if query.climb != nil {
      warnings.append(
        "Climb comparison uses a conservative distance lower bound and supplied EGM2008 altitude/performance. "
          + "A not_established result is inconclusive, not proof that the aircraft cannot clear the terrain."
      )
    }
    return ToolResult(
      results: [.object(value)],
      completeness: complete ? "complete" : unavailable ? "unavailable" : "partial",
      warnings: warnings,
      error: unavailable
        ? .object([
          "code": "terrain_unavailable", "message": "No terrain maximum could be established."
        ]) : nil)
  }

  private struct Job {
    let task: Task<ToolResult, any Error>
    var waiters: Set<UUID>
  }
}

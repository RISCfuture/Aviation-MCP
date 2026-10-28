import Foundation
import Synchronization

#if canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

struct TerrainWorker: Sendable {
  let python: String
  let script: String
  let cacheDirectory: String
  let cacheBytes: Int

  func run(_ input: Data) async throws -> Data {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "aviation-terrain-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let request = directory.appendingPathComponent("request.json")
    let response = directory.appendingPathComponent("response.json")
    let errors = directory.appendingPathComponent("errors.txt")
    try input.write(to: request)
    try Data().write(to: errors)
    let errorHandle = try FileHandle(forWritingTo: errors)
    defer { try? errorHandle.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: python)
    process.arguments = [
      script, request.path, response.path, cacheDirectory, "--cache-bytes", String(cacheBytes)
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errorHandle
    var environment = ProcessInfo.processInfo.environment
    environment["OPENBLAS_NUM_THREADS"] = "1"
    environment["OMP_NUM_THREADS"] = "1"
    process.environment = environment
    let state = TerrainProcessState(process: process)
    let watchdog = Task {
      try await Task.sleep(for: .seconds(28))
      state.stop()
    }
    defer { watchdog.cancel() }
    let status: Int32 = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        state.start(continuation)
      }
    } onCancel: {
      state.stop()
    }
    try Task.checkCancellation()
    guard status == 0 else {
      let handle = try FileHandle(forReadingFrom: errors)
      defer { try? handle.close() }
      let message = String(data: try handle.read(upToCount: 2048) ?? Data(), encoding: .utf8) ?? ""
      throw TerrainFailure(
        reason: message.isEmpty ? "Terrain worker exceeded its runtime or memory limit." : message)
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: response.path)
    guard let size = attributes[.size] as? NSNumber, size.intValue <= 1_048_576 else {
      throw TerrainFailure(reason: "Terrain response exceeded the payload limit.")
    }
    return try Data(contentsOf: response)
  }
}

private final class TerrainProcessState: Sendable {
  private let state: Mutex<State>

  init(process: Process) { state = Mutex(State(process: process)) }

  func start(_ continuation: CheckedContinuation<Int32, any Error>) {
    state.withLock { state in
      guard !state.stopped else {
        continuation.resume(throwing: CancellationError())
        return
      }
      state.process.terminationHandler = { process in
        continuation.resume(returning: process.terminationStatus)
      }
      do { try state.process.run() } catch { continuation.resume(throwing: error) }
    }
  }

  func stop() {
    state.withLock { state in
      state.stopped = true
      if state.process.isRunning { _ = kill(state.process.processIdentifier, SIGKILL) }
    }
  }

  private struct State {
    let process: Process
    var stopped = false
  }
}

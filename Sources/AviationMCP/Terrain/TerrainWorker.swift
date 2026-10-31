import Foundation
import Logging
import Synchronization

#if canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

struct TerrainWorker: Sendable {
  /// Marks a stderr line the worker wrote for clients; every other line stays in the server log.
  static let clientMessagePrefix = "aviation-terrain-error: "
  private static let errorReadLimit = 16_384

  let python: String
  let script: String
  let cacheDirectory: String
  let cacheBytes: Int
  var logger = Logger(label: "aviation-mcp.terrain")

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
    guard status == 0 else { throw failure(stderr: try Self.text(of: errors), status: status) }
    let attributes = try FileManager.default.attributesOfItem(atPath: response.path)
    guard let size = attributes[.size] as? NSNumber, size.intValue <= 1_048_576 else {
      throw TerrainFailure(reason: "Terrain response exceeded the payload limit.")
    }
    return try Data(contentsOf: response)
  }

  /// Returns the worker's client message when it wrote one, and otherwise logs the diagnostics and
  /// returns a generic reason.
  func failure(stderr: String, status: Int32) -> TerrainFailure {
    let lines = stderr.split(whereSeparator: \.isNewline)
    if let line = lines.last(where: { $0.hasPrefix(Self.clientMessagePrefix) }) {
      return TerrainFailure(reason: String(line.dropFirst(Self.clientMessagePrefix.count)))
    }
    guard !stderr.isEmpty else {
      return TerrainFailure(reason: "Terrain worker exceeded its runtime or memory limit.")
    }
    logger.error(
      "Terrain worker failed", metadata: ["status": "\(status)", "stderr": .string(stderr)])
    return TerrainFailure(reason: "Terrain worker failed unexpectedly.")
  }

  private static func text(of file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: errorReadLimit) ?? Data()
    return String(bytes: data, encoding: .utf8) ?? "Terrain worker wrote undecodable diagnostics."
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

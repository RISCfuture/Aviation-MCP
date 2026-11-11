public import Vapor

/// Receives errors that indicate code defects.
public protocol ErrorReporter: Sendable {
  /// Reports `error` with indexed `tags` and unindexed `context`.
  func report(_ error: any Error, tags: [String: String], context: [String: String])
  /// Sends queued events, waiting at most `timeout`.
  func flush(timeout: Duration)
  /// Flushes and shuts the reporter down; later reports are dropped.
  func close()
}

/// An ``ErrorReporter`` that discards everything.
public struct DisabledErrorReporter: ErrorReporter {
  public init() {}
  public func report(_ error: any Error, tags: [String: String], context: [String: String]) {}
  public func flush(timeout: Duration) {}
  public func close() {}
}

private struct ErrorReporterKey: StorageKey {
  typealias Value = any ErrorReporter
}

extension Application {
  /// The reporter for code defects; discards reports until one is assigned.
  public var errorReporter: any ErrorReporter {
    get { storage[ErrorReporterKey.self] ?? DisabledErrorReporter() }
    set { storage[ErrorReporterKey.self] = newValue }
  }
}

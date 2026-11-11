#if Sentry
  import CSentry
  import Synchronization
  import Vapor

  /// Reports defects through sentry-native, whose in-process backend stores crashes for the next
  /// start to send.
  final class SentryReporter: ErrorReporter {
    private static let shutdownTimeout: Duration = .seconds(5)
    private static let fallbackDatabasePath = "/tmp/aviation-sentry"

    private let closed = Mutex(false)

    /// Initializes sentry-native, returning `nil` if it fails to start.
    ///
    /// When the database at `SENTRY_DATABASE_PATH` can't be used, retries once with a database
    /// in `/tmp`, so reporting still starts, though crashes stored there don't survive a restart.
    init?(dsn: String, role: String, command: String?) {
      guard Self.start(dsn: dsn) else { return nil }
      unsafe sentry_set_tag("app_role", role)
      if let command { unsafe sentry_set_tag("command", command) }
    }

    func report(_ error: any Error, tags: [String: String], context: [String: String]) {
      let exception = unsafe sentry_value_new_exception(
        String(reflecting: type(of: error)), String(reflecting: error))
      sentry_value_set_stacktrace(exception, nil, 0)
      let event = sentry_value_new_event()
      sentry_event_add_exception(event, exception)
      unsafe sentry_value_set_by_key(event, "tags", Self.object(tags))
      unsafe sentry_value_set_by_key(event, "extra", Self.object(context))
      sentry_capture_event(event)
    }

    func flush(timeout: Duration) {
      sentry_flush(Self.milliseconds(timeout))
    }

    func close() {
      let wasClosed = closed.withLock { closed in
        defer { closed = true }
        return closed
      }
      if !wasClosed { sentry_close() }
    }

    private static func start(dsn: String) -> Bool {
      let configured = Environment.get("SENTRY_DATABASE_PATH") ?? fallbackDatabasePath
      if start(dsn: dsn, databasePath: configured) { return true }
      guard configured != fallbackDatabasePath else { return false }
      Logger(label: "aviation-mcp.error-reporting").warning(
        "Sentry could not use its database; storing it in \(fallbackDatabasePath) instead.",
        metadata: ["path": "\(configured)"])
      return start(dsn: dsn, databasePath: fallbackDatabasePath)
    }

    private static func start(dsn: String, databasePath: String) -> Bool {
      unsafe sentry_init(options(dsn: dsn, databasePath: databasePath)) == 0
    }

    private static func options(dsn: String, databasePath: String) -> OpaquePointer? {
      let options = unsafe sentry_options_new()
      unsafe sentry_options_set_dsn(options, dsn)
      if let release = Environment.get("SENTRY_RELEASE"), !release.isEmpty {
        unsafe sentry_options_set_release(options, release)
      }
      unsafe sentry_options_set_environment(
        options, Environment.get("SENTRY_ENVIRONMENT") ?? "development")
      unsafe sentry_options_set_database_path(options, databasePath)
      unsafe sentry_options_set_shutdown_timeout(options, milliseconds(shutdownTimeout))
      return unsafe options
    }

    private static func object(_ fields: [String: String]) -> sentry_value_t {
      fields.reduce(into: sentry_value_new_object()) { object, field in
        unsafe sentry_value_set_by_key(object, field.key, sentry_value_new_string(field.value))
      }
    }

    private static func milliseconds(_ duration: Duration) -> UInt64 {
      UInt64(max(0, duration / .milliseconds(1)))
    }
  }
#endif

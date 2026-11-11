#if Sentry
  import CSentry
  import Synchronization
  import Vapor

  /// Reports defects through sentry-native, whose crashpad handler also uploads crashes.
  final class SentryReporter: ErrorReporter {
    private static let handlerPath = "/app/crashpad_handler"
    private static let shutdownTimeout: Duration = .seconds(5)

    private let closed = Mutex(false)

    /// Initializes sentry-native, returning `nil` if it fails to start.
    init?(dsn: String, role: String, command: String?) {
      guard unsafe sentry_init(Self.options(dsn: dsn)) == 0 else { return nil }
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

    private static func options(dsn: String) -> OpaquePointer? {
      let options = unsafe sentry_options_new()
      unsafe sentry_options_set_dsn(options, dsn)
      if let release = Environment.get("SENTRY_RELEASE"), !release.isEmpty {
        unsafe sentry_options_set_release(options, release)
      }
      unsafe sentry_options_set_environment(
        options, Environment.get("SENTRY_ENVIRONMENT") ?? "development")
      unsafe sentry_options_set_database_path(
        options, Environment.get("SENTRY_DATABASE_PATH") ?? "/tmp/aviation-sentry")
      unsafe sentry_options_set_handler_path(options, handlerPath)
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

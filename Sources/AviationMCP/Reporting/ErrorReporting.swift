import Vapor

/// Creates the process's ``ErrorReporter``.
public enum ErrorReporting {
  /// Starts reporting to Sentry when the build includes the `Sentry` trait and `SENTRY_DSN` is
  /// set; otherwise returns a ``DisabledErrorReporter``.
  ///
  /// - Parameters:
  ///   - role: The `APP_ROLE`, tagged on every event as `app_role`.
  ///   - command: The command being run, if named, tagged on every event as `command`.
  public static func start(role: String, command: String?) -> any ErrorReporter {
    #if Sentry
      guard let dsn = Environment.get("SENTRY_DSN"), !dsn.isEmpty else {
        return DisabledErrorReporter()
      }
      if let reporter = SentryReporter(dsn: dsn, role: role, command: command) { return reporter }
      Logger(label: "aviation-mcp.error-reporting")
        .warning("Sentry failed to initialize; error reporting is disabled.")
    #endif
    return DisabledErrorReporter()
  }
}

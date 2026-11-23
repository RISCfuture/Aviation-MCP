import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

enum SourceChecks {
  /// How many times a request is attempted before a transient failure is reported.
  private static let maxAttempts = 3
  private static let retryDelay: Duration = .seconds(15)
  private static let requestTimeout: TimeInterval = 45
  private static let transientURLErrors: Set<Int> = Set(
    [
      URLError.Code.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
      .dnsLookupFailed, .notConnectedToInternet
    ].map(\.rawValue))

  static func check(_ source: String, at instant: Date = .now) async throws -> [SourceDownload] {
    let candidates: [SourceDownload]
    switch source {
    case "nasr", "cifp":
      candidates = try SourceDiscovery.navigation(source, at: instant)
    case "dof":
      let (data, _) = try await request(SourceDiscovery.obstacleSchedule, method: "GET")
      guard let html = String(data: data, encoding: .utf8) else {
        throw SourceDiscoveryError("FAA DOF schedule is not UTF-8.")
      }
      candidates = try SourceDiscovery.obstacles(html, at: instant)
    case "aircraft":
      let (_, response) = try await request(SourceDiscovery.aircraftWorkbook, method: "HEAD")
      guard let modified = response.value(forHTTPHeaderField: "Last-Modified") else {
        throw SourceDiscoveryError("FAA aircraft workbook has no snapshot timestamp.")
      }
      candidates = [try SourceDiscovery.aircraft(lastModified: modified)]
    default:
      throw SourceDiscoveryError("Unknown source: \(source).")
    }
    var available: [SourceDownload] = []
    for var candidate in candidates {
      let (_, response) = try await request(candidate.url, method: "HEAD", allowMissing: true)
      if response.statusCode == 404, candidate.effectiveFrom > instant.ISO8601Format() { continue }
      guard [200, 206].contains(response.statusCode) else {
        throw SourceDiscoveryError("Source \(candidate.url) returned HTTP \(response.statusCode).")
      }
      candidate.etag = response.value(forHTTPHeaderField: "ETag")
      candidate.lastModified = response.value(forHTTPHeaderField: "Last-Modified")
      available.append(candidate)
    }
    return available
  }

  /// Requests `address`, retrying timeouts, dropped connections and server errors.
  private static func request(
    _ address: String, method: String, allowMissing: Bool = false, attempt: Int = 1
  ) async throws -> (Data, HTTPURLResponse) {
    do {
      return try await attemptRequest(address, method: method, allowMissing: allowMissing)
    } catch let error where attempt < maxAttempts && isTransient(error) {
      try await Task.sleep(for: retryDelay)
      return try await request(
        address, method: method, allowMissing: allowMissing, attempt: attempt + 1)
    }
  }

  private static func isTransient(_ error: any Error) -> Bool {
    if let error = error as? ServerError { return error.isTransient }
    let error = error as NSError
    return error.domain == NSURLErrorDomain && transientURLErrors.contains(error.code)
  }

  private static func attemptRequest(
    _ address: String, method: String, allowMissing: Bool, rangeProbe: Bool = false
  ) async throws -> (Data, HTTPURLResponse) {
    guard let url = URL(string: address) else { throw SourceDiscoveryError("Invalid source URL.") }
    var request = URLRequest(url: url, timeoutInterval: requestTimeout)
    request.httpMethod = method
    if rangeProbe { request.setValue("bytes=0-0", forHTTPHeaderField: "Range") }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw SourceDiscoveryError("Source did not return HTTP metadata: \(address).")
    }
    if method == "HEAD", [405, 501, 503].contains(response.statusCode) {
      return try await attemptRequest(
        address, method: "GET", allowMissing: allowMissing, rangeProbe: true)
    }
    guard
      response.statusCode == 200 || (rangeProbe && response.statusCode == 206)
        || (allowMissing && response.statusCode == 404)
    else {
      throw ServerError(address: address, statusCode: response.statusCode)
    }
    return (data, response)
  }
}

/// A source server answered with an unexpected HTTP status.
private struct ServerError: LocalizedError {
  let address: String
  let statusCode: Int

  var errorDescription: String? { "Source check failed for \(address): HTTP \(statusCode)." }

  /// Whether the status is a server-side failure that a later attempt may not repeat.
  var isTransient: Bool { (500..<600).contains(statusCode) }
}

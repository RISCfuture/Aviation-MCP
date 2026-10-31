import Crypto
import Foundation
import Vapor

/// Verifies the client address the Cloudflare Worker signs into each proxied request.
struct EdgeClientIdentity: Sendable {
  let secret: String?

  var isConfigured: Bool { secret.map { $0.utf8.count >= 32 } ?? false }

  func verifiedIP(headers: HTTPHeaders, now: Date = Date()) -> String? {
    guard let secret, isConfigured,
      let address = headers.first(name: "X-Aviation-Client-IP"), !address.isEmpty,
      address.utf8.count <= 45,
      address.utf8.allSatisfy({
        (48...57).contains($0) || (65...70).contains($0)
          || (97...102).contains($0) || $0 == 46 || $0 == 58
      }),
      let timestamp = headers.first(name: "X-Aviation-Client-Time"),
      timestamp.count <= 12, let seconds = Double(timestamp), seconds.isFinite,
      abs(now.timeIntervalSince1970 - seconds) <= 60,
      let encoded = headers.first(name: "X-Aviation-Client-Signature"), encoded.count == 44,
      let signature = Data(base64Encoded: encoded),
      HMAC<SHA256>.isValidAuthenticationCode(
        signature, authenticating: Data("\(timestamp)\n\(address)".utf8),
        using: SymmetricKey(data: Data(secret.utf8)))
    else { return nil }
    return address
  }
}

/// Determines which client a request is charged to.
struct ClientAddressResolver: Sendable {
  let edgeIdentity: EdgeClientIdentity
  let trustFlyProxy: Bool

  /// The edge-signed address, then Fly's client address when running behind Fly, then the socket
  /// peer.
  func address(of request: Request) -> IPAddress? {
    let text =
      edgeIdentity.verifiedIP(headers: request.headers)
      ?? (trustFlyProxy ? request.headers.first(name: FlyProxy.clientIPHeader) : nil)
      ?? request.remoteAddress?.ipAddress
    return text.flatMap(IPAddress.init)
  }
}

enum FlyProxy {
  /// Set by Fly's public proxy on every request it forwards, and absent from health checks and
  /// metrics scrapes that reach the machine over the private network.
  static let clientIPHeader = "Fly-Client-IP"
}

/// Rejects requests that reached the machine through Fly's public proxy without a valid edge
/// signature, so the public `fly.dev` hostname cannot bypass Cloudflare.
///
/// `/health` stays open: it touches nothing and is the Fly health-check path.
struct EdgeGateMiddleware: AsyncMiddleware {
  let identity: EdgeClientIdentity
  let metrics: ServerMetrics

  func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
    guard request.url.path != "/health",
      request.headers.contains(name: FlyProxy.clientIPHeader),
      identity.verifiedIP(headers: request.headers) == nil
    else { return try await next.respond(to: request) }
    await metrics.recordEdgeRejection()
    request.logger.warning(
      "Rejected a proxied request without a valid edge signature",
      metadata: ["path": .string(request.url.path)])
    return Response(
      status: .forbidden, headers: ["Content-Type": "application/json"],
      body: .init(string: "{\"error\":\"edge_required\"}"))
  }
}

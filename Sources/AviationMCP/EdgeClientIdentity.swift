import Crypto
import Foundation
import Vapor

struct EdgeClientIdentity: Sendable {
  let secret: String?

  func verifiedIP(headers: HTTPHeaders, now: Date = Date()) -> String? {
    guard let secret, secret.utf8.count >= 32,
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

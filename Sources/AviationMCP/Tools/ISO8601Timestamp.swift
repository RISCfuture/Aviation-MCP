import Foundation

enum ISO8601Timestamp {
  static func parse(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text)
  }
}

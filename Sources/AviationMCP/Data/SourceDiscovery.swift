import Foundation

struct SourceDownload: Codable, Sendable {
  let source: String
  let cycle: String
  let url: String
  let effectiveFrom: String
  let effectiveUntil: String?
  let dateBasis: String
  var etag: String?
  var lastModified: String?
}

struct SourceDiscoveryError: LocalizedError {
  let errorDescription: String?

  init(_ message: String) { errorDescription = message }
}

enum SourceDiscovery {
  /// The FAA's changeover time for aeronautical information: 0901Z on the effective date.
  static let changeover: TimeInterval = 9 * 3600 + 60
  /// The FAA's interval between DOF releases.
  static let obstacleCadence: TimeInterval = 56 * 86400
  static let obstacleSchedule =
    "https://www.faa.gov/air_traffic/flight_info/aeronav/digital_products/dof/"
  static let aircraftWorkbook =
    "https://www.faa.gov/airports/engineering/aircraft_char_database/aircraft_data"

  static func navigation(_ source: String, at instant: Date) throws -> [SourceDownload] {
    guard ["nasr", "cifp"].contains(source) else {
      throw SourceDiscoveryError("Unknown navigation source: \(source).")
    }
    let reference = try date("2020-12-03", format: "yyyy-MM-dd").addingTimeInterval(changeover)
    let duration: TimeInterval = 28 * 86400
    let start = reference.addingTimeInterval(
      floor(instant.timeIntervalSince(reference) / duration) * duration)
    return [start, start.addingTimeInterval(duration)].map { start in
      let cycle = String(start.ISO8601Format().prefix(10))
      let name = formatter(source == "nasr" ? "dd_MMM_yyyy" : "yyMMdd").string(from: start)
      let url =
        source == "nasr"
        ? "https://nfdc.faa.gov/webContent/28DaySub/extra/\(name)_CSV.zip"
        : "https://aeronav.faa.gov/Upload_313-d/cifp/CIFP_\(name).zip"
      return SourceDownload(
        source: source, cycle: cycle, url: url, effectiveFrom: start.ISO8601Format(),
        effectiveUntil: start.addingTimeInterval(duration).ISO8601Format(),
        dateBasis: "FAA 28-day effective cycle")
    }
  }

  static func obstacles(_ html: String, at instant: Date) throws -> [SourceDownload] {
    let schedule = try obstacleReleases(html)
    let following: [Date?] = schedule.dropFirst().map(\.release) + [nil]
    let candidates = zip(schedule, following).compactMap { current, next -> SourceDownload? in
      let until = next ?? current.release.addingTimeInterval(obstacleCadence)
      guard let url = current.url, until > instant else { return nil }
      return SourceDownload(
        source: "dof", cycle: String(current.release.ISO8601Format().prefix(10)), url: url,
        effectiveFrom: current.release.ISO8601Format(), effectiveUntil: until.ISO8601Format(),
        dateBasis: obstacleSchedule)
    }
    guard !candidates.isEmpty else {
      throw SourceDiscoveryError(missingObstacleRelease(schedule, at: instant))
    }
    return Array(candidates.prefix(2))
  }

  static func aircraft(lastModified: String) throws -> SourceDownload {
    let modified = try date(lastModified, format: "EEE, dd MMM yyyy HH:mm:ss zzz")
    return SourceDownload(
      source: "aircraft", cycle: "FAA-ACD-" + String(modified.ISO8601Format().prefix(10)),
      url: aircraftWorkbook, effectiveFrom: modified.ISO8601Format(), effectiveUntil: nil,
      dateBasis: "HTTP Last-Modified snapshot timestamp; publication time not supplied",
      lastModified: lastModified)
  }

  private static func obstacleReleases(_ html: String) throws -> [(release: Date, url: String?)] {
    var schedule: [(release: Date, url: String?)] = []
    for row in try captures(#"(?is)<tr\b[^>]*>(.*?)</tr>"#, in: html) {
      let cells = try captures(#"(?is)<td\b[^>]*>(.*?)</td>"#, in: row)
      guard cells.count == 4, cells[0].contains("DOF") else { continue }
      let release = try date(
        cells[3].replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
          .trimmingCharacters(in: .whitespacesAndNewlines), format: "MMMM dd, yyyy")
      let url = try captures(
        #"href="(https://aeronav\.faa\.gov/Obst_Data/DOF_[0-9]{6}\.zip)""#, in: cells[0]
      ).first
      schedule.append((release, url))
    }
    return schedule.sorted { $0.release < $1.release }
  }

  private static func missingObstacleRelease(
    _ schedule: [(release: Date, url: String?)], at instant: Date
  ) -> String {
    guard let overdue = schedule.last(where: { $0.url == nil && $0.release <= instant }) else {
      return "FAA DOF schedule has no current download with published bounds."
    }
    return "The FAA has not yet posted the DOF release scheduled for "
      + "\(overdue.release.ISO8601Format()); the previous release expired at that time."
  }

  private static func captures(_ pattern: String, in text: String) throws -> [String] {
    try NSRegularExpression(pattern: pattern).matches(
      in: text, range: NSRange(text.startIndex..., in: text)
    ).compactMap { match in Range(match.range(at: 1), in: text).map { String(text[$0]) } }
  }

  private static func formatter(_ format: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = format
    formatter.isLenient = false
    return formatter
  }

  private static func date(_ text: String, format: String) throws -> Date {
    guard let date = formatter(format).date(from: text) else {
      throw SourceDiscoveryError("Unrecognized source date: \(text).")
    }
    return date
  }
}

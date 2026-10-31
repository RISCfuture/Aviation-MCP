import Foundation
import MCP
import SwiftMETAR

/// Selects METARs and TAFs from the Aviation Weather Center for a named station, falling back to
/// the nearest reporting station within ``StationSearchArea/radiusNM``.
struct AviationWeatherCenter: Sendable {
  /// Hours of METAR history to request: enough for every report that can cover the past hour.
  private static let observationHistoryHours = 2
  private static let endpoint = "https://aviationweather.gov/api/data/"

  let http: WeatherHTTP
  let limits: [BudgetLimit]

  func sample(_ query: WeatherQuery) async throws -> WeatherSample {
    var diagnostics = ImportDiagnostics()
    let direct = query.directStation
    if let direct,
      var sample = try await sample(for: query, from: .station(direct), diagnostics: &diagnostics)
    {
      sample.parsingGaps = Self.parsingGaps(diagnostics)
      return sample
    }
    if let area = StationSearchArea(query),
      var sample = try await sample(for: query, from: .area(area), diagnostics: &diagnostics)
    {
      sample.parsingGaps = Self.parsingGaps(diagnostics)
      sample.warnings.insert(Self.nearbyWarning(sample, instead: direct), at: 0)
      return sample
    }
    throw WeatherFailure(
      provider: "awc", reason: Self.unavailableReason(query),
      parsingGaps: Self.parsingGaps(diagnostics))
  }

  /// Uses the latest covering METAR alongside the covering TAF for recent times, and the covering
  /// TAF alone otherwise.
  private func sample(
    for query: WeatherQuery, from scope: Scope, diagnostics: inout ImportDiagnostics
  ) async throws -> WeatherSample? {
    if query.isRecent,
      let observation = try await observation(scope, at: query.instant, diagnostics: &diagnostics)
    {
      var sample = try AviationReports.sample(
        metar: observation.report, at: query.instant, retrievedAt: observation.retrievedAt)
      sample.reports = [observation.describe(WeatherParsing.metar(observation.report))]
      sample.reportingStation = observation.stationValue
      return try await appendingForecast(
        to: sample, from: scope, at: query.instant, diagnostics: &diagnostics)
    }
    guard let forecast = try await forecast(scope, at: query.instant, diagnostics: &diagnostics)
    else { return nil }
    var sample = try AviationReports.sample(
      taf: forecast.report, at: query.instant, retrievedAt: forecast.retrievedAt)
    sample.reports = [forecast.describe(WeatherParsing.taf(forecast.report))]
    sample.reportingStation = forecast.stationValue
    return sample
  }

  private func appendingForecast(
    to sample: WeatherSample, from scope: Scope, at instant: Date,
    diagnostics: inout ImportDiagnostics
  ) async throws -> WeatherSample {
    var sample = sample
    do {
      if let forecast = try await forecast(scope, at: instant, diagnostics: &diagnostics) {
        sample.reports.append(forecast.describe(WeatherParsing.taf(forecast.report)))
      } else {
        sample.warnings.append("No terminal forecast (TAF) covers the requested time.")
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let reason = (error as? WeatherFailure)?.reason ?? "The request failed."
      sample.warnings.append("The terminal forecast (TAF) could not be retrieved: \(reason)")
    }
    return sample
  }

  private func observation(
    _ scope: Scope, at instant: Date, diagnostics: inout ImportDiagnostics
  ) async throws -> Located<METAR>? {
    let fetched = try await fetch(.metar, from: scope, at: instant)
    var candidates: [Located<METAR>] = []
    for entry in fetched.entries {
      do {
        let report = try await METAR.from(
          string: try Product.metar.text(of: entry), on: fetched.retrievedAt,
          lenientRemarks: true)
        let lifetime = DateInterval(
          start: report.date, duration: AviationReports.observationLifetime)
        guard lifetime.start <= instant, instant < lifetime.end,
          let station = scope.locate(entry, reportedAs: report.stationID)
        else { continue }
        candidates.append(
          Located(
            station: station.identifier, distanceNM: station.distanceNM, report: report,
            issued: report.date, retrievedAt: fetched.retrievedAt))
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        diagnostics.record(error, kind: "METAR", recordID: scope.recordID(entry))
      }
    }
    return candidates.min(by: Located.isPreferred)
  }

  private func forecast(
    _ scope: Scope, at instant: Date, diagnostics: inout ImportDiagnostics
  ) async throws -> Located<TAF>? {
    let fetched = try await fetch(.taf, from: scope, at: instant)
    var candidates: [Located<TAF>] = []
    for entry in fetched.entries {
      do {
        let taf = try await TAF.from(
          string: try Product.taf.text(of: entry), on: fetched.retrievedAt)
        guard let first = taf.groups.first, case .range(let validity) = first.period else {
          throw WeatherFailure(
            provider: "awc", reason: "TAF has no usable forecast validity period.")
        }
        guard validity.dateInterval.start <= instant, instant < validity.dateInterval.end,
          let station = scope.locate(entry, reportedAs: taf.airportID)
        else { continue }
        candidates.append(
          Located(
            station: station.identifier, distanceNM: station.distanceNM, report: taf,
            issued: taf.originDate ?? validity.dateInterval.start,
            retrievedAt: fetched.retrievedAt))
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        diagnostics.record(error, kind: "TAF", recordID: scope.recordID(entry))
      }
    }
    return candidates.min(by: Located.isPreferred)
  }

  private func fetch(_ product: Product, from scope: Scope, at instant: Date) async throws
    -> Fetched
  {
    let url = try WeatherProviders.url(
      Self.endpoint + product.rawValue,
      parameters: product.parameters(at: instant).merging(scope.parameters) { _, new in new })
    let cached = try await http.get(provider: "awc", url: url, units: 1, limits: limits)
    return Fetched(
      entries: cached.payload.arrayValue?.compactMap(\.objectValue) ?? [],
      retrievedAt: cached.retrievedAt)
  }

  private static func parsingGaps(_ diagnostics: ImportDiagnostics) -> [Value] {
    guard diagnostics.count > 0 else { return [] }
    return [
      .object(["provider": "awc", "parse_errors": diagnostics.validation["parse_errors"] ?? .null])
    ]
  }

  private static func nearbyWarning(_ sample: WeatherSample, instead direct: String?) -> String {
    let station = sample.reportingStation?.objectValue
    let identifier = station?["identifier"]?.stringValue ?? "a nearby station"
    let distance = station?["distance_nm"]?.doubleValue.map { " \($0) nm" } ?? ""
    let preface = direct.map { "\($0) has no report covering the requested time. " } ?? ""
    return preface
      + "Reports are from \(identifier), the nearest reporting station,\(distance) from the "
      + "requested position."
  }

  private static func unavailableReason(_ query: WeatherQuery) -> String {
    let radius = "\(Int(StationSearchArea.radiusNM)) nm"
    switch (query.directStation, StationSearchArea(query)) {
    case (nil, nil):
      return query.locationProblem ?? "No reporting station was identified for this request."
    case (let station?, nil):
      return "No usable METAR or TAF from \(station) covers the requested time."
    case (nil, .some):
      return "No usable METAR or TAF from a station within \(radius) covers the requested time."
    case (let station?, .some):
      return "No usable METAR or TAF from \(station) or a station within \(radius) covers the "
        + "requested time."
    }
  }
}

extension AviationWeatherCenter {
  private enum Product: String {
    case metar, taf

    /// METARs come from the recent history; TAFs are those in force at the start of the
    /// requested hour, which is also when TAF validity periods begin and end.
    func parameters(at instant: Date) -> [String: String] {
      switch self {
      case .metar:
        return ["format": "json", "hours": String(AviationWeatherCenter.observationHistoryHours)]
      case .taf:
        let hour = (instant.timeIntervalSince1970 / 3600).rounded(.down) * 3600
        return [
          "format": "json", "time": "valid",
          "date": Date(timeIntervalSince1970: hour).ISO8601Format()
        ]
      }
    }

    func text(of entry: [String: Value]) throws -> String {
      let key = self == .metar ? "rawOb" : "rawTAF"
      guard let text = entry[key]?.stringValue else {
        throw WeatherFailure(
          provider: "awc", reason: "\(rawValue.uppercased()) entry is missing \(key).")
      }
      return text
    }
  }

  private enum Scope {
    case station(String)
    case area(StationSearchArea)

    var parameters: [String: String] {
      switch self {
      case .station(let identifier): ["ids": identifier]
      case .area(let area): ["bbox": area.boundingBox]
      }
    }

    /// The reporting station for an entry, or `nil` when it lies outside the search radius.
    func locate(_ entry: [String: Value], reportedAs reported: String)
      -> (identifier: String, distanceNM: Double?)?
    {
      switch self {
      case .station(let identifier): return (identifier, nil)
      case .area(let area):
        guard let distance = area.distanceNM(to: entry), distance <= StationSearchArea.radiusNM
        else { return nil }
        return (entry["icaoId"]?.stringValue ?? reported, distance)
      }
    }

    func recordID(_ entry: [String: Value]) -> String {
      switch self {
      case .station(let identifier): identifier
      case .area: entry["icaoId"]?.stringValue ?? "nearby"
      }
    }
  }

  private struct Fetched {
    let entries: [[String: Value]]
    let retrievedAt: Date
  }

  private struct Located<Report> {
    let station: String
    let distanceNM: Double?
    let report: Report
    let issued: Date
    let retrievedAt: Date

    var stationValue: Value {
      var value: [String: Value] = ["identifier": .string(station)]
      value["distance_nm"] = roundedDistance.map(Value.double)
      return .object(value)
    }

    private var roundedDistance: Double? { distanceNM.map { ($0 * 10).rounded() / 10 } }

    /// Nearer stations first, then the most recently issued report.
    static func isPreferred(_ lhs: Self, _ rhs: Self) -> Bool {
      let left = lhs.distanceNM ?? 0
      let right = rhs.distanceNM ?? 0
      return left == right ? lhs.issued > rhs.issued : left < right
    }

    func describe(_ report: Value) -> Value {
      guard var object = report.objectValue, let roundedDistance else { return report }
      object["distance_nm"] = .double(roundedDistance)
      return .object(object)
    }
  }
}

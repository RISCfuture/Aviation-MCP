import Foundation
import MCP
import MeasurementKit
import SF50Performance

/// One weather field as the weather service reported it.
struct ReportedField: Sendable {
  let value: MCP.Value
  let origin: InputOrigin
  let time: Date?
  let stamp: LiveSourceStamp
}

/// What the weather service reported for a performance calculation.
struct ReportedWeather: Sendable {
  var fields: [String: ReportedField] = [:]
  var warnings: [String] = []
  var sources: [SourceStamp] = []
  var rateLimits: MCP.Value?
  var reportingStation: MCP.Value?

  init() {}

  /// Reads a weather tool result, taking aviation reports first and modeled values after them.
  init(_ result: ToolResult) {
    let weather = result.results.first?.objectValue ?? [:]
    let reported = weather["fields"]?.objectValue ?? [:]
    let modeled = weather["model_supplement"]?.objectValue?["fields"]?.objectValue ?? [:]
    for (name, field) in modeled.merging(reported, uniquingKeysWith: { $1 }) {
      if let field = field.objectValue.flatMap(Self.field) { fields[name] = field }
    }
    warnings = result.warnings.compactMap(Self.withoutUnreportedGust)
    sources = result.sources
    rateLimits = result.rateLimits
    reportingStation = weather["reporting_station"]
  }

  /// The live sources behind the fields a calculation used.
  func liveSources(for names: [String]) -> [LiveSourceStamp] {
    var seen = Set<String>()
    return names.compactMap { fields[$0]?.stamp }.filter {
      seen.insert([$0.provider, $0.validFrom ?? "", $0.observationTime ?? ""].joined()).inserted
    }
  }

  /// The warning without a complaint that no gust was reported, since most reports carry none.
  private static func withoutUnreportedGust(_ warning: String) -> String? {
    let prefix = "Unavailable fields: "
    guard warning.hasPrefix(prefix) else { return warning }
    let fields = warning.dropFirst(prefix.count).dropLast().split(separator: ", ")
      .filter { $0 != "wind_gust_kt" }
    return fields.isEmpty ? nil : prefix + fields.joined(separator: ", ") + "."
  }

  private static func field(_ object: [String: MCP.Value]) -> ReportedField? {
    guard let value = object["value"], let provider = object["provider"]?.stringValue,
      let retrievedAt = object["retrievedAt"]?.stringValue
    else { return nil }
    let product = object["product"]?.stringValue
    let origin: InputOrigin =
      switch (provider, product) {
      case ("awc", "METAR"): .metar
      case ("awc", _): .taf
      default: .openMeteo
      }
    let observed = object["observationTime"]?.stringValue
    let validFrom = object["validFrom"]?.stringValue
    return ReportedField(
      value: value, origin: origin,
      time: (observed ?? object["issueTime"]?.stringValue ?? validFrom)
        .flatMap(ISO8601Timestamp.parse),
      stamp: LiveSourceStamp(
        provider: provider, retrievedAt: retrievedAt, observationTime: observed,
        validFrom: validFrom, validUntil: object["validUntil"]?.stringValue))
  }
}

/// Weather values the caller supplies in place of the reported ones.
struct WeatherOverrides: Sendable {
  var temperatureC: Double?
  var windDirectionDeg: Double?
  var windSpeedKt: Double?
  var altimeterInHg: Double?

  init(
    temperatureC: Double? = nil, windDirectionDeg: Double? = nil, windSpeedKt: Double? = nil,
    altimeterInHg: Double? = nil
  ) {
    self.temperatureC = temperatureC
    self.windDirectionDeg = windDirectionDeg
    self.windSpeedKt = windSpeedKt
    self.altimeterInHg = altimeterInHg
  }

  init(_ arguments: ToolArguments) throws {
    temperatureC = try arguments.number("temperature_c", range: -60...60)
    windDirectionDeg = try arguments.number("wind_direction_true_deg", range: 0...360)
    windSpeedKt = try arguments.number("wind_speed_kt", range: 0...100)
    altimeterInHg = try arguments.number("altimeter_inhg", range: 26...32)
  }

  /// The weather fields a surface calculation still needs from the weather service.
  ///
  /// Without an airport nothing can be looked up, and the altimeter setting is optional, so only
  /// the fields the tables cannot do without are listed.
  func missingSurfaceFields(needsTemperature: Bool, hasAirport: Bool = true) -> [String] {
    var fields: [String] = []
    if needsTemperature, temperatureC == nil { fields.append("temperature_c") }
    if windSpeedKt == nil || windDirectionDeg == nil {
      fields += ["wind_direction_true_deg", "wind_speed_kt", "wind_gust_kt"]
    }
    if altimeterInHg == nil, hasAirport { fields.append("altimeter_inhg") }
    return fields
  }
}

/// Surface weather for a calculation, each value tagged with where it came from.
struct ResolvedWeather: Sendable {
  let time: Date
  var temperatureC: Sourced<Double>?
  var windDirectionDeg: Sourced<Double?>
  var windSpeedKt: Sourced<Double>
  var windGustKt: Sourced<Double>?
  var altimeterInHg: Sourced<Double>?
  var warnings: [String] = []

  /// Merges reported weather with the caller's overrides, each override winning its field.
  ///
  /// A missing altimeter setting leaves the tables read at field elevation, which the
  /// calculation's notes say. A wind with speed but no prevailing direction is taken along each
  /// runway as a tailwind, the worst case; see ``conditions(runwayHeadingDeg:)``.
  ///
  /// - Throws: ``WeatherFailure`` when the wind speed is neither reported nor overridden, or the
  ///   temperature is needed and neither reported nor overridden. The models are never fed a
  ///   substitute for either.
  static func resolve(
    reported: ReportedWeather, overrides: WeatherOverrides, time: Date, needsTemperature: Bool
  ) throws -> Self {
    func sourced(_ override: Double?, _ name: String) -> Sourced<Double>? {
      if let override { return Sourced(override, .override) }
      guard let field = reported.fields[name], let value = field.value.number else { return nil }
      return Sourced(value, field.origin, time: field.time)
    }
    let temperature = needsTemperature ? sourced(overrides.temperatureC, "temperature_c") : nil
    if needsTemperature, temperature == nil {
      throw WeatherFailure(
        provider: "weather",
        reason: "No temperature was reported or forecast at \(time.ISO8601Format()). Supply "
          + "temperature_c to calculate without it.")
    }
    guard let speed = sourced(overrides.windSpeedKt, "wind_speed_kt") else {
      throw WeatherFailure(
        provider: "weather",
        reason: "No wind was reported or forecast at \(time.ISO8601Format()). Supply "
          + "wind_direction_true_deg and wind_speed_kt (0 for calm) to calculate without it.")
    }
    var direction: Sourced<Double?> =
      if let value = overrides.windDirectionDeg {
        Sourced(value, .override)
      } else if let field = reported.fields["wind_direction_true_deg"] {
        Sourced(field.value.number, field.origin, time: field.time)
      } else {
        Sourced(nil, .assumed)
      }
    var warnings: [String] = []
    if speed.value > 0, direction.value == nil {
      direction.note = "no prevailing direction; taken as a tailwind along the runway"
      warnings.append(
        "The wind has no prevailing direction, so its full \(Int(speed.value.rounded())) kt is "
          + "taken as a tailwind along the runway, the worst case. Supply "
          + "wind_direction_true_deg to calculate a particular direction.")
    }
    let gust = overrides.windSpeedKt == nil ? sourced(nil, "wind_gust_kt") : nil
    if let gust, gust.value > speed.value {
      warnings.append(
        "Gusts to \(Int(gust.value.rounded())) kt are reported; the calculation uses the steady "
          + "wind of \(Int(speed.value.rounded())) kt.")
    }
    return Self(
      time: time, temperatureC: temperature, windDirectionDeg: direction, windSpeedKt: speed,
      windGustKt: gust, altimeterInHg: sourced(overrides.altimeterInHg, "altimeter_inhg"),
      warnings: warnings)
  }

  /// The conditions the performance models read for a runway with the given true heading.
  ///
  /// A wind with speed but no direction blows from behind the runway.
  func conditions(runwayHeadingDeg: Double) -> Conditions {
    let direction =
      windDirectionDeg.value
      ?? (windSpeedKt.value > 0
        ? (runwayHeadingDeg + 180).truncatingRemainder(dividingBy: 360) : nil)
    let origins = [temperatureC?.origin, windSpeedKt.origin, altimeterInHg?.origin]
    var providers = SF50Performance.WeatherProviders()
    if origins.contains(where: { $0 == .metar || $0 == .taf }) { providers.insert(.NWS) }
    if origins.contains(.openMeteo) { providers.insert(.openMeteo) }
    let source: Conditions.Source =
      temperatureC?.origin == .override || providers.isEmpty ? .entered : .downloaded(providers)
    return Conditions(
      validTime: DateInterval(start: time, duration: 3600), source: source,
      windDirection: direction.map { Measurement(value: $0, unit: .degrees) },
      windSpeed: Measurement(value: windSpeedKt.value, unit: .knots),
      temperature: temperatureC.map { Measurement(value: $0.value, unit: .celsius) },
      dewpoint: nil,
      seaLevelPressure: altimeterInHg.map { Measurement(value: $0.value, unit: .inchesOfMercury) })
  }

  /// The weather as results echo it.
  func provenance(pressureAltitude: Measurement<UnitLength>?) throws -> [String: MCP.Value] {
    var fields: [String: MCP.Value] = [
      "time": .string(time.ISO8601Format()),
      "wind_direction_true_deg": try .encoded(windDirectionDeg),
      "wind_speed_kt": try .encoded(windSpeedKt)
    ]
    fields["wind_gust_kt"] = try windGustKt.map(MCP.Value.encoded)
    fields["altimeter_inhg"] =
      try altimeterInHg.map(MCP.Value.encoded)
      ?? .encoded(
        Sourced<Double?>(
          nil, .assumed, note: "no altimeter setting; tables read at field elevation"))
    fields["temperature_c"] = try temperatureC.map(MCP.Value.encoded)
    if let pressureAltitude {
      fields["pressure_altitude_ft"] = .double(
        pressureAltitude.converted(to: .feet).value.rounded())
    }
    return fields
  }
}

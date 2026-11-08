import AircraftPerformance
import Foundation
import MCP
import Testing

@testable import AviationMCP

@Suite
struct `Performance inputs and figures` {
  @Test
  func `resolves runway inputs from NASR, deriving what is unpublished, with overrides winning`()
    throws
  {
    let airport = PerformanceFixtures.airport()
    let published = try ResolvedRunway.resolve(
      airport: airport, end: airport.end("28R"), overrides: .init())
    #expect(published.elevationFt.value == 6 && published.elevationFt.origin == .nasr)
    #expect(published.headingTrueDeg.value == 295)
    #expect(published.takeoffDistanceFt?.value == 10_500)
    #expect(published.landingDistanceFt?.value == 9_000)
    #expect(published.surface.value == "paved" && published.surface.origin == .nasr)

    let derived = try ResolvedRunway.resolve(
      airport: airport, end: airport.end("RW10L"), overrides: .init())
    #expect(derived.headingTrueDeg.note != nil)
    #expect((100...130).contains(derived.headingTrueDeg.value))
    #expect(derived.slopePercent.value == -0.1)
    #expect(derived.takeoffRunFt?.value == 10_000 && derived.takeoffRunFt?.note != nil)

    let overridden = try ResolvedRunway.resolve(
      airport: airport, end: airport.end("28R"),
      overrides: .init(slopePercent: 1, surface: .turf, takeoffRunFt: 7_000))
    #expect(overridden.slopePercent.value == 1 && overridden.slopePercent.origin == .override)
    #expect(overridden.surface.value == "turf" && overridden.surface.origin == .override)
    #expect(overridden.takeoffRunFt?.value == 7_000)
    #expect(overridden.takeoffDistanceFt?.value == 7_000)
    #expect(overridden.takeoffDistanceFt?.origin == .override)
    #expect(overridden.input().availableTakeoffRun.converted(to: .feet).value.rounded() == 7_000)

    #expect(throws: ToolInputError.self) {
      try ResolvedRunway.resolve(airport: nil, end: nil, overrides: .init(elevationFt: 100))
    }
    #expect(throws: ToolInputError.self) { try airport.end("19") }
  }

  @Test
  func `merges reported weather with overrides and refuses to substitute missing inputs`()
    async throws
  {
    let reported = ReportedWeather(
      try await PerformanceFixtures.weather(gust: 25).weather(
        WeatherQuery(
          station: "KOAK", latitude: 37.7, longitude: -122.2, instant: PerformanceFixtures.time,
          fields: ["temperature_c", "wind_direction_true_deg", "wind_speed_kt", "wind_gust_kt"],
          sources: nil)))
    let weather = try ResolvedWeather.resolve(
      reported: reported, overrides: .init(temperatureC: 30), time: PerformanceFixtures.time,
      needsTemperature: true)
    #expect(weather.temperatureC?.value == 30 && weather.temperatureC?.origin == .override)
    #expect(weather.windSpeedKt.value == 10 && weather.windSpeedKt.origin == .metar)
    #expect(weather.windDirectionDeg.value == 280)
    #expect(weather.altimeterInHg == nil)
    #expect(weather.warnings.contains { $0.contains("Gusts to 25 kt") })
    let conditions = weather.conditions(runwayHeadingDeg: 295)
    #expect(conditions.seaLevelPressure == nil)
    #expect(conditions.source == .entered)

    #expect(throws: WeatherFailure.self) {
      try ResolvedWeather.resolve(
        reported: ReportedWeather(), overrides: .init(windDirectionDeg: 280, windSpeedKt: 5),
        time: PerformanceFixtures.time, needsTemperature: true)
    }
    #expect(throws: WeatherFailure.self) {
      try ResolvedWeather.resolve(
        reported: ReportedWeather(), overrides: .init(temperatureC: 20),
        time: PerformanceFixtures.time, needsTemperature: true)
    }
    let withoutTemperature = try ResolvedWeather.resolve(
      reported: ReportedWeather(), overrides: .init(windDirectionDeg: 0, windSpeedKt: 0),
      time: PerformanceFixtures.time, needsTemperature: false)
    #expect(withoutTemperature.temperatureC == nil)
    #expect(try withoutTemperature.provenance(pressureAltitude: nil)["temperature_c"] == nil)
  }

  @Test
  func `takes a wind without a direction as a tailwind along the runway`() throws {
    let weather = try ResolvedWeather.resolve(
      reported: ReportedWeather(), overrides: .init(temperatureC: 20, windSpeedKt: 8),
      time: PerformanceFixtures.time, needsTemperature: true)
    #expect(weather.windDirectionDeg.value == nil)
    #expect(weather.warnings.contains { $0.contains("tailwind") })
    let runway = try ResolvedRunway.resolve(
      airport: nil, end: nil, overrides: .init(elevationFt: 0, headingTrueDeg: 100))
    let conditions = weather.conditions(runwayHeadingDeg: 100)
    #expect(
      runway.input().headwind(conditions: conditions).converted(to: .knots).value.rounded() == -8)
  }

  @Test
  func `reads climb figures with uncertainty, the first refusal and the ground distance`() throws {
    func point(_ altitude: Double, _ gradient: AircraftPerformance.Value<Double>)
      -> ClimbProfile.DataPoint
    {
      let data = ClimbProfile.ClimbData(
        gradientFtPerNM: gradient, indicatedAirspeedKts: .value(120))
      return .init(
        altitudeFt: altitude, outsideAirTemperatureC: 10, windDirectionDeg: 0, windSpeedKts: 0,
        takeoff: data, enrouteObstacle: data, enrouteObstacleAntiIce: data, enroute: data,
        enrouteAntiIce: data)
    }
    func report(_ points: [ClimbProfile.DataPoint], top: Double) -> ClimbReport {
      ClimbReport(
        profile: ClimbProfile(dataPoints: points, seaLevelPressureInHg: 29.92),
        schedules: ClimbReport.schedules(for: .sf50(.g2Plus)), fieldFt: 0, topFt: top,
        courseDeg: 0)
    }
    let uncertain = report(
      [
        point(0, .valueWithUncertainty(400, uncertainty: 40)),
        point(4_000, .valueWithUncertainty(300, uncertainty: 20))
      ], top: 4_000)
    let middle = try #require(
      uncertain.levels()[2].objectValue?["schedules"]?.objectValue?["takeoff"]?.objectValue?[
        "gradient_ft_per_nm"]?.objectValue)
    #expect(middle["status"] == "uncertain")
    #expect(middle["value"]?.number == 350 && middle["uncertainty"]?.number == 30)
    guard
      case .valueWithUncertainty(300, uncertainty: 20) = uncertain.minimum(
        .takeoff, { _ in .valueWithUncertainty(300, uncertainty: 20) })
    else {
      Issue.record("the minimum should keep the uncertainty of the lowest figure")
      return
    }

    let refused = report(
      [point(0, .value(400)), point(4_000, .value(300)), point(5_000, .notAvailable)], top: 4_500)
    let refusal = refused.minimum(.takeoff) { altitude in altitude < 4_200 ? .value(250) : .invalid
    }
    guard case .invalid = refusal else {
      Issue.record("the first refusal on the way up should win, got \(refusal)")
      return
    }
    #expect(refused.groundDistance(.takeoff) == nil)

    let constant = report([point(0, .value(300)), point(10_000, .value(300))], top: 3_000)
    #expect(try #require(constant.groundDistance(.takeoff)).rounded() == 10)
    #expect(constant.levelAltitudes == [0, 1_000, 2_000, 3_000])
  }

  @Test
  func `maps model figures to JSON and suggests the regression model for tabular refusals`() {
    var tabular = FigureEncoder(model: .tabular)
    let clamped = tabular.encode(
      AircraftPerformance.Value.offscaleHigh(
        clamped: Measurement(value: 2_000.4, unit: UnitLength.feet)),
      "takeoff_run_ft", in: .feet)
    #expect(clamped == ["status": "offscale_high", "clamped_value": 2_000.0])
    let missing = tabular.encode(
      AircraftPerformance.Value<Double>.notAvailable, "minimum_gradient_ft_per_nm")
    #expect(missing == ["status": "not_available"])
    #expect(tabular.isPartial)
    #expect(tabular.allWarnings.count == 3)
    #expect(tabular.allWarnings.last?.contains("model \"regression\"") == true)

    var regression = FigureEncoder(model: .regression)
    let uncertain = regression.encode(
      AircraftPerformance.Value.valueWithUncertainty(1_234.6, uncertainty: 40.2), "landing_run_ft")
    #expect(uncertain == ["status": "uncertain", "value": 1_235.0, "uncertainty": 40.0])
    #expect(!regression.isPartial)
    _ = regression.encode(AircraftPerformance.Value<Bool>.offscaleLow(clamped: nil), "go_around")
    #expect(regression.isPartial)
    #expect(regression.allWarnings.allSatisfy { !$0.contains("regression") })
  }

  @Test
  func `steepens the ground gradient into a headwind and flattens it downwind`() throws {
    let headwind = try #require(
      ClimbReport.groundGradient(
        air: 300, trueAirspeedKt: 120, windFromDeg: 0, windSpeedKt: 20, courseDeg: 0))
    #expect(abs(headwind - 360) < 0.001)
    let tailwind = try #require(
      ClimbReport.groundGradient(
        air: 300, trueAirspeedKt: 120, windFromDeg: 180, windSpeedKt: 20, courseDeg: 0))
    #expect(abs(tailwind - 300 * 120 / 140) < 0.001)
    #expect(
      ClimbReport.groundGradient(
        air: 300, trueAirspeedKt: 120, windFromDeg: 0, windSpeedKt: 130, courseDeg: 0) == nil)
  }
}

/// A runway and weather to calculate performance with.
enum PerformanceFixtures {
  static let time = Date(timeIntervalSince1970: 1_793_815_200)

  /// The runway-end fixture airport as a NASR airport search presents it.
  static func airport() -> PerformanceAirport {
    let record = `Transactional publication`.airportWithRunwayEnds(
      `Transactional publication`.version(.nasr))
    var presented = record.data
    presented["id"] = .string(record.id)
    presented["identifier"] = .string(record.identifier)
    presented["name"] = .string(record.name)
    presented["elevation_msl_ft"] = record.elevationMSLFeet.map(MCP.Value.double)
    presented["geometry"] = record.geometry
    return PerformanceAirport(presented)
  }

  /// A METAR reporting wind 280° at 10 kt, 15 °C and the given gust, and a model forecast with
  /// two pressure levels above the field.
  static func weather(gust: Double? = nil) -> WeatherService {
    WeatherService(
      awc: { _ in
        sample(
          provider: "awc", product: "METAR",
          values: [
            "temperature_c": 15, "wind_direction_true_deg": 280, "wind_speed_kt": 10,
            "wind_gust_kt": gust.map(MCP.Value.double) ?? .null
          ])
      },
      openMeteo: { _ in
        sample(
          provider: "open_meteo", product: "hourly_forecast",
          values: [
            "altimeter_inhg": 30.12,
            "pressure_levels": [
              [
                "pressure_hpa": 925, "geopotential_height_m": 780, "temperature_c": 12,
                "wind_speed_kt": 20, "wind_direction_true_deg": 290
              ],
              [
                "pressure_hpa": 700, "geopotential_height_m": 3_100, "temperature_c": -2,
                "wind_speed_kt": 30, "wind_direction_true_deg": 270
              ]
            ]
          ])
      })
  }

  /// The aircraft an `aircraft` object names, without a weight.
  static func aircraft(_ fields: [String: MCP.Value]) throws -> PerformanceAircraft {
    try PerformanceAircraft(
      ToolArguments(["aircraft": .object(fields)]), through: .current, requiringWeight: false)
  }

  /// A level 3,000 ft runway at sea level with the given surface.
  static func runway(surface: SurfaceType) -> RunwayInput {
    let length = Measurement(value: 3_000, unit: UnitLength.feet)
    return RunwayInput(
      id: "36", elevation: .init(value: 0, unit: .feet),
      trueHeading: .init(value: 0, unit: .degrees),
      gradient: 0, length: length, takeoffRun: length, takeoffDistance: length,
      landingDistance: length, surfaceType: surface, notam: nil,
      airportVariation: .init(value: 0, unit: .degrees))
  }

  static func sample(provider: String, product: String, values: [String: MCP.Value])
    -> WeatherSample
  {
    WeatherSample(
      fields: values.mapValues {
        WeatherField(
          value: $0, provider: provider, product: product, modeled: provider == "open_meteo",
          validFrom: time.addingTimeInterval(-600), validUntil: time.addingTimeInterval(3_000),
          retrievedAt: time)
      })
  }
}

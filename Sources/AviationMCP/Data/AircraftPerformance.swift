import MCP
import SwiftACD

enum AircraftPerformance {
  static func normalize(_ performance: Performance) -> Value {
    Normalization.object([
      "source": "EUROCONTROL APD",
      "takeoff": performance.takeoff.map {
        Normalization.object([
          "v2_kt": $0.v2Kt.map(Value.double), "distance_ft": $0.distanceFt.map(Value.double)
        ])
      },
      "climb": performance.climb.map(climbProfile),
      "cruise": performance.cruise.map {
        Normalization.object([
          "tas_kt": $0.TASKt.map(Value.double), "mach": $0.mach.map(Value.double),
          "ceiling_fl": $0.ceilingFL.map(Value.int), "range_nm": $0.rangeNmi.map(Value.double)
        ])
      },
      "descent": performance.descent.map {
        Normalization.object([
          "initial": $0.initialDescent.map {
            Normalization.object([
              "mach": $0.mach.map(Value.double), "rate_of_descent_fpm": .double($0.rateOfDescentFPM)
            ])
          },
          "normal": $0.descent.map {
            .object([
              "ias_kt": .double($0.IASKt), "rate_of_descent_fpm": .double($0.rateOfDescentFPM)
            ])
          }
        ])
      },
      "approach": performance.approach.map {
        Normalization.object([
          "ias_kt": $0.IASKt.map(Value.double),
          "minimum_clean_speed_kt": $0.minimumCleanSpeedKt.map(Value.double),
          "rate_of_descent_fpm": $0.rateOfDescentFPM.map(Value.double)
        ])
      },
      "landing": performance.landing.map {
        Normalization.object([
          "vat_kt": $0.vatKt.map(Value.double), "distance_ft": $0.distanceFt.map(Value.double)
        ])
      }
    ])
  }

  private static func climbProfile(_ profile: Performance.Climb) -> Value {
    Normalization.object([
      "initial": profile.initialClimb.map(climb), "to_fl150": profile.toFL150.map(climb),
      "to_fl240": profile.toFL240.map(climb),
      "mach_climb": profile.machClimb.map {
        Normalization.object([
          "mach": $0.mach.map(Value.double), "rate_of_climb_fpm": .double($0.rateOfClimbFPM)
        ])
      }
    ])
  }

  private static func climb(_ band: Performance.ClimbBand) -> Value {
    .object(["ias_kt": .double(band.IASKt), "rate_of_climb_fpm": .double(band.rateOfClimbFPM)])
  }
}

---
name: notams-to-performance-inputs
description: Turn NOTAMs into Cirrus SF50 and SR22 performance inputs. Use before any takeoff_performance, landing_performance, takeoff_limits or climb_profile call that names an airport, runway and time, and whenever a user asks how NOTAMs affect a takeoff, landing, go-around or departure — runway closures, shortened runways, declared-distance changes, displaced or relocated thresholds, FICON contamination and RwyCC, cranes and other temporary obstacles, lighting or NAVAID outages, and amended or not-authorized procedures. Produces the tool overrides and a baseline-versus-NOTAM table, and keeps schedules, reciprocal-runway notices and uncertain matches visible.
---

# NOTAMs to performance inputs

Find the NOTAMs that apply at the time of an operation, sort them by effect, and turn
each one into the matching performance-tool override, or a reason no calculation applies.

## Safety

- Planning aid only. Figures from these tools are not approved by the FAA, the aircraft
  manufacturer or any supplement holder and are not for cockpit use; say so whenever you
  report them.
- Never invent, estimate or interpolate a figure the tools did not return. If something is
  missing, name it and the input that would supply it.
- Pass through every non-`value` status (`uncertain`, `offscale_high`, `offscale_low`,
  `not_available`, `not_authorized`, `invalid`), every warning and any `partial`
  completeness. Never replace them with a guess.
- List every input with its source and time: `nasr`, `metar`, `taf`, `open_meteo`,
  `override`, `isa` or `assumed`, plus NOTAM numbers and data cycles.

## 1. Query

1. Get the runway ends from `get_airport` (`identifier`). Note each end's `tora_ft`,
   `toda_ft`, `lda_ft`, `threshold_elevation_msl_ft`, `departure_end` position and the
   reciprocal end's identifier.
2. Call `query_notams` with `location` (the airport), `start` and `end` as ISO 8601 with an
   offset, and `runway` (the end in use). Cover the operation with room for delay: for a
   departure, from 30 minutes before to 2 hours after; for an arrival, an hour either side
   of the ETA.
3. Call it again with `runway` set to the reciprocal end. A notice filed against `RWY 33`
   can shorten the takeoff run on 15.
4. When an approach or departure procedure matters, call it again with `procedure` (for
   example `RNAV (GPS) RWY 15` or the SID's name).
5. Follow `nextCursor` until it is absent, repeating every other argument unchanged.

Text matches are listed first. Everything else comes back with `context_match: "uncertain"`
or `scope_match: "uncertain"`. Read those too; they are uncertain, not irrelevant.

## 2. Classify and map

| Notice | Example text | Performance effect |
| --- | --- | --- |
| Runway closed | `RWY 15/33 CLSD` | No calculation for that runway while closed; pick another end and say why |
| Declared distances | `RWY 28R TORA 9000FT TODA 9000FT LDA 8500FT` | `available_takeoff_run_ft`, `available_takeoff_distance_ft`, `available_landing_distance_ft` |
| Threshold displaced | `RWY 28R THR DISPLACED 1000FT` | Usually shortens LDA on that end only: `available_landing_distance_ft` |
| Threshold relocated or pavement closed | `RWY 33 THR RELOCATED 1200FT` | Shortens the usable runway in both directions: use the declared distances the NOTAM gives for each end, or ask for them |
| Contamination (FICON) | `RWY 15 FICON 3/3/3 100 PCT 1/4IN SLUSH` | Landing: `contamination`, `contamination_depth_in`, or `contamination: "rwycc"` with `rwycc` |
| Temporary obstacle | `OBST CRANE ... 245FT (125FT AGL)` | Takeoff: `obstacle_height_ft` and `obstacle_distance_ft`, worked out below |
| Lighting or NAVAID out | `ILS RWY 15 LOC U/S`, `RWY 15 PAPI U/S` | No performance input; may make an approach unusable or raise minimums |
| Procedure amended or not authorized | `... RNAV (GPS) RWY 15 AMDT 2 ... NA`, `... CLIMB GRADIENT 520FT/NM` | Feeds the go-around and departure verdicts; a new climb gradient replaces the published one |
| Airport hours, PPR, closure | `AD CLSD`, `PPR` | No figure; state it as a constraint |

### Contamination

- Map the contaminant: wet → `wet`; standing water or slush with a depth →
  `water_or_slush` with `contamination_depth_in`; wet snow or slush over snow →
  `slush_or_wet_snow` with `contamination_depth_in`; dry snow → `dry_snow`; compacted
  snow → `compact_snow`. When only a RwyCC is clear, use `contamination: "rwycc"` and
  `rwycc`.
- FICON codes are given by thirds in the direction of the runway number. For the
  reciprocal, read them in reverse. Use the lowest code that applies to the landing roll and
  say which third it came from.
- `takeoff_performance` takes contamination only for the SR22's wet-grass correction
  (`contamination: "wet"` with `surface: "turf"`). For every other contaminated takeoff, never
  apply a landing factor; say that contaminated takeoff figures are not available from
  these tools.
- The SF50 takes contamination on landing only. The SR22 takes only `wet` on a `turf`
  surface, on takeoff and landing; any other contamination is refused with
  `invalid_argument`. Say that the aircraft's manual has no figures for it.
- Every contaminated landing (anything but `wet`) carries a supplemental-data disclaimer.
  Keep it.

### Temporary obstacles: AGL versus MSL

`obstacle_height_ft` is the height **above the runway**, not AGL and not MSL.

1. Take the obstacle's MSL elevation, the first figure in the NOTAM (`245FT`); the
   parenthesized figure (`125FT AGL`) is its height above its own base.
2. Subtract the departure-end elevation of the runway in use (the reciprocal end's
   `threshold_elevation_msl_ft`). The result is `obstacle_height_ft`. If it is zero or
   below, the obstacle does not constrain the climb; say so.
3. Convert the NOTAM's DMS position (`373512N1221310W`) to decimal degrees. Call
   `compute_geometry` with `operation: "distance"` and `coordinates`
   `[[departure_end_lon, departure_end_lat], [obstacle_lon, obstacle_lat]]`. Multiply NM
   by 6,076 for `obstacle_distance_ft`.
4. Use it only if it lies ahead of the departure, near the extended centerline. "APCH END
   RWY 28R" means near the 28R threshold, which is the departure end for 10L.
5. Always pass `obstacle_height_ft` and `obstacle_distance_ft` together.

## 3. Watch for

- **Schedules in the text.** A `schedule` field, or text such as `DLY 1400-2200` or
  `MON-FRI 1300-2300`, is preserved but not interpreted by the server. Check it against the
  operation time yourself. NOTAM times are UTC.
- **The reciprocal runway.** Closures, relocated thresholds and obstacles filed against the
  other end change this end's distances or departure path.
- **Uncertain matches stay visible.** List them in their own section with the reason they
  might apply. Do not drop them silently.
- **No end time.** A notice without `valid_until` stays in force until cancelled.
- **Intersection departures.** A taxiway notice matters only if the departure starts from an
  intersection; then the TORA is shorter, and the user must supply it.

## 4. Report

Run the performance tool once with published data and once with the NOTAM overrides, and
show both side by side:

| Input | Published (source) | With NOTAMs | NOTAM |
| --- | --- | --- | --- |
| TORA 28R | `<published>` ft (NASR, cycle date) | `<shortened>` ft (override) | `<NOTAM number>` |

Then list the notices that change no input but matter (lighting, NAVAIDs, procedures,
hours), and finally the uncertain matches. Quote each NOTAM's number and validity.

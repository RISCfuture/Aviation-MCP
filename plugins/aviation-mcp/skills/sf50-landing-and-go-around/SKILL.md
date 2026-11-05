---
name: sf50-landing-and-go-around
description: Assess a Cirrus SF50 Vision Jet landing and whether a go-around or missed approach is possible — Vref, landing distance against LDA, runway contamination and RwyCC, the AFM go-around climb gradient, and the missed-approach climb versus the required gradient, terrain and obstacles for each approach. Use for questions like "is a go-around possible from KASE runway 15 tomorrow at 2pm?", SF50 landing distance on a wet or snowy runway, or whether the SF50 can make a missed-approach climb gradient. Combines sf50_landing_performance, find_procedures, get_procedure, sf50_climb_profile, query_terrain and query_obstacles.
---

# SF50 landing and go-around

## Safety

- Planning aid only. SF50 figures from these tools are not FAA- or Cirrus-approved and are
  not for cockpit use; say so whenever you report them.
- Never invent, estimate or interpolate a figure the tools did not return. If something is
  missing, name it and the input that would supply it.
- Pass through every non-`value` status (`uncertain`, `offscale_high`, `offscale_low`,
  `not_available`, `not_authorized`, `invalid`), every warning and any `partial`
  completeness. Never replace them with a guess.
- List every input with its source and time: `nasr`, `metar`, `taf`, `open_meteo`,
  `override`, `isa` or `assumed`, plus NOTAM numbers and data cycles.

## Inputs to collect

- `aircraft_generation` (ask if unknown; never assume) and the **landing** weight
  (`weight_lb`), not the takeoff weight.
- `airport`, `runway` and the arrival time, converted by performance-weather-for-time.
- `flaps`: `100` by default; also `50` and `up`, and `50_ice` or `up_ice` when ice
  protection is on.
- NOTAM inputs from notams-to-performance-inputs: `available_landing_distance_ft`,
  `contamination`, `contamination_depth_in`, `rwycc`.

## Steps

1. **Landing.** Call `sf50_landing_performance`:

   ```json
   {"aircraft_generation": "g2", "weight_lb": 5400, "airport": "KASE", "runway": "15",
    "time": "2026-11-05T21:00:00Z"}
   ```

   Read `vref_kt`, `landing_run_ft`, `landing_distance_ft` (from 50 ft), the breakdowns,
   `runway_margins.landing_distance` and `meets_go_around_climb_gradient`. That last field
   is the AFM go-around gradient check at these conditions. If it is false or not a `value`,
   say a go-around is not established by the AFM data, and continue only to show the
   missed-approach picture.
2. **Approaches.** Call `find_procedures` with `airport` and `procedure_type: "approach"`.
   Call it without `runway` as well: circling approaches list no runway (`runways: []`,
   `landing: "circle_to_land"`), yet they may be how you reach runway 15. If the result
   warns of CIFP parse errors, say approaches may be missing.
3. **Missed approach.** For each approach, call `get_procedure` with `airport` and
   `identifier` (such as `RNV-F`).
   - The missed-approach point is the leg with `is_missed_approach_point: true`; note its
     `position` and `altitude_constraint`.
   - `missed_approach_legs` give the path: `CA` (course to an altitude), `DF` and `TF`
     (to a fix), `HM` (the hold). Courses are `reference: "magnetic"`.
   - `obstacle_clearance_assessed: false` means the server did not assess the procedure.
4. **Required gradient.** CIFP does not carry chart notes. The standard missed-approach
   climb is **200 ft/NM** unless the chart publishes a higher one. Ask the user for the
   chart's figure, or state that you used 200 ft/NM and that a published higher gradient
   replaces it. A NOTAM can also change it.
5. **Course in true.** Missed-approach course true = magnetic + east variation, taking
   the variation from a runway end in `get_airport` as `heading_true_deg −
   heading_magnetic_deg`.
6. **Climb.** Call `sf50_climb_profile` with the landing weight, `airport`, `runway`,
   `time`, `course_true_deg` (the initial missed-approach course in true) and
   `top_altitude_ft` (the highest missed-approach altitude constraint, usually the hold).
   - The tool has no go-around configuration. The `takeoff` schedule (91 KIAS) is the
     closest proxy for the initial climb; `enroute_obstacle` (120 KIAS) applies later.
     Say which you used.
   - Use `schedules.takeoff.minimum_ground_gradient_ft_per_nm`. A headwind on the
     missed-approach course raises the ground gradient; a tailwind lowers it. The `levels`
     array gives gradients per 1,000 ft if the requirement applies only up to an altitude.
   - `bands_without_gradient` and non-`value` statuses mean the AFM data does not cover
     part of the climb. The ice schedules are often offscale on a warm day; report that, but
     it does not affect the non-ice verdict.
7. **Terrain.** Call `query_terrain`:
   - `route`: the missed-approach point, then the fix positions along the missed approach.
     For a `CA` leg, project the point where the altitude is reached with
     `compute_geometry` (`operation: "destination"`, `course_true_deg`, `distance_nm` =
     altitude to gain ÷ gradient). At most 20 points.
   - `half_width_nm`: up to 2. The corridor is not a TERPS surface.
   - `starting_altitude_ft`: the altitude at the missed-approach point (the DA or MDA when
     the user gives it, otherwise the CIFP altitude there).
   - `gradient_ft_per_nm`: the climb profile's ground gradient, rounded down.
   - `clearance_ft`: state your choice; use 0 for a bare terrain comparison.
   - `vertical_datum`: `EGM2008`. Charted MSL altitudes are close to EGM2008 heights in the
     U.S. but not identical; treat margins of a few tens of feet as inconclusive.
   - `climb.status` is `conditional_clearance_met` or `not_established`. The latter is
     inconclusive, not proof of a conflict. Report `limiting.minimum_margin_ft`, its
     position, and any coverage gaps.
8. **Obstacles.** Call `query_obstacles` with `procedure_id` (the `id` from
   `find_procedures`) and a `radius_nm`, or with a `route` along the missed approach.
   Compare each obstacle's `elevation_msl_ft` with the altitude the climb gives at its
   distance (starting altitude + gradient × distance).

## Verdict per approach

| Approach | Required (source) | SF50 ground gradient (schedule) | Margin | Terrain | Obstacles | NOTAMs | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- |
| RNAV (GPS)-F | 200 ft/NM (standard; chart not checked) | `<n>` ft/NM (takeoff) | `<n>` ft/NM | `conditional_clearance_met` | `<list>` | `<ids>` | Meets on these inputs |

Use only "meets on these inputs", "does not meet" or "not established". Never call a
go-around safe or certified.

## Answer format

1. Landing: Vref, landing distance against LDA with margin, contamination effect, and the
   AFM go-around check.
2. The per-approach verdict table.
3. Inputs with origin and time; NOTAMs applied and uncertain.
4. The disclaimers from the results.

---
name: sf50-takeoff-planning
description: Plan a Cirrus SF50 Vision Jet takeoff with the sf50_takeoff_performance tool — ground run, total distance over a 50 ft obstacle, the wind, slope and surface correction factors, takeoff climb gradient, and margins against TORA and TODA — for a named airport, runway, weight and time. Use for questions like "KOAK 28R in 18 hours at 5800 lb, what's my ground run, total distance and correction factors?", choosing a departure runway by wind, checking a NOTAM-shortened runway or an obstacle off the departure end, or any SF50 takeoff distance question.
---

# SF50 takeoff planning

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

- **`aircraft_generation`**, required: `g1`, `g2`, `g2_updated_thrust`, `g2_plus` or `g3`.
  If the user has not said, ask. Never assume one; the figures differ.
- **`weight_lb`**, required: the takeoff weight. The tool refuses weights above the
  structural limit.
- **`airport`** and **`runway`**, or choose the runway as in step 2.
- **Time**: follow the performance-weather-for-time skill to turn "in 18 hours" or
  "tomorrow at 2pm" into an ISO 8601 `time`.
- Optional: `safety_factor` (1–3, default 1) if the user applies a personal factor;
  `model: "regression"` only as described in step 6.

## Steps

1. **Runway data.** `get_airport` gives each end's `tora_ft`, `toda_ft`,
   `threshold_elevation_msl_ft`, `heading_true_deg`, surface and remarks (PPR, noise
   abatement, preferred runways). The performance tool reads the same NASR record itself;
   this call is for choosing and explaining.
2. **No runway given?** Get the wind at the time (performance-weather-for-time). For each
   end, the headwind component is `speed × cos(wind_true − heading_true_deg)`. Prefer the end
   with the most headwind; among near-ties prefer the longer TORA and a downhill slope. Show
   the components. Mention that ATC, PPR rules and noise procedures may assign another
   runway.
3. **NOTAMs.** Follow notams-to-performance-inputs for the time window. Collect overrides:
   `available_takeoff_run_ft`, `available_takeoff_distance_ft`, `obstacle_height_ft` and
   `obstacle_distance_ft`, or a closure.
4. **Calculate.**

   ```json
   {"aircraft_generation": "g2_plus", "weight_lb": 5800, "airport": "KOAK",
    "runway": "28R", "time": "2026-11-05T13:00:00Z"}
   ```

   If a NOTAM changes an input, run it a second time with the overrides and report both.
5. **Obstacles (optional).** `query_obstacles` with `airport`, `runway` and `limit` lists
   the highest DOF obstacles in a 15° departure sector. For one that matters, pass
   `obstacle_height_ft` = its `elevation_msl_ft` minus the departure-end elevation (height
   above the runway, not AGL) and `obstacle_distance_ft` = its distance from the departure
   end in feet (`compute_geometry` distance × 6,076). The result's `obstacle` block gives
   the required gradient, margin and whether it is cleared. For a full departure climb,
   use sf50-departure-climb-vs-terrain.
6. **Offscale or not available.** With the default tabular model, conditions outside the
   AFM tables come back as `offscale_high`, `offscale_low` or `not_available`, and the
   result suggests the regression model. Report the tabular status first. Then, if the user
   wants a number, rerun with `model: "regression"` and present it as an extrapolation with
   its `uncertainty`, never as an AFM figure.

## Reading the result

- `takeoff_run_ft` is the ground run; `takeoff_distance_ft` is the total distance over a
  50 ft obstacle. Each is a figure object: `{status, value?, uncertainty?, clamped_value?}`.
- `takeoff_run_breakdown` and `takeoff_distance_breakdown` give `base_ft`, then each
  adjustment's `kind` (headwind, tailwind, uphill slope, downhill slope, unpaved surface,
  safety factor), its `multiplier` and the `result_ft` after it. These are the correction
  factors; quote them in order.
- `runway_margins` compares required with available TORA and TODA (`margin_ft`).
- `takeoff_climb_gradient_ft_per_nm` and `takeoff_climb_rate_ft_per_min` describe the
  initial climb.
- `wind_components` gives headwind or tailwind and crosswind. `notes` flag limits
  (tailwind, elevation, temperature, weight), distances exceeding what is available, and a
  crosswind above the AFM's maximum demonstrated crosswind (18 kt flaps 50, 16 kt flaps 100).
  The AFM does not consider demonstrated crosswind limiting; report it as a caution.

## Pitfalls

- Pressure altitude comes from field elevation and the altimeter. Without an altimeter, the
  result uses field elevation and says so.
- The tool has no contamination input for takeoff. Contaminated takeoff figures are not
  available here; do not borrow landing factors.
- NASR does not record grooved or PFC treatment. Pass `surface` only if the user knows it.
  Turf, dirt and gravel all use the AFM unpaved factor.
- The wind fed to the model is the steady wind in degrees true. Gusts appear only in
  warnings.

## Answer format

1. One line: ground run and total distance, against TORA and TODA, with margins.
2. A correction-factor table from the breakdowns.
3. Wind components, climb gradient and rate, and the notes.
4. An inputs table: value, origin, time (NASR cycle, METAR or TAF issue time, model hour).
5. NOTAM effects (baseline versus NOTAM) and any regression rerun.
6. The disclaimers from the result, including "for pre-flight planning only, not for
   cockpit use".

---
name: sf50-performance-limits
description: Find Cirrus SF50 Vision Jet takeoff limits with sf50_takeoff_limits — the maximum takeoff weight at given conditions, or the highest outside air temperature at which a takeoff is still possible at a weight — for one runway end or every end of an airport, with the binding constraint for each. Use for questions like "what's the max OAT before I can't take off from KTEX in either direction at MTOW?", "how heavy can I be out of Aspen this afternoon?", or comparing limits between runway directions and explaining why wind and slope make them differ.
---

# SF50 performance limits

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

- `aircraft_generation`: ask if unknown; never assume.
- `solve_for`: `temperature` (maximum OAT at `weight_lb`) or `weight` (maximum takeoff
  weight at the conditions).
- `weight_lb` for a temperature search. "MTOW" means the structural maximum takeoff
  weight, 6,000 lb for every generation in the tool's AFM data; a heavier weight is
  refused.
- `airport`, and `runway` only if the user names one. Omit `runway` to get every end,
  which answers "either direction".
- The time (performance-weather-for-time). The temperature search still uses the wind and
  altimeter at that time.

## Steps

1. **NOTAMs.** Follow notams-to-performance-inputs. Runway overrides and obstacles need a
   named `runway`, so run one call per affected end.
2. **Search.**

   ```json
   {"aircraft_generation": "g2_plus", "solve_for": "temperature", "weight_lb": 6000,
    "airport": "KTEX"}
   ```

3. **Wind comparison.** A forecast wind is a headwind one way and a tailwind the other. If
   the user asked about "either direction" or the time is far off, also run with
   `wind_speed_kt: 0` and `wind_direction_true_deg: 0` as a calm-wind baseline, labeled as
   an override.
4. **Compare with the forecast.** Get the expected OAT at the time (the performance tools'
   inputs or `get_weather`) and give the margin between the maximum OAT and the forecast.
   Say the forecast temperature is modeled when it comes from `open_meteo`.

## Reading the result

There is one result per runway end, with `max_temperature_c` or `max_takeoff_weight_lb`.
A `null` value means no value satisfies the constraints. Each has a
`binding_constraint` and its `binding_constraint_description`:

| `binding_constraint` | Meaning |
| --- | --- |
| `field_length` | Required takeoff run or distance exceeds TORA or TODA |
| `afm_data` | The AFM tables end (not available or offscale) before any other limit |
| `obstacle_clearance` | The required gradient over the supplied obstacle is not met |
| `go_around_climb_gradient` | The AFM go-around climb gradient is not met |
| `structural_limit` | The weight search reached the maximum takeoff weight |
| `temperature_limit` | The temperature search reached the operating temperature limit |
| `wind_limit` | Tailwind exceeds the limit |
| `elevation_limit` | The field is outside the approved elevation range |

- `relies_on_offscale_data: true` means the limit depends on data outside the AFM tables.
  Say so next to the figure.
- With `afm_data`, the limit is where the tables stop, not a measured performance limit.
  A rerun with `model: "regression"` extrapolates, with an uncertainty. Label it an
  extrapolation if you show it.
- The weight search stops at `minimum_weight_lb` (default 5,000 lb, the lightest weight in
  the takeoff tables). When the result is `null` with `afm_data`, an obstacle or the runway
  may be the real cause. Rerun with a lower `minimum_weight_lb` or without the obstacle to
  find out.

## Explaining direction differences

For each end, use `wind_components` and the runway inputs:

- **Wind:** a headwind shortens the distance and raises the limit; a tailwind costs much
  more than an equal headwind helps, and past the tailwind limit the end is unusable
  (`wind_limit`). Crosswind never binds: the AFM's figure is a demonstrated value, not a
  limit, so a strong crosswind shows up only as a note.
- **Slope:** `slope_percent` is positive uphill in the direction of travel. Uphill costs
  distance; downhill helps.
- **Distances:** TORA and TODA may differ by end (displaced thresholds, stopways,
  clearways).
- **Obstacles** apply only to the end you named them for.

## Answer format

| Runway | Max OAT or weight | Binding constraint | Offscale? | Wind (head/tail, cross) | Slope | TORA/TODA |
| --- | --- | --- | --- | --- | --- | --- |

Then: the overall answer (the lower of the ends, if the question is "either direction"),
the forecast margin, why the ends differ, every input with its origin and time, and the
disclaimers from the results.

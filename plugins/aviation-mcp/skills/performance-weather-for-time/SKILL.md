---
name: performance-weather-for-time
description: Work out the weather a Cirrus SF50 performance calculation will use at a departure or arrival time, and build what-if overrides. Use when a takeoff, landing, climb or takeoff-limits question gives a time such as "now", "in 18 hours" or "tomorrow at 2pm"; when converting a local time to ISO 8601 with the airport's offset; when the forecast is a U.S. TAF, which has no temperature; when TEMPO, PROB, BECMG groups, gusts or variable winds could change the answer; when an ATIS or tower wind (magnetic) must be converted to true; or when the time is beyond the forecast range.
---

# Performance weather for a time

The SF50 tools fetch weather themselves from the `time` argument. This skill makes sure
that time is right, explains where each value came from, and adds worst-case runs for
conditional forecast groups.

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

## 1. Pin the time

- Write every time as ISO 8601 with an explicit offset, such as `2026-11-05T14:00:00-07:00`,
  and give the UTC equivalent.
- Infer the airport's time zone from its position and state (`get_airport`), and say which
  zone and offset you used. Account for daylight saving time: in the U.S. it ends on the
  first Sunday in November and starts on the second Sunday in March. Arizona (outside the
  Navajo Nation) and Hawaii do not observe it.
- Resolve relative times ("in 18 hours", "tomorrow") from the current time, and state
  both.
- For "now", omit `time` or pass the current UTC time.
- Ask only when the time is truly ambiguous, such as "at 2" with no AM or PM.

## 2. What the server uses

For each weather input the performance tools record an origin and time in `inputs`:

| Time from now | Wind | Temperature | Altimeter |
| --- | --- | --- | --- |
| Within an hour of a METAR | `metar` | `metar` | `metar` |
| Covered by the TAF | `taf` | `open_meteo` | `open_meteo` |
| Past the TAF (24–30 h) | `open_meteo` | `open_meteo` | `open_meteo` |
| Past the model (about 16 days) | `weather_unavailable` | — | — |

- **U.S. TAFs carry no temperature and no altimeter.** The OAT and altimeter then come from
  the Open-Meteo model. Say so plainly; a modeled temperature is not a forecast from a
  forecaster and not an observation.
- With no altimeter, the tools read the AFM at field elevation instead of pressure altitude
  and add a note. Keep it.
- Past the model's range, ask for hypothetical temperature, wind and altimeter, run with
  overrides, and label the result hypothetical.
- To see the raw report and every TAF group, call `get_weather` with `station` and the same
  `time`. Values in `model_supplement` are modeled and must not be presented as reported.

## 3. Wind: true versus magnetic

- The tools take `wind_direction_true_deg` in degrees **true**. METAR and TAF winds are
  true.
- ATIS, tower and AWOS broadcast winds, and runway numbers, are **magnetic**. Convert a
  user's broadcast wind: true = magnetic + east variation. Take the variation from a
  runway end in `get_airport` as `heading_true_deg − heading_magnetic_deg`. For example,
  KASE runway 15 is 151° magnetic and 160° true, so the variation is 9° east.
- The tools use the NASR true runway heading, not the runway number.
- **Gusts** appear in warnings; the steady wind feeds the model. Do not take credit for
  the gust as headwind.
- **Variable winds (VRB).** The tools take the full wind speed as a tailwind along the
  runway and say so in a warning. Report that it is a worst case, or supply
  `wind_direction_true_deg` for a particular direction.
- **Missing temperature or wind.** The tools refuse (`weather_unavailable`) rather than
  assume standard-atmosphere temperature or calm wind. Supply `temperature_c`, or
  `wind_direction_true_deg` and `wind_speed_kt` (0 for calm), and label them as overrides.

## 4. Conditional groups

The server uses the prevailing forecast at the time. Check the TAF groups covering the time
with `get_weather`:

- **FM**: the group in force. The server already uses it.
- **TEMPO** and **PROB30/PROB40**: run a separate worst case with overrides for the wind
  (`wind_direction_true_deg`, `wind_speed_kt`). The temperature stays the model's.
- **BECMG**: run the conditions before and after the change when the time falls inside
  the change period.
- When the answer is close to a limit, add a sensitivity run with a warmer
  `temperature_c` override, and label it a sensitivity, not a forecast.

## 5. Report

| Field | Value | Origin | Product, issue and valid time | Modeled |
| --- | --- | --- | --- | --- |
| Wind | `<dir>`° true at `<n>` kt | `taf` | TAF issue time and FM group | no |
| Temperature | `<n>` °C | `open_meteo` | model hour | yes |

List each scenario run (prevailing, TEMPO, PROB, sensitivity) with its overrides beside its
results.

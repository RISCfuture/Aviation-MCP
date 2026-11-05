---
name: airport-briefing
description: Brief a U.S. airport for a flight with Aviation MCP data — runways and declared distances, elevation and remarks, current and forecast weather, NOTAMs for the time window, instrument approaches, departures and arrivals, airspace, and the currency of every data source. Use when the user asks to brief, review or "tell me about" an airport before a departure or arrival, wants the conditions, NOTAMs and procedures at an airport for a time, or as the first step before Cirrus SF50 performance planning.
---

# Airport briefing

## Safety

- Planning aid only. This data is not certified for navigation or dispatch, and SF50
  figures from these tools are not FAA- or Cirrus-approved and are not for cockpit use.
- Never invent, estimate or interpolate a figure the tools did not return. If something is
  missing, name it and the input that would supply it.
- Pass through every non-`value` status (`uncertain`, `offscale_high`, `offscale_low`,
  `not_available`, `not_authorized`, `invalid`), every warning and any `partial`
  completeness. Never replace them with a guess.
- List every input with its source and time: `nasr`, `metar`, `taf`, `open_meteo`,
  `override`, `isa` or `assumed`, plus NOTAM numbers and data cycles.

## Steps

1. **Data currency.** Call `get_data_status`. Report each source's effective cycle and
   availability. The server never returns expired data; an unavailable source is reported
   as such, with its reason. Say which parts of the briefing that affects.
2. **Airport.** Call `get_airport` with `identifier` (FAA or ICAO). If several airports
   share it, pick by `record_id` after confirming with the user. Report:
   - elevation (`elevation_msl_ft`), magnetic variation, tower and attendance hours;
   - each runway end: length, width, surface, `tora_ft`, `toda_ft`, `asda_ft`, `lda_ft`,
     displaced thresholds, threshold elevations (and so the slope), lighting and glide-path
     aids;
   - remarks that change operations: PPR, noise procedures, wingspan limits, wildlife,
     terrain warnings.
3. **Time.** Turn the user's time into ISO 8601 with the airport's offset, as in
   performance-weather-for-time.
4. **Weather.** Call `get_weather` with `station` and `time`.
   - Give the METAR and TAF with their issue and valid times. Only BKN, OVC and VV layers
     are ceilings; FEW and SCT are not.
   - Brief the TEMPO, PROB and BECMG groups covering the time separately from the
     prevailing forecast.
   - Values in `model_supplement` are modeled (Open-Meteo). Label them; they are not
     observations or terminal forecasts. U.S. TAFs carry no temperature.
   - Winds are in degrees true; runway numbers are magnetic.
5. **NOTAMs.** Call `query_notams` with `location`, `start` and `end` around the time,
   and follow `nextCursor` to the end. Group them as runways, taxiways, lighting and
   NAVAIDs, procedures, obstacles, airspace (TFRs from the overlying ARTCC), and other.
   Check schedules in the text against the time, and list uncertain matches separately.
6. **Procedures.** Call `find_procedures` with `airport`, by `procedure_type` (`approach`,
   `departure`, `arrival`). Circling approaches list no runway. If CIFP parse warnings
   appear, say procedures may be missing. Use `get_procedure` only for the ones the user
   will fly.
7. **Airspace.** Call `query_airspace` with `airport` for the controlled airspace around
   it, and add `altitude_ft` when a specific altitude matters.

## Answer format

1. Data currency: sources, cycles, anything unavailable.
2. Airport and runways: a table of ends with declared distances, elevation and surface.
3. Weather at the time: observed, forecast, conditional groups, modeled values labeled.
4. NOTAMs by group, with numbers, validity and schedules; uncertain matches last.
5. Procedures and airspace.
6. Items that would change an SF50 performance calculation, with a pointer to the matching
   skill (sf50-takeoff-planning, sf50-landing-and-go-around,
   sf50-departure-climb-vs-terrain, sf50-performance-limits).

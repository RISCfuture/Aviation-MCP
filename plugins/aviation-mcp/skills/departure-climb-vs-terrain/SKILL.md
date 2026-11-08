---
name: departure-climb-vs-terrain
description: Check whether a Cirrus SF50 Vision Jet or SR22 can out-climb terrain and obstacles after takeoff — climb gradient by altitude with forecast winds aloft, ground gradient along the departure course, SID or ODP climb requirements, DOF obstacles in the departure sector, and a query_terrain corridor comparison in EGM2008. Use for questions like "will I out-climb terrain taking off KASE 15 right now?", "can the SF50 make the departure's climb gradient?", "can my SR22 out-climb the terrain leaving KTRK, and how long to reach 12,000 ft?", or any SF50 or SR22 climb-versus-terrain, obstacle or mountain-departure question. Combines takeoff_performance, climb_profile, get_procedure, query_obstacles and query_terrain.
---

# Departure climb versus terrain

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

Never claim certified obstacle clearance or that a departure is safe. The SF50 and
SR22 are single-engine: these are all-engine climb figures, and there is no engine-out climb to plan
for.

## Inputs to collect

- `aircraft`, an object chosen by `type` (ask if unknown; never assume):
  - SF50: `{"type": "sf50", "generation": "g2_plus"}`, with `generation` one of `g1`, `g2`,
    `g2_updated_thrust`, `g2_plus` or `g3`.
  - SR22 (pre-G3 wing): `{"type": "sr22", "hartzell_propeller": false,
    "turbonormalized": false}`. Ask whether the aircraft has the Hartzell composite
    propeller supplement and the Tornado Alley turbonormalizing supplement; both are
    required.
- The takeoff `weight_lb`. The tool refuses weights above the aircraft's maximum.
- `airport`, `runway` and the time: for "right now", omit `time`. Otherwise use
  performance-weather-for-time.
- The departure route: a SID or ODP, a heading, or straight out. If the user gives none,
  assume runway heading straight out, and say so.

## Steps

1. **Runway.** From `get_airport`: the runway end's `heading_true_deg` and
   `heading_magnetic_deg`, its `departure_end` position, and the **departure-end
   elevation** (the reciprocal end's `threshold_elevation_msl_ft`). On a sloping runway it
   differs from the takeoff threshold: KASE 15 starts at 7,680 ft and ends at 7,838 ft.
   Also read the remarks; KASE requires PPR for takeoff on 15.
2. **NOTAMs.** Follow notams-to-performance-inputs: temporary obstacles, amended departure
   procedures or takeoff minimums, closures.
3. **Takeoff.** Run `takeoff_performance` (see takeoff-planning). The climb only
   matters if the takeoff fits the runway; report `takeoff_distance_ft` against TODA first.
4. **Climb profile.** Call `climb_profile`:

   ```json
   {"aircraft": {"type": "sf50", "generation": "g2_plus"}, "weight_lb": 5900,
    "airport": "KASE", "runway": "15", "course_true_deg": 160, "top_altitude_ft": 16000}
   ```

   - `course_true_deg`: the departure course in true (magnetic + east variation, from
     `heading_true_deg − heading_magnetic_deg`). Without it you get only still-air
     gradients.
   - `top_altitude_ft`: high enough to clear the terrain of interest. Use the SID's top
     altitude or the MEA, or the highest terrain from a first `query_terrain` call plus a
     margin. The tool refuses an altitude above the aircraft's maximum operating altitude
     (SF50 G1 28,000 ft, G2, G2+ and G3 31,000 ft; SR22 17,500 ft).
   - Read `schedules.takeoff` (SF50 91 KIAS, the steepest) and, for the SF50,
     `schedules.enroute_obstacle` (120 KIAS). The SR22 has `takeoff` and `enroute`
     schedules only; `enroute_obstacle`, `enroute_obstacle_ice` and `enroute_ice` are
     listed in `unavailable_outputs` and absent. Each schedule gives
     `minimum_ground_gradient_ft_per_nm`, `minimum_gradient_ft_per_nm` (still
     air), `ground_distance_nm` and `bands_without_gradient`. `levels` gives each 1,000 ft
     with OAT, wind aloft, gradient, ground gradient, rate and true airspeed.
   - The ready-made `query_terrain` object gives `starting_altitude_ft` (the departure end
     of the named runway, `starting_point` `departure_end`) and `gradient_ft_per_nm` for the
     takeoff schedule, rounded down, with `basis` `ground` or `still_air`. With the
     regression model it adds `gradient_uncertainty_ft_per_nm`; report it. The object is
     left out when the departure-end elevation is unknown.
   - **A tailwind lowers the ground gradient.** Winds aloft often differ from the surface
     wind; show the ground gradient, not only the still-air figure.
   - On a warm day the SF50's ice schedules are often offscale. Report it; it does not
     affect the non-ice verdict.
   - For the SR22, `time_fuel_distance_to_climb` gives `{time_min, fuel_gal, distance_nm}`
     figures from the field to the top altitude; a turbonormalized SR22 also gets
     `time_fuel_distance_to_climb_lean_of_peak`. Report them with the manual's
     configuration notes: with the Hartzell propeller the figures are optimistic. They are
     the table's difference between the two pressure altitudes, without the POH's 1.5 gal
     for start, taxi and takeoff or its 10% per 10 °C above standard; say so. Do not scale
     them to another altitude or weight.
5. **Published requirement.** Call `find_procedures` with `airport` and
   `procedure_type: "departure"`, then `get_procedure` for the SID or ODP. CIFP gives legs
   and altitude constraints but not the climb gradients printed on the chart or in the
   Takeoff Minimums and (Obstacle) Departure Procedures. Ask the user for the published
   figure, or use the **200 ft/NM** standard and state it. Compare it with the aircraft's
   minimum ground gradient up to the altitude the requirement applies to.
6. **Obstacles.** Call `query_obstacles` with `airport`, `runway`, `radius_nm` (for
   example 10) and `order: "highest"`. It searches a sector splayed 15° either side of the
   runway course from 500 ft either side of the departure end; it is not a TERPS
   assessment.
   - Compare MSL with MSL: altitude available at an obstacle = departure-end elevation +
     ground gradient × distance from the departure end (NM). Margin = that minus
     `elevation_msl_ft`. `height_agl_ft` is the structure's own height, not its height above
     the runway.
   - For the most limiting obstacle, rerun `takeoff_performance` with
     `obstacle_height_ft` (elevation MSL minus departure-end elevation) and
     `obstacle_distance_ft` (from the departure end, in feet) to get the manual-based required
     gradient and `cleared`.
7. **Terrain.** Call `query_terrain`:
   - `route`: the departure end first, then points along the departure path. Use SID fix
     positions, or project points with `compute_geometry` (`operation: "destination"`,
     `course_true_deg`, `distance_nm`). At most 20 points.
   - `half_width_nm`: at most **2 NM**. Wider areas are not covered; say so.
   - `starting_altitude_ft`: the departure-end elevation, never lower. This ignores the
     50 ft screen height, which is conservative.
   - `gradient_ft_per_nm`: the climb profile's takeoff-schedule ground gradient (the
     `query_terrain` object's value).
   - `clearance_ft`: state your choice; use 0 for a bare terrain comparison.
   - `vertical_datum`: `EGM2008`. Terrain heights are above the EGM2008 geoid; charted MSL
     elevations are close but not identical, so margins of a few tens of feet are
     inconclusive.
   - Read `climb.status`: `conditional_clearance_met`, or `not_established`, which is
     inconclusive and not proof of a conflict. Report `limiting.minimum_margin_ft`, its
     position and `distance_lower_bound_nm`, the corridor `maximum`, and coverage gaps.
     Distance is measured radially from the first point, which is conservative for a
     turning path.
   - The terrain model includes buildings and vegetation but not DOF obstacles or NOTAM
     cranes; step 6 covers those.

## Answer format

1. Verdict: "On these inputs, the `<aircraft>`'s takeoff-schedule ground gradient of `<n>` ft/NM
   (still air `<n>`) meets / does not meet / does not establish..." for the published
   requirement, the obstacles and the terrain, separately.
2. Takeoff distance against TODA.
3. A climb table by altitude: gradient, ground gradient, rate, wind aloft.
4. Limiting terrain and obstacles with margins and positions.
5. For the SR22, time, fuel and distance to climb.
6. Inputs with origin and time, NOTAMs, and the disclaimers from the results, including the
   manuals' configuration notes.

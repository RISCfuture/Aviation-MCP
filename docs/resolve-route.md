# `resolve_route` specification

Status: implemented on the `resolve-route` branch; not yet merged or deployed.

## Purpose

`resolve_route` turns a filed route string such as `KOAK SNS V25 PRB KSBP` into
ordered route elements, legs with distances and courses, and a
`[longitude, latitude]` path.

`query_airspace`, `query_obstacles`, `query_terrain` and `compute_geometry` all
take a route as raw coordinate pairs. Today a client has to build that path
itself by chaining `get_airport`, `find_navigation`, `get_airway` and
`get_procedure`, choosing among duplicate identifiers along the way. This tool
does that once, on one pinned data snapshot, and reports every choice it made.

It is a lookup and geometry tool. It does not validate that a route is flyable,
legal, or acceptable to ATC, and it does not assess obstacle or terrain
clearance.

## Scope

- **United States only.** Every element is resolved against FAA NASR and CIFP,
  which cover U.S. airports, fixes, navaids, airways and procedures. A foreign
  airport, fix or airway is returned as unresolved, never approximated. The
  tool description says so, so a client does not read an unresolved foreign
  element as a typing error.
- **No approaches.** A route ends at its last arrival fix or at the destination
  airport's reference point. Approach and approach-transition elements are not
  part of the grammar. Use `find_procedures` and `get_procedure` for them.
  Approach support is tracked as a future addition; see
  [Future work](#future-work).
- **Never guesses.** An identifier with more than one possible match is
  returned with its candidates and left unresolved until the client selects
  one.

## Tool definition

| Field | Value |
| --- | --- |
| Name | `resolve_route` |
| Title | Resolve a route string |
| Group | `navigation` |
| Sources | `nasr` always; `cifp` only when the route names a departure or arrival |
| Annotations | read-only, idempotent, not open-world |

Description shown to clients:

> Resolve a U.S. route string of airports, fixes, navaids, airways, departures,
> arrivals and coordinates into ordered legs with distance and course, and a
> `[longitude, latitude]` path usable as the `route` of `query_airspace`,
> `query_obstacles` and `query_terrain`. Covers FAA data only, so foreign
> elements are unresolved; approaches are not included. Ambiguous identifiers
> return candidates and are never guessed; select them with `selections`.

## Input

| Parameter | Type | Required | Meaning |
| --- | --- | --- | --- |
| `route_string` | string, 3–1024 characters | yes | Route elements separated by spaces or dots. At most 60 elements. |
| `departure_runway` | string | no | Runway used to select a departure's runway transition, such as `28R`. |
| `arrival_runway` | string | no | Runway used to select an arrival's runway transition. |
| `selections` | array of `{index, record_id}` | no | Chooses one candidate for the element at `index` (zero-based), using an `id` from an earlier result's `candidates`. |
| `include_geometry` | boolean, default `false` | no | Adds a densified GeoJSON `MultiLineString`, split at the antimeridian, as `compute_geometry` produces. |

The parameter is `route_string` rather than `route` because `route` already
means a coordinate array in four other tools.

There is no pagination. The tool returns one result record and never a
`nextCursor`.

## Route grammar

Elements are case-insensitive and are classified in this order.

| Element | Example | Rule |
| --- | --- | --- |
| Speed and level group | `N0450F350` | Recognised by pattern, reported, and otherwise ignored. Also accepted as a `/N0450F350` suffix on a fix. |
| Direct | `DCT` | Joins its neighbours with a geodesic leg. Two adjacent points with no `DCT` between them are joined the same way. |
| Coordinate | `3730N12200W`, `37N122W` | ICAO degrees or degrees and minutes. |
| Place, bearing, distance | `SNS090020` | A navaid, a three-digit magnetic bearing and a three-digit distance in NM. Navaids only; see [Place, bearing, distance](#place-bearing-distance). |
| Airport | `KOAK`, `OAK` | Only as the first or last element. Matched by FAA location identifier or ICAO code. |
| Departure | `PORTE3` | Only directly after the origin airport, or after a runway that follows it. Matched against that airport's CIFP departures by computer code. |
| Arrival | `SADDE8` | Only directly before the destination airport, or before a runway that precedes it. Matched against that airport's CIFP arrivals. |
| Runway | `20C`, `18R` | Only between the origin and its departure (`KBNA 20C.DANLS5.TPEEE`) or between an arrival and the destination (`WINDU.SEWZY6.18R KAUS`). It chooses the runway transition, as `departure_runway` and `arrival_runway` do. |
| Airway | `V25`, `J80`, `T319` | Must follow a point. Matched against NASR `airway` records. |
| Fix or navaid | `GOSHI`, `SNS` | NASR `fix` and `navaid` records. |

An identifier that matches both an airway and a fix is an airway when the
previous element is a point on that airway, and a fix otherwise.

At either end of the route an identifier is looked up among airports, fixes and
navaids together. A three-letter identifier is often both an airport and a
navaid (`OAK` is Oakland's airport and its VOR), and the tool does not prefer
one. Such an element returns both as candidates unless an adjacent airway or
arrival anchors it. The four-letter ICAO code (`KOAK`) names only the airport.

## Resolution rules

### Airways

An airway is traversed from the preceding point to the following point, in
travel order, using the same logic as `AirwayExpansion`. Entry and exit points
come from the airway's own `segments`, so a fix identifier shared with another
fix elsewhere is not ambiguous here.

- If several airway records share the designation, the one containing both
  points is used. If more than one does, the element returns candidates.
- Two adjacent airways with no fix between them join at their shared point
  when exactly one exists. With none or several, the element is unresolved.
- A segment flagged `airway_gap`, or lacking a position, breaks the path there.
  `mea_unusable` segments stay in the path and raise a warning.
- The point where the route joins an airway must be the same point the route
  has already reached. When a previous airway or procedure places a fix of that
  name somewhere else, the two share only an identifier, and the airway is
  unresolved.
- An airway whose geometry the importer withheld because of parse errors is
  unresolved. Its surviving points are not joined, since a point between them
  may be missing.

Each airway leg carries the published segment distance, the magnetic course
for the direction flown, and the segment's whole `altitudes` object (MEA, MOCA,
MAA and their opposite-direction values) with `airway_direction` set to
`published` or `reversed`. The tool does not pick the directional altitude; the
client reads the one that applies.

### Departures and arrivals

Procedure records are stored one per transition, plus a common route. The
ordering follows `ProcedureExpansion`: for a departure, runway transition,
common route, then en route transition; for an arrival, the reverse.

- The en route transition is the one whose name matches the adjacent route
  element. If none matches, the procedure is joined at the end of its common
  route with a direct leg. When the procedure does publish en route
  transitions, a warning names them.
- The runway transition is chosen with `departure_runway` or `arrival_runway`,
  using `RunwayName.matches`. A procedure with a single runway transition uses
  it. With several and no runway, or a runway that matches none, no runway
  transition is used: a warning names the argument, and the path breaks between
  the airport and the common route so that no leg is drawn across the omitted
  transition.
- A runway written in the route and the matching argument must agree; a
  disagreement is an `invalid_argument` error. A runway that is not beside a
  departure or arrival is unresolved.
- Many procedures publish no common route, only transitions. Such a procedure
  is flown on its runway transition alone when no en route transition is named,
  and is unresolved only when it has neither.
- The leg into an arrival's first fix is a direct leg; every later leg is the
  arrival's. Every leg of a departure, including the one from the airport, is
  the departure's.
- Only an initial fix (`IF`) and a track to a fix (`TF`) are drawn, the same
  standard as the published procedure geometry. Every other leg splits the
  path and is listed in `geometry_gaps` with its sequence, path terminator and
  reason:
  - a leg with no fix position (`VA`, `VI`, `CA`, `VM`) contributes no point;
  - a leg that ends at its fix along an arc or a course (`RF`, `AF`, `CF`,
    `DF`), or after a hold (`HA`, `HF`), splits the path before the fix;
  - a leg that starts at its fix and ends somewhere unpublished (`FM`, `FA`,
    `FC`, `FD`, `HM`, `PI`) splits the path after the fix, so an arrival ending
    on such a leg is not joined to the destination airport;
  - any other leg with a fix is cut off on both sides.

  A leg at the fix the path has already reached, such as a hold there, adds
  nothing and splits nothing.
- A procedure whose geometry the importer withheld because of parse errors is
  unresolved, and the elements beside it resolve on their own.
- Approaches are out of scope. The path ends at the last arrival fix or the
  destination airport's reference point.

### Fixes and navaids

A fix or navaid that is not anchored by an adjacent airway or procedure is
looked up by exact identifier. VOR test facilities (VOTs) are excluded: they
share their airport's identifier but radiate a test signal and are not points to
navigate to.

1. One match: use it.
2. Several matches: the element is unresolved. It returns every match in
   `candidates`, each with its `id`, kind, name, position and its distance from
   the adjacent resolved points, and the path breaks there until the client
   supplies a `selections` entry.

The tool never picks a candidate by proximity, however obvious the choice
looks. A wrong automatic choice would silently move the path that terrain and
obstacle queries are run against. The distances in `candidates` let the client
make the choice, and state it, in one further call.

### Place, bearing, distance

`SNS090020` means the point 20 NM from the SNS navaid on its 090° magnetic
bearing. The place must be a navaid.

The bearing is magnetic, and projecting the point needs a true course. NASR
publishes `magnetic_variation_deg` for navaids, which is also the variation the
navaid's radials are aligned to. Fix records carry no variation, and the tool
does not model the magnetic field, so a bearing from a fix cannot be converted
without inventing a figure.

- A place that is a fix, or a navaid with no published variation, is
  unresolved, with a reason naming the missing variation.
- The point is projected with `Geodesy.destination` on the true course
  `bearing + variation` (east positive). The element reports the variation and
  the true course used.
- A navaid identifier with several matches follows the rules above and returns
  candidates.

### Unresolved elements

An element that matches nothing, or is ambiguous, does not fail the call. It is
returned with `kind` `unresolved`, the reason, and any candidates. The path
breaks around it, `completeness` is `partial`, and a warning names the element
by index and text.

## Output

The standard envelope (`results`, `sources`, `completeness`, `warnings`,
`retrievedAt`) carries one result record:

```json
{
  "route_string": "KOAK SNS V25 PRB KSBP",
  "elements": [
    {
      "index": 1, "text": "SNS", "kind": "navaid", "identifier": "SNS",
      "record_id": "…", "resolution": "unique",
      "position": {"type": "Point", "coordinates": [-121.6, 36.66]}
    }
  ],
  "legs": [
    {
      "sequence": 2, "via": "V25", "via_kind": "airway",
      "from": "SNS", "to": "…",
      "distance_nm": 18.2, "published_distance_nm": 18,
      "initial_course_true_deg": 141.3, "published_course_magnetic_deg": 128,
      "airway_direction": "published",
      "altitudes": {"unit": "ft", "datum": "MSL", "mea": 5000},
      "path_index": 0, "start_point_index": 1
    }
  ],
  "paths": [[[-122.22, 37.72], [-121.6, 36.66]]],
  "total_distance_nm": 171.4,
  "distance_complete": true,
  "geometry_gaps": [],
  "ignored": [{"index": 0, "text": "N0450F350", "kind": "speed_level"}]
}
```

The values above illustrate the shape only; they are not source data.

- `elements` has one entry per input element, in order, including ignored and
  unresolved ones. `resolution` is `unique`, `anchored` (taken from an adjacent
  airway or procedure), `selected` (from `selections`) or `unresolved`.
- `kind` is `airport`, `fix`, `navaid`, `airway`, `airway_point`, `departure`,
  `arrival`, `procedure_fix`, `coordinate`, `place_bearing_distance`, `direct`,
  `speed_level` or `unresolved`.
- Candidate distances (`distance_from_previous_nm`, `distance_to_next_nm`) are
  spherical approximations to help choose, not leg measurements.
- `legs` has one entry per pair of consecutive path points. `from` and `to` are
  identifiers; a leg's coordinates are `paths[path_index]` at
  `start_point_index` and the point after it. Legs carry no GeoJSON positions
  because responses bound GeoJSON to 32,768 bytes per record, which a long
  route would exceed. `distance_nm` and
  `initial_course_true_deg` are WGS84 geodesic values computed in PostGIS, as
  in `compute_geometry`. Published airway values are reported beside them and
  never substituted for them.
- `paths` is an array of contiguous runs of `[longitude, latitude]` points. A
  fully resolved route has exactly one run. A gap starts a new run, so a client
  cannot draw a straight line across unresolved geometry by accident.
- `total_distance_nm` sums the resolved legs. `distance_complete` is `false`
  when any gap exists.
- Magnetic courses appear only where the source publishes them. The tool does
  not derive magnetic courses from true ones.

### Size limits

`query_airspace` and `query_obstacles` accept 200 route points, and
`query_terrain` accepts 20 points and 500 NM. When a run exceeds 200 points the
result stays complete, and a warning says to split it by leg using each leg's
`path_index` and `start_point_index`. The tool does not simplify the path,
because simplification would move it.

## Completeness, warnings and errors

| Situation | Outcome |
| --- | --- |
| Every element resolved, no gaps | `complete` |
| Unresolved or ambiguous element, geometry gap, skipped runway transition, or source parse-coverage warnings | `partial`, with a warning per cause |
| Route names a departure or arrival and CIFP is unavailable | `partial`; the rest of the route resolves, and the procedure element is unresolved with the source's unavailability reason |
| NASR unavailable | `data_unavailable` error |
| Empty route, more than 60 elements, a `selections` index out of range, or a `record_id` that is not a candidate for its element | `invalid_argument` error naming the element |

`sources` lists `nasr`, and `cifp` only when a procedure was read.

## Implementation

All lookups run inside one `store.withSnapshot` call so every element comes
from the same NASR and CIFP versions.

- `Tools/RouteGrammar.swift`: splits and classifies elements by form. Pure,
  with no database access.
- `Tools/RouteAssembly.swift`: resolves elements against the records that could
  match them and assembles points, gaps and warnings. Pure, so its rules are
  tested without a database.
- `Tools/RouteResolver.swift`: the database side. It issues at most four
  queries per call: one for every airport, fix, navaid and airway identifier in
  the route, one for the origin and destination procedures, one PostGIS query
  measuring all legs, and one for `include_geometry`.
- `ToolDefinition.swift`, `ToolSchemas.swift` and `ToolCatalog.swift`: the
  tool's definition, parameters and dispatch.
- It follows `AirwayExpansion`'s endpoint logic and `ProcedureExpansion`'s
  transition ordering, and uses `RunwayName` and `Geodesy` directly.

Still to do after deployment, because they record the deployed server:
refresh the eval mock `plugins/aviation-mcp/evals/mocks/aviation/_tools.json`
and its `_server.md` tool list, and add the tool to `plugins/verification.md`
and `site/examples-verification.md`. The `departure-climb-vs-terrain` skill is
the first candidate to use the tool.

## Tests

Grammar and assembly tests are in `RouteTests.swift` and need no database;
catalog tests are in `RouteToolTests.swift` and need PostGIS.

`RouteResolutionTests.swift` runs every route in
`Tests/AviationMCPTestData/RouteResolutionTests.txt` through the catalog
against real FAA records. Those records are in `RouteResolutionRecords.jsonl`
beside it, exported from a fully ingested cycle by
`scripts/export-route-fixture.sh`. Each route has a pinned expectation
(completeness, unresolved elements, path sizes and total distance); a route
without one fails the test. After adding a route, rerun the script and add its
expectation.

Grammar tests:

- each element kind is classified, including dot separators and the speed and
  level suffix;
- an identifier that is both an airway and a fix is classified by context;
- element and length limits are enforced.

Assembly and catalog tests:

- `SNS V25 PRB` returns the same ordered points as `get_airway` with
  `entry_fix` and `exit_fix`, in both directions (acceptance case 3);
- a duplicated fix identifier resolves when anchored by an airway, and
  otherwise returns candidates with distances and is never auto-selected, even
  when one candidate is far nearer than the rest;
- a place, bearing, distance element resolves from a navaid using its published
  variation, and is unresolved from a fix or from a navaid without variation;
- a foreign airport or fix is unresolved and the rest of the route resolves;
- `selections` resolves a candidate, and rejects an `id` that was not offered;
- an airway gap splits `paths` into two runs and sets `distance_complete` to
  `false`;
- a departure with a matching en route transition is ordered runway, common,
  en route; without `departure_runway` the runway transition is skipped with a
  warning;
- a heading-defined procedure leg appears in `geometry_gaps`;
- a route naming a departure resolves the remainder when CIFP is absent;
- a resolved run passes unchanged as `route` to `query_airspace`.

## Future work

- **Approaches.** Appending a named approach and transition to the route would
  let one call cover a route from runway to runway. It is left out of this
  version to keep the grammar small. A GitHub issue is to be filed for it.

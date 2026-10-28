# Acceptance cases

These cases come from the original task at
`/Users/tmorgan/Desktop/prompts/aviation-mcp.txt`. They are requirements, not
completed tests. Assertions must use pinned fixtures and representative ingested
datasets; no hard-coded current aviation answers substitute for source data.

1. “What approaches are there into KOAK and what do I cross the IAF at?”
   Search approaches by airport, then expand selected transitions. Preserve
   altitude constraints, datums, path terminators and missed-approach boundaries.
2. “What's the tallest obstacle within 5 NM of the departure end of runway 29?”
   Resolve the airport ambiguity, locate the departure end, perform a 9,260-meter
   geography radius query and order by MSL elevation. Return AGL separately.
3. “What's on V25 between SNS and PRB?”
   Resolve navigation identifiers and return airway segments in traversal order,
   including restrictions and every source version used.
4. “Which NOTAMs affect my arrival into KSFO tomorrow morning?”
   Resolve the time window and timezone, query overlapping effective periods,
   preserve schedules and text, and explain uncertain runway/procedure matches.
5. “What approach category is a B738?”
   Resolve ICAO type and aircraft variants, retain published category provenance
   and distinguish missing source data from a negative result.

## Squawk comparison checklist

Prior art is [Squawk](https://github.com/neilcochran/squawk), specifically
`packages/libs/mcp/src/tools` and its underlying resolver packages.

- Airport identifier, text and proximity searches; runway length, facility and
  public/private filters; frequencies, declared distances, pavement and ILS.
- Fix/navaid ambiguity, proximity and search; airway traversal between endpoints.
- Airspace geometry and geographic boundary behavior.
- Procedure identifier, airport, approach type and runway searches; parallel
  runway `B` matching and `ALL` transitions.
- SID runway/common/enroute order, STAR enroute/common/runway order and approach
  transition/final/missed sequencing; explicit unresolved geometry gaps.
- Bounded coordinate conversion, distance, bearing and route geometry.

Source parity remains unverified until ingestion mappings and behavioral checks
cover these capabilities.

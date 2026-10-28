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

## Public deployment checks on October 28, 2026

The deployed image for commit `6ae4909` passed TLS, readiness and eight-tool
catalog checks. Public B738 lookup and an explicit KSFO NOTAM overlap window
exercised cases 4 and 5. A coordinate-centered 5 NM obstacle query returned
MSL-ordered DOF records; case 2's runway context remains blocked on paired
NASR/CIFP publication, as do cases 1 and 3.

AWC-only, Open-Meteo-only and default combined weather queries succeeded. The
combined response kept AWC's temperature and supplemented modeled pressure
levels, with field provenance and attribution. Repeating it used cached data
without reducing the locally tracked Open-Meteo daily budget. Supplied METAR
parsing, UTM/MGRS conversion and an antimeridian geodesic query also passed.
An unapproved Origin received HTTP 403. Concurrent calls reused JSON-RPC ID 1
and returned the corresponding independent results.

The endpoint serves the already validated DOF and aircraft snapshots, retaining
their original parser provenance. GitHub's ingestion image now includes the new
parser pins; scheduled ingestion will revalidate and replace those snapshots.
CIFP's known source rejections remain an explicit publication failure.

# Website example verification

Checked on October 28, 2026 (October 29 UTC). These checks exercise the MCP
calls needed to answer the displayed questions; they do not guarantee how a
particular ChatGPT or Claude model selects tools or phrases its answer.
Live reports and NOTAMs change over time.

## Environments

All examples were exercised through `https://aviation-mcp.org/mcp`. Denver
airports, Boston procedures, Austin airspace, Chicago NOTAMs, and Southeast
weather were checked at approximately 23:02–23:03 PDT. Aircraft was checked at
21:42 PDT; navigation and the route-based examples at 22:42–22:44 PDT.
The public endpoint advertises all 17 tools. Each final example query returned
HTTP 200, `isError: false`, and the expected usable results.

The public navigation data is FAA cycle 2026-10-29: 171,436 NASR records and
55,181 CIFP records. All 226,617 records published atomically. Three NASR field
errors and three CIFP record/aggregation errors remain visible in source
diagnostics and produce partial results. Airport and procedure positions used
for obstacle, terrain, and distance queries came from the public MCP responses.

The obstacle queries use the available DOF release effective September 29
through November 24. A re-import with the recovery adapter rolled back after a
maintenance deadlock; the previously published, still-effective version remains
available. These checks establish usable tool responses, not complete source
coverage or a latency guarantee.

## Results

| Example       | Tool calls                                                                                                                                  | Observed result                                                                                                                                                                            |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Airports      | `get_airport`: `KDEN`                                                                                                                       | Six concrete runways: five 12,000 ft runways and 16R/34L at 16,000 ft.                                                                                                                     |
| Procedures    | `find_procedures` for `KBOS`, then `get_procedure`: airport `KBOS`, identifier `I04R`, transition `GOSHI`                                   | GOSHI is published at 6,000 ft MSL; the transition and common route retain their separate leg constraints.                                                                                 |
| Navigation    | `get_airway`: `V25`, entry `SNS`, exit `PRB`                                                                                                | SNS → CASRA → HAGRO → WIGGL → LUCAB → PRB, with source segment data.                                                                                                                       |
| Airspace      | `query_airspace`: identifier `KAUS`, kinds `["airspace"]`                                                                                   | Two Class C definitions: surface–4,500 ft MSL and 2,100–4,500 ft MSL.                                                                                                                      |
| NOTAMs        | `query_notams`: `KORD`, current UTC time through six hours later, limit 200                                                                 | 138 notices, complete response with no next cursor.                                                                                                                                        |
| Weather       | Three `get_weather` calls: `KATL`, `KCLT`, `KRDU`; source `awc`; wind, visibility, cloud layers                                             | Complete comparison fields with observation times and provenance. KCLT has the lowest ceiling (6,000 ft AGL); KRDU the lowest reported visibility (7 SM); KATL the strongest wind (11 kt). |
| Aircraft      | `get_aircraft`: `SF50`                                                                                                                      | Length 30.7 ft, wingspan 38.7 ft, tail height 10.9 ft.                                                                                                                                     |
| Obstacles     | `get_procedure` and `get_airport` for KHAF, then `query_obstacles` with the WOHLI–MAVKC–RW30 route, 1 NM radius, highest ordering, limit 10 | Ten obstacles, ordered by MSL elevation. Highest: obstacle 06-259247, 323 ft MSL and 47 ft AGL.                                                                                            |
| Terrain       | `get_airport` for `KTRK` and `KMMH`, then `query_terrain` with those positions and a 1 NM half-width                                        | Complete coverage of 1,123,030 cells. Maximum 9,120.52 ft EGM2008 at 37.86278°N, 119.00722°W.                                                                                              |
| Geography     | `get_airport` for `KJFK` and `KLAX`, then `compute_geometry`, operation `distance`                                                          | WGS84 geodesic distance 2,150.63 NM; initial true bearing 273.89°.                                                                                                                         |
| Source status | `get_data_status`                                                                                                                           | Current NASR/CIFP versions include error counts and diagnostic samples. A KUIN R31 query explicitly retains its parsing-gap warning and withholds affected geometry.                       |

## Procedure path and source limits

WOHLI and MAVKC positions come from the CIFP procedure legs. The runway leg is
not resolved by SwiftCIFP's generic fix resolver, so the RW30 position comes
from the published runway 30 displaced threshold in `get_airport`. The verified
obstacle query uses those three points explicitly; it does not assume that a
procedure-ID query covers an unresolved runway leg. The [FAA RNAV (GPS) RWY 30
chart](https://aeronav.faa.gov/d-tpp/2610/06675R30.PDF) was also checked for the
named final-approach sequence.

The terrain example uses Truckee–Mammoth Yosemite. Truckee–Bend exceeded the
current native-pixel budget and returned partial coverage, so it is not used as
the showcased complete-corridor example. Terrain elevations use EGM2008 and do
not establish certified obstacle clearance. Aircraft characteristics are type
data, not tail-number registration data or an AFM performance calculation.

Aviation coverage on the website is U.S. only; terrain coverage is worldwide.
Coordinate calculations are mathematical operations, not an additional aviation
dataset. The copied questions use airport and fix identifiers rather than
requiring readers to supply latitude/longitude pairs.

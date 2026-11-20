# Directory verification

MCP Inspector 2.12.0 exercised all 17 tools against
<https://aviation-mcp.org/mcp> on October 29, 2026 UTC. Each final call returned
`isError: false` and nonempty structured results. These are tool-level checks;
they do not establish how ChatGPT or Claude selects tools or summarizes results.

| Tool | Inputs | Result |
| --- | --- | --- |
| `find_airports` | KDEN | One airport; partial source coverage |
| `get_airport` | KDEN | Airport and runways; partial source coverage |
| `find_navigation` | SNS, navaid | One record; partial source coverage |
| `get_airway` | V25, SNS to PRB | Ordered airway; partial source coverage |
| `find_routes` | Preferred routes, limit 3 | Three records; partial source coverage |
| `query_airspace` | KAUS, airspace | Two records; partial source coverage |
| `find_procedures` | KBOS approaches | 42 records; source and geometry warnings |
| `get_procedure` | KBOS, I04R, GOSHI | One procedure; source and geometry warnings |
| `query_obstacles` | KHAF WOHLI–MAVKC–RW30 path, 1 NM, highest first | Ten obstacles, complete |
| `get_aircraft` | SF50 | One record, complete |
| `get_weather` | KATL, AWC, wind/visibility/cloud fields | One report, complete |
| `parse_weather` | Supplied KATL METAR and explicit reference time | Parsed report, marked client-supplied |
| `query_notams` | KORD, current six-hour window | 138 notices, complete |
| `convert_coordinates` | Denver coordinates to UTM | One conversion, complete |
| `compute_geometry` | JFK to LAX airport positions | One distance/bearing result, complete |
| `get_data_status` | No arguments | Five sources available; NASR/CIFP partial |
| `query_terrain` | KTRK to KMMH airport positions, 1 NM half-width | One corridor analysis, complete |

The partial NASR/CIFP results expose three parsing diagnostics per source in the
2026-10-29 cycle. Procedure geometry gaps remain explicit. The DOF recovery import
succeeded in ingestion run
[40824999908](https://github.com/RISCfuture/Aviation-MCP/actions/runs/40824999908);
the public status response reports 656,884 obstacles and no parse errors using
`dof-adapter-4`.

An unpaced Inspector batch reached the server's admission limit. Paced retries
succeeded. Three connection timeouts were retried with Node's IPv4-first DNS
ordering and succeeded. The strict discovery check found zero schema errors and
17 identical portability warnings: the shared `rateLimits` output property uses
the legal JSON Schema union `type: ["array", "object"]`.

Airport and procedure coordinates for route queries came from the public MCP
responses. Detailed example outcomes and procedure-path limits are in
[website verification](../site/examples-verification.md). Live counts and weather
values change; successful queries do not certify flight safety or completeness
of upstream data.

## Performance tools

On November 20, 2026 UTC, direct calls to the production endpoint exercised the four
aircraft-neutral performance tools for both aircraft. Each returned structured results
with input origins, the manuals used, and the planning-only disclaimer. These are
tool-level checks; they do not establish how a client selects tools.

| Tool | Inputs | Result |
| --- | --- | --- |
| `takeoff_performance` | SF50 G2+, 5,800 lb, KOAK 28R, forecast time | Ground run and distance with wind and slope breakdowns; NASR, TAF and Open-Meteo origins |
| `takeoff_performance` | SR22, 3,600 lb, KOAK 28R | `invalid_argument`: above the 3,400 lb maximum takeoff weight |
| `climb_profile` | SF50 G2+, 5,900 lb, KASE 15, course 150° true, to 14,000 ft | Gradients for all five schedules; takeoff schedule offscale above 10,030 ft, reported as such |
| `landing_performance` | SR22, Hartzell propeller, turbonormalized, 3,400 lb, KASE 15 | Landing distance with balked-landing climb; Vref and go-around gradient listed as unavailable |
| `takeoff_limits` | SF50 G2+, 6,000 lb, KTEX, solve for temperature | Maximum OAT for runways 09 and 27, each limited by field length |

## ChatGPT client review, 1.2.0

On November 20, 2026 UTC, the 1.2.0 **Aviation Data** plugin, installed in the ChatGPT
desktop app from this repository's marketplace, ran the eight review cases against the
production endpoint. Production logs confirm the tool calls.

| Scenario | Observed result |
| --- | --- |
| KDEN runways | Six concrete runways; 16R/34L 16,000 ft, the rest 12,000 ft; NASR cycle cited |
| KBOS I04R at GOSHI | 6,000 ft MSL and 210 kt through `get_procedure` with the GOSHI transition |
| KATL–KCLT–KRDU weather | Observation times for each station; a scattered layer not treated as a ceiling |
| SF50 takeoff, KOAK 28R | UTC time, NOTAMs for 28R and 10L, correction multipliers, input origins with modeled OAT, margins against TORA and TODA, disclaimer |
| SF50 climb versus terrain, KASE 15 | Closure NOTAM found; climb gradients; terrain within ½ NM of track and DOF tower compared MSL to MSL; result called inconclusive; no clearance claim |
| Flight-plan submission | Said the plan was not filed and the plugin cannot file one |
| Missing airport for runway 29 | Asked which airport before any query |
| Safety certification | Refused to certify; offered bounded analysis and asked for inputs |

The SF50 climb answer used the enroute-obstacle schedule because the takeoff schedule's
table ends above 10,000 ft at KASE. While Open-Meteo was briefly unreachable, an earlier
SF50 takeoff attempt returned `weather_unavailable`; the client then supplied its own
temperatures, as the error directs.

The demo at `site/public/review/aviation-data-1.2.0-demo.mp4` records the SF50 takeoff
question and an SR22 maximum-temperature follow-up at KTRK runway 20 in the same client.

## ChatGPT client review, 1.0.0

On October 29, 2026 UTC, the private **Aviation Data Review** connector exercised
the production endpoint in ChatGPT. This is the same endpoint configured in the
public **Aviation Data** draft. The recorded walkthrough shows actual completed
conversations, including the weather correction; it is not a simulated transcript.

| Scenario | Observed result |
| --- | --- |
| KDEN runways | Six concrete runways; five 12,000 ft and 16R/34L 16,000 ft, with NASR cycle |
| KBOS I04R at GOSHI | 6,000 ft MSL, 210 KIAS, transition context and CIFP cycle |
| KATL–KCLT–KRDU weather | Correct ceiling, visibility and wind comparisons; classification correction required |
| KORD next six hours | Explicit 0812–1412Z window, runway/taxiway and procedure restrictions, retrieval time |
| KTRK–KMMH terrain | 9,121 ft EGM2008 maximum, location and complete corridor coverage; no clearance claim |
| Flight-plan submission | Refused filing through this read-only aviation plugin; did not claim submission |
| Missing airport for runway 29 | Asked which airport before an obstacle query |
| Safety certification | Refused to certify terrain/obstacle clearance and described bounded analysis |

The weather response initially called KRDU VFR despite correctly reporting 4 SM
visibility. A follow-up corrected it to MVFR without changing the observations.
A direct production tool query also returned the correct visibility. This is a
model interpretation failure, not evidence that every generated briefing is
accurate. The NOTAM summary was inspected, but complete pagination behavior was
not independently established from the client trace.

The Swift MCP SDK rejects object-valued experimental client capabilities during
initialization. The server ignores unsupported experimental capabilities; it
implements none. The reproduction failed before the workaround and passed
afterward. Linux CI passed all 45 tests with PostGIS, and the production probe
and ChatGPT connector setup succeeded. The defect is documented in the local
Swift SDK checkout's `AVIATION-MCP-BUGS.md`.

Claude discovery and Inspector checks succeeded. Conversation testing inside
Claude was unavailable because the account had reached its weekly usage limit;
the submission's testing acknowledgment is based on Inspector.

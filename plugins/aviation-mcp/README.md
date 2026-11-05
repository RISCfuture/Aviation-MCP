# Aviation MCP plugin

This plugin connects Claude or ChatGPT to [Aviation MCP](https://aviation-mcp.org), a
public, read-only MCP server for U.S. aviation data from FAA sources: airports, runways,
navigation, airspace, instrument procedures, obstacles, aircraft characteristics, weather
and NOTAMs. It also covers worldwide Copernicus terrain and Cirrus SF50 Vision Jet takeoff,
landing, climb and takeoff-limit calculations. Every result names its source cycles,
provenance and coverage gaps. No account is needed.

## Contents

- `.mcp.json` (Claude) and `mcp.json` (OpenAI): the server at
  `https://aviation-mcp.org/mcp`.
- `skills/`: workflows that combine the tools.

| Skill | Use it for |
| --- | --- |
| `airport-briefing` | Runways, weather, NOTAMs, procedures, airspace and data currency |
| `notams-to-performance-inputs` | Turning NOTAMs into performance overrides |
| `performance-weather-for-time` | The weather a calculation uses at a given time, and worst cases |
| `sf50-takeoff-planning` | Ground run, total distance and correction factors |
| `sf50-landing-and-go-around` | Landing distance and missed-approach climb versus terrain |
| `sf50-departure-climb-vs-terrain` | Out-climbing terrain and obstacles after takeoff |
| `sf50-performance-limits` | Maximum takeoff weight or OAT for each runway end |

## Install in Claude Code

```text
/plugin marketplace add RISCfuture/Aviation-MCP
/plugin install aviation-mcp@aviation-mcp
```

## Limits

Aviation MCP is for research and pre-flight planning. It is not certified for navigation,
dispatch or obstacle clearance. SF50 figures are not approved by the FAA or Cirrus Aircraft
and are not for cockpit use.

- Privacy: <https://aviation-mcp.org/privacy/>
- Terms: <https://aviation-mcp.org/terms/>
- Support: <https://aviation-mcp.org/support/>

## License

MIT; see [LICENSE](LICENSE).

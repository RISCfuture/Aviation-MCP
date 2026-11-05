# Aviation MCP directory submissions

`aviation-mcp/` is one plugin for both ChatGPT and Claude. Both MCP configurations
point to the public, unauthenticated production endpoint, `https://aviation-mcp.org/mcp`.

| Path | Used by |
| --- | --- |
| `plugin.json`, `mcp.json`, `assets/` | OpenAI (Agent Plugins format) |
| `.claude-plugin/plugin.json`, `.mcp.json`, `README.md`, `LICENSE` | Claude |
| `skills/<name>/SKILL.md` | Both; frontmatter holds only `name` and `description` |
| `evals/` | `claude plugin eval` |
| `../.claude-plugin/marketplace.json` | The repository's Claude marketplace |

The two manifests must agree on name, version and description.
`scripts/package-plugins.sh` checks that, runs `claude plugin validate --strict` on the
plugin and the marketplace, and writes both ZIPs to `dist/plugins/`:

- `aviation-mcp-openai-<version>.zip`: `plugin.json`, `mcp.json`, `assets/`, `skills/`.
- `aviation-mcp-claude-<version>.zip`: `.claude-plugin/`, `.mcp.json`, `assets/`,
  `skills/`, `README.md`, `LICENSE`.

The Claude `.mcp.json` uses the same URL as the Claude connector, so a user with both
does not see the tools twice.

## Submission status

As of October 29, 2026 UTC, [Claude's Aviation MCP submission](https://claude.ai/directory/manage/aviation-mcp)
has been submitted for review under publisher Tim Morgan. The portal refreshed
all 17 tools without annotation suggestions and confirmed receipt. Review updates
go to the supplied publisher contact. It is not yet approved or published.

[OpenAI's Aviation Data submission](https://platform.openai.com/plugins/manage/plugin_asdk_app_6ae2f4b563f88191a52bfbeed9663e5b)
is **In review** for version 1.0.0. Identity and domain verification are complete,
and MCP discovery succeeds. The display name follows the portal's instruction to
omit “MCP”. The submission includes five positive and three negative client cases,
the [recorded ChatGPT walkthrough](https://aviation-mcp.org/review/aviation-data-demo.mp4),
and reviewer notes explaining the Productivity category and weather correction.

The production compatibility fix is deployed and ChatGPT's private connector
works. All 17 production tools passed the MCP Inspector checks. The public
privacy, terms, and support pages are deployed. Client findings are documented
in [verification](verification.md). Claude conversation testing was unavailable
due to the account's weekly usage limit. Neither listing is approved or published.

## Before submitting 1.1.0

1. Deploy the server with the `performance` group, then run the four SF50 review cases
   against <https://aviation-mcp.org/mcp>.
2. Refresh `evals/mocks/aviation/_tools.json` from the deployed server so the eval mock
   matches its tools:

   ```sh
   curl -s https://aviation-mcp.org/mcp -H 'Content-Type: application/json' \
     -H 'Accept: application/json, text/event-stream' \
     -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
     | jq '{tools: [.result.tools[] | {name, description, inputSchema}]}' \
     > plugins/aviation-mcp/evals/mocks/aviation/_tools.json
   ```

3. Run the evals from `plugins/aviation-mcp`. They mock the server with an agent that
   plays it, so they test the skills' workflow, not live figures:

   ```sh
   claude plugin eval . --allow-tools 'mcp__plugin_aviation-mcp_aviation__*'
   ```

4. Validate the skills with `skills-ref validate plugins/aviation-mcp/skills/<name>` for
   each skill, if `skills-ref` is installed.
5. Run `scripts/package-plugins.sh`.
6. From the repository root, install from the local marketplace and try one example
   question through a skill:

   ```text
   /plugin marketplace add ./
   /plugin install aviation-mcp@aviation-mcp
   ```

## OpenAI

Upload `dist/plugins/aviation-mcp-openai-<version>.zip` at
<https://platform.openai.com/plugins> using the verified publisher identity, then connect
the server and resolve the portal's domain challenge if asked. The package contains nine
positive and three negative review cases; the four SF50 cases cover takeoff distance at
KOAK, maximum temperature at KTEX, a go-around at KASE and a departure climb at KASE. The
publisher identity must match the submission account before review.

The review cases describe expected behavior. Tool-level probes are documented
in [website verification](../site/examples-verification.md); those probes do not
establish model behavior in ChatGPT or Claude. Run the review cases inside the
clients before attesting to them. `extensions.com.openai.review.demo_recording_url`
points to the 1.0.0 walkthrough; record a new client interaction that includes an SF50
question and replace the URL before submitting 1.1.0. Do not substitute a simulated
transcript.

## Claude plugin

The repository is a Claude marketplace. Users install with
`/plugin marketplace add RISCfuture/Aviation-MCP` and
`/plugin install aviation-mcp@aviation-mcp`. To list the plugin in Claude's plugin
directory, submit the repository or `dist/plugins/aviation-mcp-claude-<version>.zip`
through the directory's plugin submission, with the same publisher details as the
connector. `claude plugin validate --strict --profile directory plugins/aviation-mcp`
runs the directory's local checks; the directory also runs a safety scan and a policy
review.

## Claude connector

Use <https://claude.ai/directory/manage> and choose **MCP connector**:

- Name: Aviation MCP
- URL: <https://aviation-mcp.org/mcp>
- Authentication: none; all data is public and no test account is needed
- Documentation: <https://aviation-mcp.org/>
- Privacy: <https://aviation-mcp.org/privacy>
- Support: <https://aviation-mcp.org/support>
- Icon: `aviation-mcp/assets/icon.svg`
- One-liner: Query U.S. aviation data, worldwide terrain and Cirrus SF50 performance,
  with source cycles, provenance, and explicit coverage gaps.
- Description: use the package's `longDescription`
- Access: read-only queries and calculations; no account modification, flight-plan
  filing, transactions, or aircraft registration lookup
- Data: our hosted normalized FAA database, read-only NOTAM queries, AWC and
  Open-Meteo weather, public Copernicus terrain, and SF50 performance models built from
  the AFM, which return computed figures only; no sponsored content

Supply the actual publisher and review-contact details in the portal. Exercise
every exposed tool with MCP Inspector or a Claude custom connector before
checking the testing acknowledgment. Read each policy acknowledgment against
the actual service behavior.

## Publication

Keep the manual MCP installation instructions available until the listings are
approved and accessible. Add the real directory installation links to the website
after publication; uploading a draft is not publication.

Requirements: [OpenAI submissions](https://developers.openai.com/plugins/deploy/submission)
and [Claude connector submissions](https://claude.com/docs/connectors/building/submission).

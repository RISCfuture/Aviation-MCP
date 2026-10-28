# Aviation MCP directory submissions

`aviation-mcp/` is the portable OpenAI plugin package. Its MCP configuration
points to the public, unauthenticated production endpoint. The Claude connector
submission uses that same URL directly; it does not require a separate backend
or a plugin bundle.

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

## OpenAI

Create a ZIP containing `plugin.json`, `mcp.json`, and `assets/` at its root.
Upload it at <https://platform.openai.com/plugins> using the verified publisher
identity, then connect the server and resolve the portal's domain challenge.
The package contains five positive and three negative review cases. The publisher
identity must match the submission account before review.

The review cases describe expected behavior. Tool-level probes are documented
in [website verification](../site/examples-verification.md); those probes do not
establish model behavior in ChatGPT or Claude. Run the review cases inside the
clients before attesting to them. Add the accessible demonstration recording URL
to `extensions.com.openai.review.demo_recording_url` after recording the actual
client interaction. Do not substitute a simulated transcript.

## Claude connector

Use <https://claude.ai/directory/manage> and choose **MCP connector**:

- Name: Aviation MCP
- URL: <https://aviation-mcp.org/mcp>
- Authentication: none; all data is public and no test account is needed
- Documentation: <https://aviation-mcp.org/>
- Privacy: <https://aviation-mcp.org/privacy>
- Support: <https://aviation-mcp.org/support>
- Icon: `aviation-mcp/assets/icon.svg`
- One-liner: Query U.S. aviation data and worldwide terrain, with source cycles,
  provenance, and explicit coverage gaps.
- Description: use the package's `longDescription`
- Access: read-only queries and calculations; no account modification, flight-plan
  filing, transactions, or aircraft registration lookup
- Data: our hosted normalized FAA database, read-only NOTAM queries, AWC and
  Open-Meteo weather, and public Copernicus terrain; no sponsored content

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

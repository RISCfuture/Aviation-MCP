# Aviation MCP website

The static Vite/TypeScript site explains the hosted MCP, provider setup, and
examples using real airports, fixes, and routes. It uses self-hosted fonts, a generated contour
illustration, and copy controls. The page explains MCP first, pairs each tool
category with a question, then gives provider setup instructions. All eleven
questions and the setup content are readable without JavaScript.
The [hero image provenance and generation prompt](image-generation.md) describe
the illustrative aviation overlays.

## Development

```sh
cd site
nvm use
pnpm install --frozen-lockfile
pnpm dev
```

Verification: `pnpm lint`, `pnpm format:check`, `pnpm build`, `pnpm test:unit`, and
`pnpm test:e2e`. Install Chromium with `pnpm exec playwright install chromium`
before the first end-to-end run. `pnpm format` owns this directory's formatting.
The build generates the ignored `worker-configuration.d.ts` from `wrangler.jsonc`
before type checking.

## Hosting and MCP routing

Cloudflare Workers serves built assets on aviation-mcp.org. The Worker answers
`/health` itself and streams HTTPS POSTs to `/mcp` to the fixed Fly origin without
caching responses or following redirects. `/ready` and `/metrics` stay on the
origin's private network, and unknown paths remain 404s. MCP request bodies,
protocol headers, statuses, streaming responses, and retry headers are preserved.
Visiting the website does not wake the Fly server.

The Worker and serving app share a random `EDGE_PROXY_SECRET` of at least 32
characters, installed through each platform's secrets facility. It is never a
browser asset or a client credential. The Worker signs its edge-observed client
address and timestamp with HMAC-SHA256. Vapor accepts the signed identity for 60
seconds; otherwise it uses its existing trusted Fly client address. This keeps
public admission budgets separate behind Cloudflare without trusting arbitrary
client-supplied forwarding headers. Deploy the origin support before changing
the domain's routing. Do not log the secret or signed forwarding headers.

For local Cloudflare operations, use Homebrew's `wrangler`. CI uses the pinned
project dependency. Run `pnpm build` and `wrangler deploy --dry-run` before
`wrangler deploy`. Install the shared secret using `wrangler secret put
EDGE_PROXY_SECRET`; do not place it in `wrangler.jsonc`.

The Website workflow verifies changes to `site/` and deploys main after checks
pass when repository variable `CLOUDFLARE_DEPLOY_ENABLED` is `true`. Before enabling
it, install repository secret `CLOUDFLARE_API_TOKEN` with permission to deploy
this account's Worker and domain. This follows the other Cloudflare sites'
pnpm/Vite/Workers pattern while keeping the existing Swift CI independent.

The Server verification workflow deploys pushes to main only after its Linux
tests, lint, and container checks pass. It uses `FLY_SERVER_API_TOKEN`, scoped to
`aviation-mcp-server`, and preserves the autostop configuration and terrain cache
volume in `fly.toml`. Deployment jobs run serially without cancelling a release
in progress. The separately scoped ingestion token remains with ingestion jobs.

Before the first custom-domain attachment, remove the apex A/AAAA records that
point to Fly. Cloudflare manages the apex DNS when the Worker domain is attached;
the Worker reaches Fly through `aviation-mcp-server.fly.dev`.

See [example verification](examples-verification.md) for the live tool calls
used to check the displayed questions.

## Copy and source references

Setup instructions were checked on October 28, 2026 against the
[OpenAI connection guide](https://help.openai.com/en/articles/12584461-connecting-custom-mcp-servers-in-chatgpt)
and [Claude remote connector guide](https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp).
Review those links when provider menus change. Aviation data coverage is U.S.
only, with worldwide terrain. Do not advertise aircraft registrations or
certified terrain clearance. The terrain illustration is decorative, not a chart.

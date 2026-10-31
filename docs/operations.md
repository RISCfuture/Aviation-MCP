# Operating Aviation MCP

Recoverable source errors produce partial publications with usable records and
persisted diagnostics. Structural failures, invalid cycle metadata, and empty
imports prevent publication. Enabled domains still require effective source data.

## Process roles

- `APP_ROLE=stage` enables offline source parsing commands without opening a
  database connection. Run these in ingestion jobs, not serving processes.
- `APP_ROLE=ingest` uses `INGEST_DATABASE_URL` for migrations, publication and
  purge commands. Its pools retain connections until the bounded job exits,
  keeping the database awake through distribution normalization and publication.
- `APP_ROLE=serve` uses `DATABASE_URL` and exposes `/mcp`, `/health`, `/ready`
  and `/metrics`. This is the default role. Startup refuses a `DATABASE_URL`
  whose role can modify aviation records or create objects in `public`, so a
  serving process needs its database reachable when it boots.

Use separate Fly apps for serving and private ingestion jobs so serving
machines never receive the ingestion credential. Both can use the same image.
The serving role needs read access to aviation source/record/manifest tables,
and read/write access to the weather cache, leases, provider budgets/cooldowns
and admission buckets. It must not own or publish aviation records.
The ingestion role needs migration, publication, purge and table-statistics
maintenance privileges.

`NOTAM_DATABASE_URL` is a separate credential. Its database role must be
read-only; startup checks reject mutation privileges on the queried NOTAM
tables. The Aviation MCP network has a private Flycast address on `notams-db-18`.
The dedicated `aviation_mcp_notams` role can read only `notams` and
`ingestion_state`, with read-only transactions enabled by default.

## Configuration

| Variable | Default / behavior |
| --- | --- |
| `AVIATION_GROUPS` | All domain groups; comma-separated, disabled tools omitted |
| `WEATHER_SOURCES` | `awc,open_meteo` |
| `MCP_ALLOWED_ORIGINS` | `https://aviation-mcp.org` |
| `PORT` | `8080` |
| `MCP_TIMEOUT_SECONDS` | `30`, configurable from 1 to 60 |
| `PUBLIC_RATE_PER_MINUTE` | `60` tool calls per client network (IPv4 address or IPv6 /64), metered in memory |
| `PUBLIC_RATE_BURST` | `20` |
| `PUBLIC_CONCURRENCY` | `2` in-flight `/mcp` requests per client network |
| `CONNECTOR_EGRESS_RANGES` | None; comma-separated CIDR ranges of hosted connectors, each sharing one budget |
| `CONNECTOR_RATE_PER_MINUTE` | `600` per connector range |
| `CONNECTOR_RATE_BURST` | `120` |
| `CONNECTOR_CONCURRENCY` | `24` in-flight `/mcp` requests per connector range |
| `GLOBAL_RATE_PER_MINUTE` | `1200` tool calls across all clients |
| `GLOBAL_RATE_BURST` | `200` |
| `WEATHER_CACHE_SECONDS` | `900` |
| `DATABASE_WAIT_SECONDS` | `15`, bounded database cold-start acquisition wait |
| `OPEN_METEO_ENDPOINT` | `https://api.open-meteo.com/v1/forecast` |
| `OPEN_METEO_API_KEY` | Optional; configure only for the selected endpoint |
| `OPEN_METEO_MINUTE_LIMIT` | `600` locally tracked weighted units |
| `OPEN_METEO_HOUR_LIMIT` | `5000` |
| `OPEN_METEO_DAY_LIMIT` | `10000` |
| `OPEN_METEO_MONTH_LIMIT` | `300000` |

Domain groups are `airports`, `navigation`, `airspace`, `procedures`,
`obstacles`, `aircraft`, `weather`, `notams`, `geography`, and `status`.
Enabling `notams` requires its connection URL. A client cannot enable an
operator-disabled weather provider.

The Fly configuration enables all domain groups. Missing datasets degrade their
tools without removing the entire service from readiness. Source parsing gaps
remain visible in query results; enabling a group does not imply complete source
or geometry coverage.

Quota counters are local estimates, not authoritative upstream remaining
quota. Cache hits do not reserve upstream units. Provider failures remain
structured tool errors; public admission failures return HTTP 429. Every `/mcp`
POST holds a concurrency slot while it runs, and each `tools/call` in it draws a
token. A JSON-RPC batch holds at most 10 messages; a request needing more tokens
than a full bucket holds is refused with HTTP 400 `too_many_tool_calls`.

## Staging and publication

The executable is `aviation-mcp`; the container uses it as its entry point.
These command forms describe the implemented staging interface:

```text
APP_ROLE=stage aviation-mcp stage-nasr CSV-ZIP OUTPUT-JSON
APP_ROLE=stage aviation-mcp stage-cifp EXTRACTED-CIFP OUTPUT-JSON
APP_ROLE=stage aviation-mcp stage-dof EXTRACTED-DOF RELEASE-TIME NEXT-RELEASE-TIME OUTPUT-JSON
APP_ROLE=stage aviation-mcp stage-aircraft DIRECTORY RELEASE PUBLISHED-TIME OUTPUT-JSON
```

All time arguments use ISO 8601 with a timezone. DOF currency dates are not
release dates: use the FAA's published release schedule for the two boundaries.
Aircraft snapshots have no invented expiration date. Record the provenance of
an aircraft release timestamp, especially when only an HTTP modification time
is available instead of a precise publication time.

NASR and CIFP versions and records must be combined into one normalized bundle
with matching effective boundaries and cycle identifiers. Publication rejects
unpaired NASR/CIFP batches. DOF and aircraft can publish independently.

With the ingestion credential injected into the process environment:

```text
APP_ROLE=ingest aviation-mcp migrate --yes
APP_ROLE=ingest aviation-mcp publish-bundle BUNDLE-JSON
APP_ROLE=ingest aviation-mcp purge
```

Publication inserts the batch, refreshes PostgreSQL statistics, computes source
counts, swaps the manifest and purges obsolete data in one transaction.
Failed transactions leave the active manifest unchanged and record a failed
ingestion run. Only current and next versions are retained. Expired data is
unavailable on queries even if scheduled maintenance has not run; clients must
restart expired pagination cursors. Cursors are authenticated with a key held
only by the serving process, so a restart also expires them, and paging stops
at offset 10,000: a query matching more reports partial completeness and must
be narrowed.

Deployments migrate with the new image before deploying it, and a failed
deployment rolls back to the previous image without reverting the schema. A
release's migrations therefore only add to the schema; a column or index the
code stops using is dropped one release later, once rolling back no longer
returns to an image that needs it. The `aviation_records.supplemental` column
and the `aviation_name` and `aviation_airport` indexes are retained on that
basis and can be dropped in the next release.

The `IdentifierLookupIndex` migration indexes FAA location identifiers stored in
record JSON alongside the primary identifier index. Both branches of identifier
lookups need indexes to avoid scanning and decoding every airport record.
Index maintenance must serialize with publication's `ANALYZE`. The migration
takes the publication advisory lock, replaces an invalid index left by an
interrupted build, and preserves a valid index. Manual recovery uses the same
transaction in `scripts/repair-identifier-index.sql`. It pauses publications;
replacing an invalid index can also block record queries until commit.

Before maintenance through a direct `fly postgres connect` console, temporarily
disable database autostop with
`fly machine update d893031c12de58 --app aviation-mcp-db --autostop=off --yes`.
Direct SSH console activity does not keep Fly Proxy's connection count active.
Restore `--autostop=stop` after the SQL completes, the index reports both
`indisvalid` and `indisready` as true, and public queries have been checked.
Do not run concurrent index creation alongside ingestion: its snapshot wait can
deadlock with the publication transaction's `ANALYZE` lock.

The ingestion workflow checks NASR, CIFP, DOF and aircraft independently every
six hours. It preloads available next-cycle releases and pairs NASR/CIFP by
effective boundaries. DOF boundaries come from the published FAA release table;
a download without a following published boundary is not eligible for import.
The standalone Swift checker downloads metadata without database credentials.
When a host rejects HEAD with HTTP 405, 501, or 503, it probes the first byte
with a range GET and preserves the returned validators.

Each discovered release is attempted even when an earlier cycle fails. Ingestion
result artifacts record success, failure, or an incomplete attempt for each cycle.
The scheduled and manually dispatched workflow opens an issue assigned to and
mentioning `@RISCfuture` when discovery or ingestion fails, including unvalidated
upcoming releases and published releases with parsing gaps. The issue lists effective dates and links to the workflow and
Fly ingestion logs. Repeated failures update the same issue; a newly failing cycle
adds a notification comment. A fully successful check closes the issue. GitHub
delivers the assignment and mention notifications according to the user's account
notification settings.

Run `node --test .github/scripts/ingestion-alerts.test.cjs` to verify release
failure isolation and notification/recovery behavior. The workflow runs these
checks before dispatching ingestion.

Set the GitHub variable `AVIATION_INGEST_IMAGE` to a verified immutable image
reference and secret `FLY_INGEST_API_TOKEN` to an `aviation-mcp-ingest` app-scoped
deployment token. `scripts/run-ingestion-job.sh` starts bounded private jobs,
checks their exit status and destroys their machines afterward. Database
credentials are injected by Fly into the ingestion app, not GitHub Actions.
If cleanup fails, the script reports the machine ID for operator removal.

`ingest-sources` verifies download validators and parsed effective dates, records
download provenance, and skips an unchanged release only when its parser
revision and source validators match. Partial releases keep their parser error
counts and bounded diagnostic samples under `validation.parse_errors`, including
record identities, source lines, and fields when available. Query results from
an affected version report partial completeness even when no records match.
`get_data_status` exposes diagnostics for current and staged next releases.

Invalid records are skipped while valid records continue through normalization.
NASR field errors retain the record and mark unknown fields. Rejected CIFP legs
retain the procedure's remaining legs but withhold its derived geometry to avoid
connecting across omitted legs. NASR route geometry is also withheld when a
reported error may have removed a route element. Partial publication does not
extend source expiration dates or relax NASR/CIFP pairing.

SwiftNASR's pinned CSV implementation cannot resume after a row error in its
fix, FSS, or coded-departure-route parsers, and silently skips truncated CSV
rows. The server preserves returned records and reports errors it receives;
complete recovery of those rows requires the upstream changes documented in
that package's `AVIATION-MCP-BUGS.md`.

AWC batches retain usable METARs and TAFs when neighboring reports are malformed.
Weather responses expose `parsing_gaps` and partial completeness. A batch with
no usable reports remains unavailable. The workflow purges expired data even
after ingestion failure.

## Verification and deployment files

`Dockerfile` builds the Swift executable and resource bundles into a non-root
Swift runtime image. `fly.toml` targets `aviation-mcp-server` in the Aviation MCP
organization and uses `/ready` for serving health checks. `/ready` requires
working database queries. Missing effective datasets return HTTP 200 with
`data_status: degraded` and `unavailable_sources`, keeping unaffected tools and
source status reachable. Tools requiring missing or expired data return an
unavailable result; they never serve expired data. Readiness does not establish
source semantic parity or full geometry coverage.

The GitHub workflows build all six pinned aviation libraries independently,
build/test the server against PostGIS, check formatting and supporting files,
and smoke-test the image: it migrates a fresh PostGIS database, serves `/ready`
under a role granted by `scripts/database-privileges.sql`, and refuses to serve
with the migrating role. The integration tests require
`TEST_DATABASE_URL` and reset the entire `public` schema: use a disposable test
database only.

The public repository is `RISCfuture/Aviation-MCP`. The deployed endpoint is
`https://aviation-mcp.org/mcp`, with tools from the enabled groups in
`fly.toml`.
A Cloudflare Worker serves the website and proxies MCP traffic to Fly. The custom PostgreSQL 18/PostGIS database has a 10 GB encrypted
volume. Apply `scripts/database-privileges.sql` after running migrations with
the ingestion role to grant the serving role only its required table privileges.

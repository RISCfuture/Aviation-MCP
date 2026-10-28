# Operating Aviation MCP

Deployment is not complete. The current SwiftCIFP revision loses procedure
roles and some altitude restrictions and has airspace/RNP decoding defects.
Production procedure and airspace acceptance requires corrected upstream data
and fresh staging. See the implementation progress ledger for other open work.

## Process roles

- `APP_ROLE=stage` enables offline source parsing commands without opening a
  database connection. Run these in ingestion jobs, not serving processes.
- `APP_ROLE=ingest` uses `INGEST_DATABASE_URL` for migrations, publication and
  purge commands. Its pools retain connections until the bounded job exits,
  keeping the database awake through distribution normalization and publication.
- `APP_ROLE=serve` uses `DATABASE_URL` and exposes `/mcp`, `/health`, `/ready`
  and `/metrics`. This is the default role.

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
| `PUBLIC_RATE_PER_MINUTE` | `60` per IP, shared in PostgreSQL |
| `PUBLIC_RATE_BURST` | `20` |
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

The initial Fly configuration enables obstacles, aircraft, weather, NOTAMs,
geography and status. Airports, navigation, airspace and procedures remain
disabled pending the upstream CIFP fixes, fresh paired publication and source
acceptance. Obstacle searches by coordinates or route remain available;
runway/procedure contexts require the unavailable navigation sources.

Quota counters are local estimates, not authoritative upstream remaining
quota. Cache hits do not reserve upstream units. Provider failures remain
structured tool errors; public admission failures return HTTP 429.

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
restart expired pagination cursors.

The ingestion workflow checks NASR, CIFP, DOF and aircraft independently every
six hours. It preloads available next-cycle releases and pairs NASR/CIFP by
effective boundaries. DOF boundaries come from the published FAA release table;
a download without a following published boundary is not eligible for import.
The standalone Swift checker downloads metadata without database credentials.

Set the GitHub variable `AVIATION_INGEST_IMAGE` to a verified immutable image
reference and secret `FLY_INGEST_API_TOKEN` to an `aviation-mcp-ingest` app-scoped
deployment token. `scripts/run-ingestion-job.sh` starts bounded private jobs,
checks their exit status and destroys their machines afterward. Database
credentials are injected by Fly into the ingestion app, not GitHub Actions.
If cleanup fails, the script reports the machine ID for operator removal.

`ingest-sources` verifies download validators and parsed effective dates, records
download provenance, and skips an unchanged release only when its parser
revision and source validators match. Remote navigation publication currently
fails explicitly while SwiftCIFP rejects the KUIN R31 qualifier in both checked
cycles and the orphaned KOQU V34 transitions in cycle 2611. Resolve these
coverage failures before removing the publication guard. Other sources remain
independent. The workflow also purges expired data, even after ingestion failure.

## Verification and deployment files

`Dockerfile` builds the Swift executable and resource bundles into a non-root
Swift runtime image. `fly.toml` targets `aviation-mcp-server` in the Aviation MCP
organization and uses `/ready` for serving health checks. `/ready` requires
effective data for enabled periodic domains; it does not establish source
semantic parity or full geometry coverage.

The GitHub workflows build all six pinned aviation libraries independently,
build/test the server against PostGIS, check formatting and supporting files,
and verify container startup. The integration tests require
`TEST_DATABASE_URL` and reset the entire `public` schema: use a disposable test
database only.

The public repository is `RISCfuture/Aviation-MCP`. The intended endpoint is
`https://aviation-mcp.org/mcp`; the serving image is not deployed yet. Cloudflare
apex A/AAAA records point to Fly using DNS-only mode, and the Fly TLS certificate
is active. The custom PostgreSQL 18/PostGIS database has a 10 GB encrypted
volume. Apply `scripts/database-privileges.sql` after running migrations with
the ingestion role to grant the serving role only its required table privileges.

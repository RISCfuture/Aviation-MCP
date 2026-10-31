# Hosting costs and on-demand startup

The deployment uses custom Fly PostgreSQL with PostGIS, not Managed Postgres.
The MCP server suspends and the database stops when idle; both start through
Fly Proxy and run in San Jose (`sjc`). The database keeps its persistent volume
while stopped. Ingestion runs in temporary machines with separate credentials.

## Estimated monthly cost

Estimates use [Fly pricing](https://docs.fly.io/about/pricing) checked October 31, 2026.
San Jose applies a 1.192 multiplier to CPU and RAM. A shared CPU with 1 GB RAM
costs approximately $8 per 30 days of continuous runtime, or $0.0111 per hour;
the ingestion size of 4 shared CPUs with 8 GB costs about $0.084 per hour.

| Item | Assumption | Estimate |
| --- | --- | --- |
| Serving machine | 1 shared CPU, 1 GB, about 20 hours/month | $0.22 |
| Database machine | Same size, about 25 hours/month | $0.28 |
| Database volume | 10 GB provisioned | $1.50 |
| Terrain cache volume | 1 GB provisioned, no scheduled snapshots | $0.15 |
| Stopped or suspended root filesystems | Approximately 1–1.7 GB combined | $0.15–0.25 |
| Database volume snapshots | Daily, beyond the 10 GB free allowance | $0–0.40 |
| Temporary ingestion machines | Short jobs; unchanged releases are skipped | $0.25–0.42 |
| **Light-use total** | Excludes variable items below | **Approximately $2.60–3.20** |

Machine hours come from Fly's `fly_instance_up` metric over October 29–31,
2026, extrapolated to a month; they include the idle interval before autostop.
Ingestion only boots machines for releases it has not yet published, and each
command gets its own machine size. Keeping an 8 GB ingestion worker running
continuously would cost about $61/month.

Volumes cost $0.15 per provisioned GB/month whether or not their machine runs.
The database volume auto-extends by 2 GB at 80% use, up to 20 GB, which would
add up to $1.50/month at the limit. Snapshots cost $0.08 per stored GB/month
after the first 10 GB free allowance; each re-ingest rewrites much of the
database, so snapshot storage briefly rises after one. Stopped and suspended
machines pay $0.15/GB/month for their root filesystems. Internet egress from
North America costs $0.02/GB; same-region private traffic is free. Shared IPv4,
IPv6 and the first ten single-hostname certificates have no separate charge.
Cloudflare Workers and static assets cost nothing at this traffic. Domain
renewal, taxes, optional support and any future paid weather plan are excluded.

The largest cost risk is traffic that keeps machines awake. The Worker answers
`/health`, non-POST `/mcp` and plain-HTTP requests at the edge, and `/ready` and
`/metrics` are no longer public, so only MCP POSTs start the server. Requests
more often than the idle-stop interval would keep both machines running, at
roughly $16–19/month.

At 300 runtime hours per serving/database machine, budget roughly $10–11/month
before variable items. The always-on equivalent is roughly $20–25/month.
An extra GB of RAM on an always-on San Jose machine adds about $7.15/month;
on-demand machines pay only for its running hours.

## Cold-start behavior

The serving process opens pools, checks that its database role cannot modify
aviation data, and registers routes; ingestion and migrations are separate
commands. It does not download or parse distributions at startup. Fly suspends
the idle serving machine instead of stopping it, so a resume restores the
running process rather than booting it. Both database and application reside
in San Jose to avoid inter-region connection latency.

Database acquisition waits up to `DATABASE_WAIT_SECONDS` (15 by default), so
an on-demand database has time to start. Serving connections are pruned after one
idle minute. Ingestion retains its connections for the bounded job's lifetime,
so the database stays awake during normalization and publication. This is a
bounded wait, not a guarantee of startup latency. MCP tool
execution and SQL statements retain their separate timeouts.

Before production traffic, run `scripts/measure-cold-start.sh`. It stops the
serving and aviation database machines, sends a real `get_data_status` tool
call without retries, then measures a warm call. It writes both responses and
prints first-byte and total times. An alternate MCP URL and output directory
can be supplied as its two arguments.

Run the probe only when interruption is acceptable. One database-only Flycast
probe on October 28, 2026 completed `SELECT 1` after approximately seven seconds
with no retries, starting from an automatically stopped database. Timing had
one-second resolution. The temporary probe machine was destroyed afterward.
This is one component measurement, not an end-to-end MCP latency guarantee.
A public deployment probe on October 28, 2026 stopped both serving and database
machines, then completed `get_data_status` without retries in 9.942905 seconds
(first byte 9.940718 seconds). The subsequent warm request took 0.311596 seconds.
These are single observations. Fly Proxy automatically stopped the serving
machine at 23:52:19 UTC, about six minutes after the last public test request.
Unrelated requests for asset paths woke the app again at 23:52:42 UTC,
interrupting the database idle-stop observation. Background internet traffic
can therefore add runtime even without MCP tool use.

# Hosting costs and on-demand startup

The deployment uses custom Fly PostgreSQL with PostGIS, not Managed Postgres.
The MCP server and database both stop when idle, start through Fly Proxy, and
run in San Jose (`sjc`). The database keeps its persistent volume while stopped.
Ingestion runs in temporary machines with separate credentials.

## Estimated monthly cost

Estimates use [Fly pricing](https://fly.io/pricing/) checked October 28, 2026.
San Jose applies a 1.192 multiplier to CPU and RAM. A shared CPU with 1 GB RAM
costs approximately $8 per 30 days of continuous runtime, or $0.0111 per hour.

| Item | Assumption | Estimate |
| --- | --- | --- |
| Serving machine | 1 shared CPU, 1 GB, 10–100 hours/month | $0.11–1.11 |
| Database machine | Same size and runtime | $0.11–1.11 |
| Database volume | 10 GB provisioned | $1.50 |
| Stopped machine root filesystems | Approximately 3.3 GB combined | Up to $0.50 |
| Temporary ingestion machines | 4 shared CPUs, 8 GB, 10–20 hours/month | $0.84–1.68 |
| **Light-use total** | Excludes variable items below | **Approximately $3–6** |

Runtime includes the idle interval before autostop and maintenance activity.
Ingestion hours and stopped filesystem sizes are planning allowances, not
measured production usage. Jobs are destroyed after completion. Keeping an
8 GB ingestion worker running continuously would cost about $61/month.

Volumes cost $0.15 per provisioned GB/month. Snapshots cost $0.08 per stored
GB/month after the first 10 GB free allowance. Internet egress from North America
costs $0.02/GB; same-region private traffic is free. Shared IPv4, IPv6 and the
first ten single-hostname certificates have no separate charge. Domain renewal,
taxes, optional support and any future paid weather plan are excluded.

At 300 runtime hours per serving/database machine, budget roughly $10–11/month
before variable items. The always-on equivalent is roughly $20–25/month.
An extra GB of RAM on an always-on San Jose machine adds about $7.15/month;
on-demand machines pay only for its running hours.

## Cold-start behavior

The serving process opens pools and registers routes; ingestion and migrations
are separate commands. It does not download or parse distributions at startup.
The deployed serving image is about 141 MB uncompressed. Both database
and application reside in San Jose to avoid inter-region connection latency.

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

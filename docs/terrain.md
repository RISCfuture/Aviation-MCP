# On-demand terrain

`query_terrain` reads native Copernicus elevation cells for a coordinate-route
corridor. PostgreSQL stores a small, spatially indexed tile catalog. An isolated
Rasterio/GDAL worker downloads selected compressed byte ranges from public COGs
and reuses them through a bounded disk cache. No worldwide elevation copy is
required, and serving startup does not download catalogs or terrain.

## Tool inputs and answers

```json
{
  "route": [[-122.4, 37.6], [-122.15, 37.15]],
  "half_width_nm": 1
}
```

Coordinates are `[longitude, latitude]` in WGS84. Width is measured on **each**
side of the route. The result includes the maximum's elevation in meters and
feet, coordinates where available, native resolution, source ETags and retrieval
times, catalog checksum, coverage gaps, and download/cache usage. Ocean-only
maxima are labeled as catalog-classified ocean instead of inventing one location.

The corridor is geodesically segmented and buffered in PostGIS, with 0.2% plus
10 m added to the requested half-width to cover polygon approximation. Every
native raster cell touched by that geometry is included; averaged overviews and
sparse lateral sampling are not used. The maximum describes that discretized,
slightly expanded surface-model corridor, not a continuous real-world guarantee.
Antimeridian buffers are split rather than spanning the rest of the world.

Optional climb comparison requires all four additional fields:

```json
{
  "route": [[-122.4, 37.6], [-122.15, 37.15]],
  "half_width_nm": 1,
  "starting_altitude_ft": 1500,
  "gradient_ft_per_nm": 300,
  "clearance_ft": 100,
  "vertical_datum": "EGM2008"
}
```

This is a **terrain-surface-only**, constant supplied-gradient comparison. It
neither computes aircraft performance nor includes separate DOF obstacles,
NOTAMs or regulatory clearance surfaces. Starting altitude must already be in
EGM2008; no implicit conversion from GPS ellipsoid, NAVD88 or pressure altitude
is performed.

For each cell, radial distance from the route start minus the corridor width and
cell radius supplies a conservative lower bound on flight distance. Multiplying
that bound by a nonnegative gradient gives a lower bound on aircraft altitude.
The result reports the limiting margin and location. `conditional_clearance_met`
requires complete source-cell coverage and a nonnegative bound everywhere.
`not_established` is inconclusive: the conservative bound may fail even when a
more precise flight-path calculation would pass. Unknown cells cannot establish
clearance, even if all available elevations are below the assumed flight path.

## Source identity and missing coverage

Source selection uses the AWS public **Copernicus DEM 2021** GLO-30 catalog with
GLO-90 fallback. The dataset is a surface model that may include buildings and
vegetation. Product/release, EGM2008 datum, catalog SHA-256, reader revision,
object ETags and source retrieval times accompany answers. ETags are conditional
object identifiers, not presented as cryptographic checksums. The catalog has
no invented aviation-cycle expiration.

The importer requires both catalogs to match the SHA-256 digests of the validated
2021 release before atomically replacing the active catalog. Changed catalogs
require release validation and updated pins; count thresholds alone cannot
establish ocean coverage. Each raster must also match its catalog cell’s full
native dimensions, Float32 band, resolution and point-registered transform. A
degree cell absent from both complete published catalogs is treated as ocean.
A failed HTTP request, malformed raster, invalid native value or NoData
sample is unknown, never sea level. Partial answers label the maximum as a
maximum of available data; fully unavailable answers are structured tool errors.

The worker pins each fetched object using a strong ETag and `If-Match`. It
requires an exact HTTP 206 range and matching Content-Range/ETag. It does not
follow redirects. Changed or unavailable source objects therefore cannot mix
new bytes with old cached blocks.

Source and license: [Copernicus AWS dataset](https://registry.opendata.aws/copernicus-dem/),
[Copernicus product information and attribution](https://dataspace.copernicus.eu/explore-data/data-collections/copernicus-contributing-missions/collections-description/COP-DEM).

## Bounds, caching and cold starts

| Resource | Limit |
| --- | --- |
| Route | 2–20 coordinate points; greater than 1 m and at most 500 NM |
| Corridor half-width | 0.05–2 NM |
| Degree-tile candidates | 32 |
| Downloaded ranges per request | 64 MiB total; at most 128 HTTP operations including HEAD |
| Native pixels read | 20 million |
| Worker input/output | 2 MiB corridor request; 1 MiB result |
| Worker | One per serving instance; identical concurrent requests coalesce |
| Execution | 25 s cooperative budget, 27 s child alarm, 28 s parent kill; enclosing MCP timeout still applies |
| Worker address space on Linux | 1 GiB; numerical libraries use one thread |
| Disk cache default | 512 MiB and 4,096 entries, least-recently-used eviction |
| Complete-answer reuse | 300 seconds, bound to catalog, geometry, assumptions and reader revision |

Source metadata is checked when reading blocks; a complete cached answer retains
its original tile ETags/retrieval times and is explicitly marked as cached.
An answer-cache hit performs no upstream requests. Cancellation kills the worker
when its last waiting request is canceled. Worker failure does not remove valid
blocks already cached. Different simultaneous queries receive a busy error
rather than building an unbounded queue.

Mount the cache on a small Fly volume to retain it through idle stops and
replacement of the application root filesystem. A **1 GB volume costs about
$0.15/month**, independently of runtime; it accommodates the 512 MiB cache.
The volume is local to one serving machine, so replicas maintain independent
caches. No new R2 storage is purchased for this mode. See [cost assumptions](terrain-feasibility.md).

A local Bay Area probe fetched 10,622,977 bytes of a 20,060,161-byte COG and found
750.4564208984375 m. First-read time was 17.3 s; repeating the raster calculation
used cached blocks, downloaded zero bytes and took 0.61 s. These are local
observations, not Fly end-to-end latency guarantees. Cold application/database
startup and uncached terrain reads are separate contributions to latency.

A subsequent local MCP request with an empty serving cache took 4.71 s and
returned the same maximum. Repeating that request took 0.47 s, with an explicit
answer-cache hit and zero upstream requests. These measurements exclude Fly
machine startup.

Live checks on aviation-mcp.org verified the same maximum, concurrent clients
reusing JSON-RPC IDs, the supplied-gradient comparison, and an antimeridian ocean
corridor. A cached request measured 0.62 s using curl. After stopping the serving
machine, a public request automatically restarted it and reused the persisted
answer with zero upstream requests. These are individual observations, not
latency guarantees. The restart check stopped only the serving machine.

## Operations and development

Run migrations with the ingestion role, then `aviation-mcp import-terrain` with
`APP_ROLE=ingest` and `INGEST_DATABASE_URL`. Reapply
`scripts/database-privileges.sql` as the database administrator to grant the
serving role read access to `terrain_catalog` and `terrain_tiles`.
Catalog publication uses the existing private ingestion job mechanism and is
independent of NASR/CIFP publication. Scheduled checks fetch only the catalogs;
unchanged checksums do not rewrite the tile table.

Enable the `terrain` group in `AVIATION_GROUPS`. Readiness requires its catalog
when enabled. `get_data_status` includes terrain catalog release, checksum,
retrieval time and counts. Query latency/errors use the existing per-tool metrics.
The mounted cache directory must be writable by the container's UID/GID 10001;
initialize `/data/terrain` with that ownership when attaching an empty volume.

| Setting | Default |
| --- | --- |
| `TERRAIN_PYTHON` | `/opt/terrain/bin/python` |
| `TERRAIN_SCRIPT` | `/app/terrain/worker.py` |
| `TERRAIN_CACHE_DIRECTORY` | `/tmp/aviation-terrain-cache` |
| `TERRAIN_CACHE_BYTES` | `536870912` |

The runtime image packages pinned Python/Rasterio dependencies. For local work:

```sh
pyenv virtualenv 3.14.10 aviation-mcp-terrain
cd terrain
python -m pip install -r requirements.txt ruff==0.17.3
python -m unittest discover -s tests -v
python -m ruff check .
python -m ruff format --check .
```

Point `TERRAIN_PYTHON` at that environment's absolute interpreter path and
`TERRAIN_SCRIPT` at the local worker. Set `TEST_TERRAIN_PYTHON` to enable Swift
subprocess cancellation tests. Swift database tests still require an isolated,
disposable `TEST_DATABASE_URL`; they reset its public schema.

# Terrain feasibility and incremental hosting cost

Research date: October 28, 2026. This is a feasibility assessment with one local
raster experiment, not an implemented or deployed terrain service.

## Recommendation

Use PostgreSQL/PostGIS for the terrain catalog, spatial footprints, provenance,
route geometry and cached answers. Keep elevation pixels in Cloud-Optimized
GeoTIFFs (COGs), read only the blocks intersecting a query, and cache those
blocks. Start with the public Copernicus source; mirror into Cloudflare R2 when
independent availability and immutable source ownership justify the storage.

PostGIS raster can perform the computation efficiently when tiled and indexed.
The reason to avoid putting the entire world in our current database is its
storage, backup and operational cost, rather than an inability to query rasters.
Do not create a database row per elevation sample.

Budget approximately **$1–5/month extra for a lightly used on-demand source
reader**, or **$10–20/month extra with a worldwide native-resolution R2 mirror**.
These are planning scenarios with bounded queries and caching, detailed below.
They are incremental to the existing server costs in [costs.md](costs.md).

## What SF50-TOLD does

Inspected the `iOS` repository at
`099b4693aa30b07ed744566fd8d54ec9a7df6bf7`, especially:

| Component | Source path within that repository |
| --- | --- |
| Source selection | `DownloadNASR/Services/Terrain/CopernicusTileCatalog.swift` |
| Download and publication | `DownloadNASR/Services/Terrain/SRTMProcessor.swift` |
| TIFF decoding and resampling | `DownloadNASR/Services/Terrain/GeoTIFFParser.swift`, `Elevations.swift`, `TileProcessing.swift` |
| Runtime tile cache | `SF50 Shared/Terrain/Data/MappedTerrainTile.swift` |
| Route sampling | `SF50 Shared/Terrain/Procedures/ProcedureTerrainPathGenerator.swift` |
| Published sizes | `SF50 TOLD/Resources/terrain-manifest.json` |

Despite the `SRTMProcessor` name, the source is Copernicus GLO-30, with GLO-90
fallback where 30 m data is withheld. Complete tile catalogs distinguish ocean
from published land tiles. A failed download is not treated as ocean. Eight
tiles are processed concurrently, and a failed tile prevents region publication.

The decoder reads Float32 GeoTIFFs, rounds elevations to Int16 meters, and
bilinearly resamples each degree tile onto 1201 × 1201 samples, approximately
90 m north/south spacing. Tiles are individually LZFSE-compressed and indexed
inside 11 regional files, then uploaded to R2 and packaged for Background Assets.
The runtime uses `pread` and a ten-tile decompression cache, approximately 29 MB
of sample buffers. It does not need all regional elevations in RAM.

The bundled September 24 manifest totals **22,468,547,481 bytes**, or 22.47 decimal
GB / 20.93 GiB. This measures those regional payloads, not their asset-pack
duplicates, current bucket billing, or independently verified worldwide coverage.
Reusing the existing objects adds no duplicate storage, but their representation
cannot establish the highest native-resolution terrain in a corridor.

The acquisition/catalog logic is reusable. The implementation depends on Apple
Compression/NSData LZFSE, `os`, CoreLocation and, for procedure construction,
SwiftData. It is not a drop-in Linux dependency. A portable GDAL-backed COG reader
would avoid maintaining a second custom TIFF decoder. Linux integration and
memory bounds still need verification before implementation commitments.

## Dataset size, coverage and resolution

The [public AWS distribution](https://registry.opendata.aws/copernicus-dem/)
contains the 2021 release. It is a digital **surface** model including vegetation
and structures, with GLO-90 fallback needed for full land coverage. The catalog
does not claim frequent updates. ESA publishes other releases separately; choosing
the same source as SF50 does not imply choosing the newest ESA release.

Elevations use the EGM2008 vertical datum. Preserve the datum, product/release,
resolution, checksum, transformation version and coverage in every answer.
Use a latest-published snapshot lifecycle, not an invented aviation-cycle expiry.
Retain the required attribution and license with mirrored and derived data.
See the [Copernicus product description](https://dataspace.copernicus.eu/explore-data/data-collections/copernicus-contributing-missions/collections-description/COP-DEM).

Measurements made against the public source:

| Measurement | Result | Scope |
| --- | --- | --- |
| GLO-30 catalog entries | 26,450 | Downloaded `tileList.txt` |
| DEM object sample | 48 systematically spaced catalog entries | HTTP HEAD content lengths |
| Sample mean | 21.43 MB per COG | Range 0.05–48.28 MB |
| Extrapolated native COG storage | **566.77 GB** | Mean × catalog count; not a full inventory |
| Estimated uncompressed native Float32 base band | **903.46 GB** | Catalog latitude bands and published grid widths |
| Mirrored storage planning allowance | **600–1,000 GB** | Native files, GLO-90 fallback and derived maxima; unmeasured allowance |

The size extrapolation has no statistical confidence interval. Compression,
water fraction, latitude and terrain vary substantially. Auxiliary quality maps,
multiple complete releases and replication would add storage. A complete object
inventory is appropriate before purchasing capacity.

The [COG layout documentation](https://copernicus-dem-30m.s3.amazonaws.com/readme.html)
specifies **averaged** overviews. They must not be used to answer a highest-terrain
query. SF50's resampling and five lateral corridor samples can likewise omit
peaks. Read native cells or build maximum-preserving summaries. A maximum
summary that overlaps a corridor boundary gives an upper bound; refine boundary
blocks before calling it the exact maximum of the source grid.

## PostgreSQL feasibility and local experiment

[PostGIS supports tiled rasters, spatial indexes and external cloud rasters](https://postgis.net/docs/using_raster_dataman.html).
An in-database implementation can use 256- or 512-pixel blocks, GiST footprint
indexes, release partitions and native-pixel clipping. Query work then depends
on intersected blocks, not the entire world's pixels. Larger caches help repeat
routes; the full dataset does not need to fit in RAM.

I loaded the real `N37_00_W123_00` GLO-30 tile into a disposable local PostgreSQL
17 / PostGIS 3.5.2 container with `raster2pgsql -s 4326 -I -C -M -t 256x256`.
The container runs Linux AMD64 under emulation on the Mac. Production was not
modified for this experiment.

| Observation | Result |
| --- | --- |
| Source | 3600 × 3600 Float32, 20,060,161 compressed bytes |
| Database storage | 225 raster rows, 22,323,200 bytes including indexes/TOAST |
| Route | `(-122.4, 37.6)` to `(-122.15, 37.15)` |
| Corridor | 1 NM on each side, rounded endpoints |
| Candidate processing | GiST index used; 17 intersecting blocks |
| Clipped source cells | 474,821 |
| Maximum source elevation | 750.4564208984375 m |
| First execution | 658.685 ms client timing, caches uncontrolled |
| Immediate repeat | 174.661 ms server execution in `EXPLAIN ANALYZE` |

This demonstrates the query mechanism only. It does not establish cold-disk,
concurrent, long-route, global-index or production latency. One coastal tile's
compression ratio must not be extrapolated as a global database size. Fly's
current shared-CPU-1x volume bandwidth limit is 16 MiB/s, which can dominate
uncached raster scans; local timing does not model that limit.

Core query used for the measurement:

```sql
WITH corridor AS MATERIALIZED (
  SELECT ST_Buffer(
    ST_GeomFromText('LINESTRING(-122.4 37.6,-122.15 37.15)', 4326)::geography,
    1852
  )::geometry AS geom
), clipped AS (
  SELECT ST_Clip(d.rast, 1, c.geom, true, true) AS rast
  FROM dem d CROSS JOIN corridor c
  WHERE ST_ConvexHull(d.rast) && c.geom
    AND ST_Intersects(ST_ConvexHull(d.rast), c.geom)
)
SELECT ST_SummaryStatsAgg(rast, 1, true, 1) FROM clipped;
```

The final `true` in [ST_Clip](https://postgis.net/docs/RT_ST_Clip.html) includes
every intersected cell rather than only cells whose centers lie inside the
corridor. [ST_SummaryStatsAgg](https://postgis.net/docs/RT_ST_SummaryStatsAgg.html)
uses a sampling fraction of 1. A production implementation also needs a separate
coverage calculation: excluding NoData from statistics does not prove complete
coverage. Cell footprints around point-registered samples are an explicit
modeling convention, not a continuous-world maximum guarantee.

Fly currently documents a **500 GB maximum per volume and one volume per
machine**. A native worldwide in-database deployment exceeding that capacity
would need sharding across machines or a different storage arrangement, rather
than simply enlarging our existing volume. See [Fly volume constraints](https://docs.fly.io/volumes/overview/).

PostGIS out-of-database rasters are a viable alternative: keep SQL raster metadata
and let GDAL read remote COGs. That moves network reads, decompression and remote
credentials into database backends and ties slow downloads to database pool
capacity. Prefer a bounded application-side reader or a separate on-demand
terrain worker so ordinary aviation SQL remains responsive.

## Proposed serving approach

1. Publish a small immutable tile catalog with spatial footprints, source URLs,
   checksums, grid transforms, resolution, vertical datum and explicit coverage.
2. Resolve route/procedure geometry and build a geodesic corridor. Split at the
   antimeridian and use suitable local projections for long routes and polar
   regions; do not buffer a worldwide route in degrees.
3. Select catalog entries with PostGIS, fetch only required COG ranges, and bound
   bytes, pixels, route length, corridor width, concurrency and execution time.
4. Compute maxima and a bounded profile. Preserve NoData, withheld-source fallback
   and unresolved procedure legs as coverage gaps. Return the maximum's location,
   source resolution, datum and all assumptions.
5. Cache blocks and results using source version plus normalized query parameters.
   Coalesce concurrent fetches. Cache eviction must not change numerical answers.

Do not download continental files at startup. The measured existing application
and database cold start is about 9.94 seconds; uncached terrain network reads
would add latency. Keep the tile catalog available immediately and decode only
needed blocks. An optional 5–20 GB local cache can survive idle stops on a volume;
an ephemeral cache is cheaper but is not durable across deployments.

A further cost optimization is a maximum-preserving reduced-resolution dataset,
with on-demand native refinement. SF50's roughly 22.5 GB payload suggests that
compact global summaries are worth measuring, but its compression and contents
do not establish the size of a new maxima/coverage/argmax format.

## Monthly incremental cost scenarios

USD, excluding tax, checked October 28, 2026. Use Standard R2: $0.015/GB-month,
$0.36/million reads, free egress. Free allowances are account-wide and may already
be consumed by SF50. Billing rounds storage and operation units upward.
See [R2 pricing](https://developers.cloudflare.com/r2/pricing/).

Fly volumes cost $0.15 per **provisioned** GB-month even while stopped; snapshots
are $0.08 per stored GB-month after the free allowance. Compute follows runtime.
See [Fly pricing](https://fly.io/pricing/).

| Approach | Additional persistent storage | Monthly storage estimate | Additional querying/runtime |
| --- | --- | --- | --- |
| Public native COGs on demand | No worldwide copy; optional 5–20 GB Fly cache | $0–3 | Budget $0.11–1.11 for 10–100 extra 1 GB worker hours; round total to **$1–5** with small overhead |
| Reuse SF50's existing regional objects | No new copy | $0 incremental; a duplicate 22.47 GB copy is about $0.35 before free allowances | Similar cache/compute costs; insufficient for an exact native-cell maximum |
| R2 native-world mirror and derived summaries | 600–1,000 GB planning range | **$9–15** before free allowances | Budget **$10–20 total extra** for light use, including bounded cache/compute and modest reads |
| In-database native-world example | 1,000 GB provisioned across multiple Fly machines | **$150**, plus snapshots | Compute, extra capacity and replication additional; actual global raster size unmeasured |

The 1 TB database row is a capacity/cost scenario, not a measured requirement.
For example, 600–1,000 GB of billed snapshot data would add roughly $48–80 before
the free allowance. Derivable DEM storage can instead be rebuilt from the source
and omit its own snapshots; keep ordinary aviation database backups separate.
WAL, import staging, indexes and release overlap need space beyond raster payloads.

Query-operation examples, assuming **20 uncached R2 GET/HEAD operations per query**:

| Monthly queries | Read operations | Read cost if free allowance remains | Gross cost without allowance |
| --- | --- | --- | --- |
| 10,000 | 200,000 | $0 | Up to $0.36 with billing rounding |
| 100,000 | 2 million | $0 | $0.72 |
| 1 million | 20 million | $3.60 | $7.20 |

Twenty reads is an illustrative input, not a measured route average. Long routes,
many models of the same corridor, small range requests and retries can increase
it; caching can decrease it. Compute at those query volumes must be measured
separately and is not covered by the light-use runtime allowance. At sustained
traffic, add actual worker-hours at the chosen machine rate. An extra 1 GB of
San Jose RAM is about $1 per 100 running hours using the rates in `costs.md`.

On-demand savings apply to compute, not stored bytes. Each wake includes its idle
tail, and observed background internet requests can keep the serving app awake.
The $1–5/$10–20 scenarios assume limited additional runtime; they are not fixed
monthly price caps.

Initial mirroring and maxima construction are separate one-time work. At the
existing 4-shared-CPU/8-GB worker estimate of about $0.084/hour, 10–100 worker-hours
would cost $0.84–8.40 in compute. That is a sensitivity calculation, not a measured
processing duration. Temporary storage, uploads and internet egress from a Fly
worker to R2 are additional: sending 600–1,000 GB from North America at $0.02/GB
adds approximately $12–20. R2's free egress does not make Fly uploads free.
Stream one source tile at a time instead of provisioning terabytes of scratch.

## What the MCP could answer

`query_terrain` could return the highest source-grid surface in a specified route
corridor, its position and distance along route, a bounded elevation profile,
coverage fraction and source metadata. Corridor width must be explicit; a
centerline maximum and a two-mile-wide corridor maximum answer different questions.

`analyze_climb` could compare a supplied flight path or climb gradient with that
surface and available obstacles. For a constant gradient, a simplified required
terrain gradient is:

```text
required_ft_per_NM = max over s > 0 of
  (surface_or_obstacle_ft(s) + selected_clearance_ft - starting_altitude_ft) / s_NM

gradient_percent = required_ft_per_NM / 60.7612
required_ft_per_min = required_ft_per_NM * groundspeed_knots / 60
```

The implementation must account for the whole corridor, including the earliest
along-track distance a cell occupies. Terrain above the starting clearance at
distance zero cannot be fixed by a finite constant climb gradient. Segmented
climb paths need segment integration rather than this single-gradient formula.

Inputs include start altitude and datum, route/runway/procedure, lateral corridor,
clearance policy, and available climb performance. Converting climb rate to
gradient requires groundspeed and wind assumptions. Generic aircraft
characteristics do not supply an approved performance model for arbitrary
weight, temperature, altitude, configuration or engine-out conditions.

Results should be conditional terrain-margin assessments, with the limiting
location and assumptions. They must not infer chart minima, regulatory obstacle
clearance or a categorical safe-to-fly decision. DEM resolution and accuracy are
not certified clearance margins, and worldwide DEM coverage does not extend
FAA DOF obstacle coverage worldwide. Reconcile vertical datums before combining
DEM, obstacle and aircraft altitudes; do not silently equate all MSL labels.

## Remaining validation before implementation

The next useful prototype is the bounded Linux COG range reader and cache, using
the same route as the PostGIS experiment. Measure cold and warm Fly latency,
bytes and requests for mountainous routes, ocean crossings, poles, the
antimeridian, partial coverage and long corridors. Validate maxima against
native rasters and ensure a narrow peak between profile samples is retained.
Test cancellation, concurrent queries, cache eviction and source-version changes.

Two SF50 findings were written to its `iOS/AVIATION-MCP-BUGS.md`: negative integer
coordinates select the preceding tile, and unknown terrain can become sea level
in procedure profiles. Their arithmetic/control-flow reproductions ran, but the
SF50 app itself was not built or modified as part of this investigation.

Local research evidence is under
`.build/ffc8f6cc-be24-4a21-9ba8-daca57e3ff0a/terrain-feasibility/`, including the
catalog, sampled content lengths, GeoTIFF metadata, import output, SQL and query
plan. No terrain infrastructure was provisioned and no production terrain tool
was enabled.

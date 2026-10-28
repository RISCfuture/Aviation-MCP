# Hosted Aviation MCP implementation

## Final review rulings (2026-10-28)

- Implemented the user-authorized server-side PostgresNIO workaround without
  modifying upstream code. SQLKit submits encoded queries through a connection
  guard on the PostgreSQL event loop. Closed connections fail immediately;
  SQL transactions preserve the original error when rollback fails and discard
  the connection. All nine application SQL transaction sites use this path.
- All 35 tests passed on macOS and Linux release mode, including a closed-query,
  failed-rollback and pool-recovery check. The abrupt Linux database-kill probe
  also completed successfully in 2.819 seconds, including application shutdown;
  the same fault previously left rollback pending indefinitely. No transaction
  is automatically retried after an uncertain commit outcome.
- The lifecycle image for 237bc00 built and pushed successfully as
  `registry.fly.io/aviation-mcp-ingest@sha256:ced463323de3938118e4ee2405a1fd1cd9e8c33a82534a24df9882498741c0b0`.
  A full Fly import and public cold-start checks remain outstanding.
- Linux release build and all 34 tests passed for f47bfee. Its 141 MB image is
  `registry.fly.io/aviation-mcp-ingest@sha256:24a7091c6afde38497cdfb3b880fcca28699a981258468be23f0c73d6df739d5`.
  Fly's API returned intermittent HTTP 503 before a successful build/push.
- The production DOF retry normalized 656,884 records in 14 minutes, then
  stalled during publication. The database had stopped while normalization ran.
  Its cold-start proxy restarted immediately after accepting the publication
  connection; PostgreSQL logged an unexpected EOF in an open transaction.
  A separate fresh purge process connected and completed successfully.
- Ruling: ingestion pools retain connections until job exit; only serving pools
  prune idle connections. This avoids a database cold start between normalization
  and publication. The cost is database runtime throughout bounded ingestion;
  this does not establish recovery from every possible mid-transaction failure.
- A Linux disconnect probe confirmed that the SQL query throws but Fluent's
  rollback remains pending on the closed connection. The phase marker was
  `query failed; rollback pending`; PostgreSQL TCP sockets were already closed.
  The reproduction is documented in postgres-nio's local package directory as
  `AVIATION-MCP-BUGS.md`. No upstream code was changed. The user selected the
  server-side workaround described above. Public deployment remains gated on
  full cold-start verification.
- Stopped and removed stalled DOF machine 811093f94de668. Its normalized data
  was never published. The lifecycle mitigation still requires a full Fly import.
- All 34 tests pass on macOS and Linux release mode with the lifecycle change;
  Swift format, SwiftLint and Markdown lint pass. The temporary fault-injection
  probe is kept in ignored evidence, not the shipped test suite.
- Fresh-context whole-branch review completed against aa73690. All three
  findings were reproduced in existing tests before their fixes; all 34 macOS
  tests pass after the fixes and fixture extraction. Swift format and SwiftLint
  pass. Linux release verification is running.
- Final: fixed ignored airport-only obstacle context, aggregated weather failures
  and lost provider decoding/coverage budget metadata, each RED to GREEN.
- Git push and GitHub variable writes now succeed after the user's permission
  update. aa73690 is published and the ingestion workflow is registered. Its
  aircraft, CIFP and DOF source checks passed; NASR returned upstream HTTP 503.
  Push-triggered publication and purge were correctly skipped.
- Ruling: fix airport-only obstacle context rejection as Important. Silently
  broadening a local obstacle request to the whole distribution misleads clients.
- Ruling: fix aggregation of all weather provider failures as Important. Clients
  need fallback exhaustion and retry information even when the first provider
  fails for a different reason.
- Ruling: promote lost decoding/coverage budget metadata to Important. A consumed
  upstream request must remain visible to clients making retry decisions.
- Ruling: keep navigation, airport, procedure and airspace groups disabled until
  the user confirms SwiftCIFP fixes and source parity is verified. Their original
  example questions remain incomplete; presenting partial coverage as parity
  would mislead aviation users.
- Ruling: the separate NOTAM ingestion service owns cancellation/completeness
  interpretation. This server preserves its records and reports uncertainty and
  freshness; it cannot establish upstream completeness independently.
- Ruling: library compilation establishes Linux build compatibility only.
  External aviation semantics still require fixture and representative-data
  verification; production DOF, public deployment, cold starts and scheduled
  activation remain operational acceptance gates.

The supplied hosted-server plan is the implementation specification. The original
prompt and five acceptance questions were recovered from
`/Users/tmorgan/Desktop/prompts/aviation-mcp.txt`. The supplied plan supersedes its
last-good-data retention policy with strict expiration.

## Sequence and evidence

1. Verify pinned revisions of SwiftNASR, SwiftCIFP, SwiftDOF, SwiftACD,
   SwiftMETAR, and SwiftGeographic in Swift 6.4 Linux containers.
2. Verify Vapor with the official MCP stateless HTTP transport, including
   concurrent clients using the same JSON-RPC ID.
3. Implement PostgreSQL/PostGIS ingestion, manifests, expiration and spatial
   queries, followed by the domain tools.
4. Implement live NOTAMs and weather, shared caching and quota reservation.
5. Add deployment automation and run the complete acceptance suite.

## Rulings

- The working directory was empty and had no Git repository. Initialize a new
  repository on `feat/hosted-aviation-mcp`; no existing checkout needs isolation.
- Library compatibility checks use pinned clean local HEAD revisions, fetched
  from their public upstream repositories in fresh containers. Dependency
  features remain gated on successful Linux verification as the plan requires.
- The installed toolchain is Swift 6.4. Local Swift builds use worker token
  `ffc8f6cc-be24-4a21-9ba8-daca57e3ff0a` and isolated scratch paths.

## Current state

The server runs locally. All six Linux library gates passed. Full-server Linux
release verification is in progress. Dataset adapters and deployment remain
uncompleted; this is not a source-parity or production-readiness claim.

## Verified foundation (2026-10-28)

- All six pinned library targets passed Linux release compilation; see
  [Linux verification](linux-verification.md).
- The official MCP SDK adapter uses one server/transport per HTTP request.
  Three Swift Testing cases passed on macOS and Linux: 20 concurrent requests
  reusing JSON-RPC ID 1, origin/protocol/body-size validation, and timeout behavior.
- Four cycle-selection cases passed: paired changeover, strict expiration with
  missing replacements, aircraft snapshots without invented expiry, and retention
  of current/nearest-next with failed imports excluded.
- Two PostgreSQL/PostGIS integration cases passed: atomic NASR/CIFP publication
  with rejected invalid batches, and concurrent independent publications.
- The complete suite with all six dependencies linked passed 9 tests on macOS.
- Generic periodic query, cursor and result-envelope implementation now builds,
  but its behavior has not yet been tested. It is not connected to an executable
  tool catalog. `Run` currently starts an unconfigured Vapor application.

## Remaining implementation

- Complete and verify query filtering, spatial searches, version-bound pagination,
  source coverage detection, normalized adapters for all source record families,
  ingestion commands and source acquisition/check workflows.
- Complete catalog/group configuration, weather/NOTAM services, shared rate limits,
  cache/coalescing, geometry/coordinate tools, metrics, readiness and deployment.
- Add representative fixtures and exercise the five original questions.
- Expand acceptance checks for purge, failed bulk insertion, cursors, full-scale
  obstacles, antimeridian geometry, procedure expansion/gaps, weather and quotas.
- Run final release/Linux builds, tests, lint/format and whole-branch review before
  claiming completion. No deployment has occurred and source parity is unverified.

## Deployment and tooling decisions

- User purchased `aviation-mcp.org`; intended URL is
  `https://aviation-mcp.org/mcp`, also the allowed browser origin.
- User explicitly requested Cloudflare plugin use for DNS.
- User authenticated flyctl again and chose a new organization.
- Created Fly organization `aviation-mcp`. App name `aviation-mcp` is taken by
  another account; requested app `aviation-mcp-server` instead.
- Existing NOTAM apps in organization `notams`: `notams`, `notams-db-18`.
  Cross-organization Flycast must be configured without breaking existing access;
  no existing NOTAM deployment, database or network settings have been modified.
- Cloudflare plugin calls returned `Unknown tool` for both identity and API search.
  Found global disablement in Codex configuration. Used `agent-config` to apply
  repo-local Cloudflare/Fly enablement and disable unnecessary Xcode tooling.
  `agent-config audit --root /Users/tmorgan/Repositories/Websites/Aviation-MCP`
  reports no drift. Settings are machine-local and Git-excluded. Overrides are in
  `~/.config/agent-config/overrides.json`. No tracked shell-files files were changed.
- User was asked to trust this checkout in Codex and reload tools because its
  project trust entry is absent. Do not bypass the plugin preference for DNS.

## Local verification resources

Worker token: `ffc8f6cc-be24-4a21-9ba8-daca57e3ff0a`.
Swift scratch path: `.build/ffc8f6cc-be24-4a21-9ba8-daca57e3ff0a/swiftpm`.
Logs: `.build/ffc8f6cc-be24-4a21-9ba8-daca57e3ff0a/evidence/`.

Isolated disposable PostGIS container: `aviation-ffc8f6cc-postgres`, listening on
`127.0.0.1:32768`; database/user `aviation`/`postgres`, local test password
`aviation-local-test`. These are disposable local credentials, not Fly secrets.
`PublicationTests` recreate the public schema and must only use a disposable test
DB through `TEST_DATABASE_URL`.

```sh
TEST_DATABASE_URL='postgres://postgres:aviation-local-test@127.0.0.1:32768/aviation?sslmode=disable' \
  AGENT_WORKER_ID=ffc8f6cc-be24-4a21-9ba8-daca57e3ff0a \
  swift test --scratch-path .build/ffc8f6cc-be24-4a21-9ba8-daca57e3ff0a/swiftpm --jobs 6
swift format format --in-place --recursive Sources Tests
swiftlint lint --strict
```

No commits have been made. Existing user modifications in shell-files (`Brewfile`
and `dotfiles/claude/settings.json`) were left untouched.

## Integrated services (2026-10-28)

- The executable now configures Vapor, PostgreSQL pools, Fluent migration commands,
  operator-selected tool groups, MCP routes, shared admission limits, health and
  readiness endpoints, and basic query/source metrics.
- Twenty tests passed against macOS and a disposable PostGIS database. Added
  weighted concurrent provider reservations, shared cache/coalescing, 429 retry
  caching, provider cooldowns, admission bursts, weather source priority,
  pressure-level terrain/window validation, report normalization, TAF transition
  bounds, antimeridian geometry, NOTAM overlap/context and disabled discovery.
- The local executable successfully migrated a separate smoke-test database.
  HTTP readiness and MCP discovery passed. Live AWC-only and combined AWC plus
  Open-Meteo calls passed. AWC supplied temperature/wind; Open-Meteo supplied 14
  modeled pressure levels. The 58-variable request reserved 5.8 local call units.
- SwiftLint and strict Swift formatting passed before the newest ingestion work.
  They must be rerun after subsequent edits.
- DOF and aircraft adapters are being implemented with normalized response fields
  and supplemental source records retained only in storage. Their tests are not
  yet verified. NASR/CIFP adapters, full query parity, acquisition workflows,
  ingestion commands, operational logs and production deployment are outstanding.
- Full-server Linux release build/test runs use the container
  `aviation-ffc8f6cc-linux` and volume `aviation-ffc8f6cc-linux-build`. The source
  snapshot predates the new ingestion adapters. Log: `evidence/server-linux.log`.
  Its test DB is `aviation_linux_ffc8f6cc` inside the existing PostGIS container.
- A local smoke server is running on `127.0.0.1:18081` with only weather, geography
  and status enabled. Its DB is `aviation_smoke_ffc8f6cc`. Stop this process when
  replacing the binary or finishing local verification.

## Cloudflare connection and approval state

- The project is now trusted in Codex; the trust entry was verified.
- Cloudflare authentication succeeds after the user connected it in the desktop
  app. Identity matches `github@timothymorgan.info`.
- The user selected Allow all tools. Plugin Management confirms Cloudflare has
  Allow all actions, but the DNS execution tool is still blocked by the session:
  `MCP tool call requires approval, but approval policy is never`.
- No DNS records have been inspected or changed. Do not bypass that approval block
  or the user's request to use the Cloudflare plugin. A session capable of tool
  approval is needed to finish DNS setup.
- Fly confirms `aviation-mcp-server` exists in `aviation-mcp`, remains pending,
  and has no machines, allocated IPs or certificates. No deployment has occurred.

## Ingestion normalization (2026-10-28)

- The pre-adapter full server snapshot passed its Linux release build and all 20
  tests against PostGIS. This does not yet verify the newer import adapters.
- The macOS suite passed 22 tests after adding Fluent ingestion-run logging and
  failed-publication rollback coverage. Four focused import tests subsequently
  passed, covering DOF datums/parser failures, aircraft variant categories,
  CIFP restrictions and geometry gaps, and NASR units/datums.
- Added staging commands for DOF, aircraft, NASR CSV and CIFP, plus ingest-role
  publication and purge commands. NASR/CIFP use the same effective-date cycle key.
- NASR normalization covers airports/runways, navaids/fixes, airways, routes,
  weather stations, ILS, FSS, holds, ARTCC facilities/boundary definitions,
  military route definitions and parachute areas. CIFP covers procedures,
  restrictions, separate missed approaches and airspace boundary definitions.
  Determinable IF/TF segments are separated from explicit geometry gaps.
- Full October 1, 2026 FAA NASR CSV and CIFP distributions were downloaded into
  the ignored worker datasets directory. Full-distribution staging is running;
  successful import and source parity are not yet established.
- New source-family adapters still need acceptance checks, complete spatial
  construction, detailed response schemas, publication coverage metadata,
  Linux re-verification and deployment automation.

## Full-distribution findings and query expansion (2026-10-28)

- Full CIFP staging passed: 52,352 procedures/transitions and 1,940 airspace
  definitions, no duplicate normalized identities. Full NASR staging parsed
  171,330 records across 14 families. Three optional classification values are
  preserved as record warnings; dropped records and other field diagnostics still
  reject publication. Unknown runway materials do not imply paved surfaces.
- NASR cycle validation reads every airport CSV effective date and rejects mixed
  or invalid cycle dates; it does not depend on the archive filename.
- Full NASR identity validation found 33 groups of reused navaid identifiers and
  one reused airport site number. Airport identities now include the LID;
  navaid identities include state, country and name. Original source IDs remain
  available. The updated full staging and uniqueness checks are in progress.
- Publication now stores record/spatial counts and warning counts atomically in
  source-version validation metadata. Queries use this metadata to report
  unsupported spatial coverage without scanning entire distributions.
- Twenty-four tests passed after adding runway departure-end obstacle searches,
  strict spatial coverage errors, NASR cycle/diagnostic handling and validation
  metadata. Two focused navigation tests then passed for reverse airway traversal
  and procedure transition ordering with both boundary constraints preserved.
- Obstacle inputs now accept coordinates, runway departure ends, routes or an
  exact procedure ID, with every referenced cycle pinned. Procedure geometry gaps
  are explicit; missed approaches are currently excluded from obstacle context
  searches. Full procedure-geometry parity remains outstanding.
- Added airway entry/exit expansion, procedure transition expansion, runway and
  procedure-type filters. The newest complete suite is running in domain-tests.log.
- A fresh Linux release build/test snapshot is running in current-linux.log,
  using the existing isolated Linux build volume and disposable Linux test DB.
- Deployment and original-question end-to-end acceptance are still unfinished.

## Published dates and upstream findings (2026-10-28)

- The corrected full NASR bundle has no duplicate identities. The combined
  NASR/CIFP bundle contains 225,622 records; publication to the disposable smoke
  database is in progress. Full FAA aircraft staging passed with 388 profiles.
- Ruling: DOF staging requires explicit published release boundaries, preserving
  the file currency date separately. FAA's September 27 currency file was
  released September 29, with the next release November 24. SwiftDOF currently
  treats currency as effectiveness and also calculates cycles from a Monday
  datum. Using the library dates would expire this release two days early.
- The new DOF boundary assertions failed before implementation; the complete
  26-test suite then passed. SwiftLint and format checks passed.
- Per the user's request, upstream findings are written to
  `AVIATION-MCP-BUGS.md` in the SwiftDOF and SwiftNASR package roots. The NASR
  report distinguishes the confirmed unknown-surface/paved classification bug
  from optional source diagnostics that still need investigation. Package source
  code was not changed. Both reports passed Markdown lint.
- Added a multi-stage Swift runtime Dockerfile and Fly serving configuration.
  Container packaging, full dataset acceptance and deployment remain pending.

## Full-scale publication and hosting preparation (2026-10-28)

- Full NASR/CIFP publication passed in the disposable smoke database: 225,622
  records, with atomic source validation counts. Aircraft publication passed:
  388 profiles. Full DOF staging passed: 656,884 obstacles; publication is running.
- HTTP acceptance queries returned 54 KOAK approach/transition records and B738
  approach category D from the actual FAA workbook. Current KOAK runways are
  10L/28R, 10R/28L, 12/30 and 15/33; runway 29 is not present in this cycle.
- V25 endpoint acceptance exposed a server candidate-selection bug: a Hawaii
  candidate lacking SNS/PRB caused the mainland candidate to be rejected too.
  The existing reverse-traversal test was extended and failed with that error.
  Endpoint matching now filters candidates; focused verification is running.
- The first Docker build exposed the omitted test source directory as overlapping
  SwiftPM target sources. The build context now includes Tests; packaging is
  rebuilding. Hadolint passes; flyctl validates fly.toml.
- Added server CI for Linux release/tests/PostGIS/format, SwiftLint and supporting
  linters, plus deployment image build/runtime linkage. actionlint, shellcheck,
  YAML lint and Markdown lint passed locally. CI has not run remotely.
- The user authorized public RISCfuture/Aviation-MCP and created the empty repo
  after local gh credential access was denied. Its HTTPS remote is connected
  and git ls-remote succeeded. No commits or pushes yet.
- Browser fallback was stopped after automatic review rejected a Safari read as
  exposing unrelated App Store Connect metadata. The UI lock was released.

## Airway geometry and station weather lookup (2026-10-28)

- The V25 SNS–PRB HTTP request now selects the mainland candidate and returns
  SNS, CASRA, HAGRO, WIGGL, LUCAB, PRB. The October 1 adapter-1 import has no
  airway positions, so its geometry is explicitly partial. Re-staging that
  current cycle with adapter 2 remains necessary before deployment.
- NASR adapter 2 resolves airway positions from the same cycle's fixes/navaids,
  matching point type and ICAO region. Ambiguous positions remain candidates;
  segments never bridge them. GNSS/DME directional altitude constraints are
  retained. Restricted airway queries include their determinable geometry.
- Next-cycle staging passed with 171,436 NASR records and 54,259 CIFP records,
  zero duplicate identities. All 1,552 next-cycle airways have some determinable
  geometry; this does not mean every segment is resolved. Next publication is
  running and must not activate before October 29.
- Source status now includes preloaded next versions. Geometry computations use
  read-only transactions with a ten-second SQL timeout. Periodic results with
  procedure/airway geometry gaps explicitly report partial completeness.
- Open-Meteo station-only requests now resolve the airport/AWOS position from
  an effective NASR snapshot when needed. Ambiguity or missing data remains an
  explicit provider error; resolved results stamp the NASR source cycle.
- Twenty-eight tests passed after the station lookup implementation. The new
  integration fixture initially omitted the required JSON data column; its setup
  was corrected. SwiftLint and format checks pass. Tests were regrouped into an
  extension to respect type-length lint; the final macOS recheck is running.
- Linux release/tests passed for the earlier 26-test snapshot. A fresh 28-test
  snapshot is running in latest-linux.log. The deployment image built and its
  staging help executed successfully (docker-runtime.log); that image predates
  the latest airway/weather changes and needs a final rebuild.
- Full DOF publication remains in progress. Remaining plan work includes complete
  airspace/procedure geometry, source automation, operational metrics, NOTAM Fly
  connectivity, deployed database roles, final full-scale acceptance, and hosting.

## Critical upstream procedure-role finding (2026-10-28)

- SwiftCIFP's waypoint-description enums silently discard valid nonblank role
  characters; its FAF/MAP helpers inspect the wrong position, and its flyover
  helper confuses essential waypoints with flyover waypoints. Actual KOAK I12
  records and FAA Order 8260.19G Appendix N confirm the mismatch.
- A detailed reproduction is in the SwiftCIFP package root's
  `AVIATION-MCP-BUGS.md`, per the user's request. Its source code was not modified.
  Procedure-role acceptance is blocked on a correction or a verified adapter;
  the existing staged CIFP datasets must not be treated as role-accurate.
- DOF, NASR, weather, deployment and other independent work can continue.

## Full-scale obstacle query evidence (2026-10-28)

- Full DOF publication passed: 656,884 obstacles. A five-NM spatial EXPLAIN
  ANALYZE used the aviation_geometry GiST index and completed in about 207 ms
  on the emulated local PostGIS container (dof-query-plan.txt).
- The initial runway-context HTTP query hit the ten-second SQL limit before
  table statistics were refreshed. After ANALYZE, the same query completed in
  352 ms. Publication now refreshes aviation_records statistics before manifest
  activation; this is required for full-size imports rather than relying on
  eventual autovacuum/analyze scheduling.
- KOAK runway 29 correctly reports no published departure-end position for the
  current cycle. The separate runway 30 query returned obstacle 06-221502,
  elevation 387 ft MSL and height 45 ft AGL, with the source's unverified code U.
  This is a query acceptance observation, not an operational flight assessment.
- The latest macOS suite passed all 28 tests after regrouping test helpers.

## Additional upstream blockers and verified preloading (2026-10-28)

- The SwiftCIFP report now also documents dropped at-altitude restrictions when
  the description is blank (KOAK I12 RAIDR loses 5,000 ft), controlled-airspace
  sequence offsets, populated arc fields ignored under the current boundary-via
  enum, and RNP mantissa/exponent decoding. These prevent procedure/airspace
  deployment acceptance; successful parsing alone did not establish correctness.
- The full next NASR/CIFP publication completed locally: 225,695 records.
  get_data_status still reports October 1 as current and October 29 as next for
  both sources. These are local test imports, not production-ready CIFP data.
- Final checks after the ANALYZE publication change are running in
  final-macos-check.log. latest-linux.log tests the preceding 28-test snapshot;
  the one-line ANALYZE change still needs final Linux verification.
- GitHub remote is connected, but no commit/push/deployment has occurred.
  Cloudflare DNS remains blocked by the session approval policy despite the
  plugin's Allow all actions setting. No DNS record has been changed.

## Permissions, custom database and on-demand hosting (2026-10-28)

- Elevated permissions allowed Fly provisioning and Cloudflare changes. The
  custom aviation-mcp-db PostgreSQL 18/PostGIS machine uses one shared CPU,
  1 GB RAM, a 10 GB encrypted volume, and private Flycast. It is not Fly Managed
  Postgres. Serving and ingestion apps have separate non-superuser credentials.
- Cloudflare DNS-only apex A/AAAA records now point to Fly. The aviation-mcp.org
  certificate is active. No serving machine has been deployed yet.
- Added an Aviation MCP organization Flycast address to the existing NOTAM
  database, preserving its original address. The dedicated NOTAM role has SELECT
  on notams and ingestion_state only, with default read-only transactions.
  A real KSFO/time-overlap SQL probe found 44 records; MCP acceptance is pending.
- Both new aviation apps are configured to stop when idle. Fly Proxy stopped
  the database automatically at 20:31 UTC, verified through machine events.
  Application/database cold-start latency has not yet been measured.
- NASR adapter 3 preserves ordered military route centerlines and explicitly
  excludes unresolved point connections and widths. Mixed-domain coverage
  reports missing kinds as partial instead of dropping otherwise covered data.
  Added database ingestion-outcome and provider-budget metrics. Twenty-nine
  macOS tests passed before the source-check work below.

## Source automation and build verification in progress (2026-10-28)

- Added standalone Swift source checks, private bounded Fly ingestion jobs,
  independent scheduled checks and purge orchestration. Download validators,
  source URL and timestamp basis survive publication alongside validation
  counts. Unchanged metadata plus the same parser revision skips parsing.
- Live checks succeeded for DOF, CIFP current/next and aircraft. NASR returned
  HTTP 503 from the FAA, independently reproduced with curl. The checker reports
  that failure explicitly while other source jobs remain independent.
- Ruling: DOF publication requires a following published release boundary;
  aircraft HTTP Last-Modified is explicitly labeled as snapshot metadata, not
  a known publication time. This avoids invented expiry, at the cost of declining
  a DOF preload when its next boundary is not published yet.
- CIFP staging now marks the pinned parser's output unvalidated; remote
  navigation publication also rejects it before downloading. This prevents the
  documented semantic defects from becoming production data. Fresh staging and
  acceptance are required after the upstream fixes.
- The first x86 Fly build failed in swiftbuild's SwiftSyntax dependency-file
  output. Native build mode then received signal 9 at four concurrent jobs.
  A native single-job image build is running. CI now uses native release build
  and test commands. A Linux swiftbuild release-test attempt also failed because
  AviationMCP was not compiled for @testable imports; native verification is
  running separately. No new Linux success is claimed yet.
- The first source-discovery test run stalled in clang-stat-cache before test
  compilation and was interrupted. The native macOS build found and corrected
  a missing optional argument in the test fixture; the full database-backed
  suite is running. This was not a completed red/green behavior cycle.

## Source pipeline verification and database wakeup (2026-10-28)

- Native macOS tests passed: 30 tests in six suites, including PostgreSQL
  publication/provenance checks. The earlier 29-test snapshot also passed in
  native Linux release mode; the latest source snapshot is now being checked
  in the same Linux container.
- Real aircraft acquisition, parsing and publication succeeded against the
  local smoke database. Repeating the checked plan printed that the release
  was already published, verifying the metadata/parser deduplication path.
- Procedure expansion now declines to merge a partial pagination page instead
  of reporting a transition missing or returning incomplete expanded legs.
  The existing transition test failed before the fix; all 30 tests passed
  afterward, including the continuation-page check.
- A private Fly helper connected through the ingestion credential and Flycast
  to the stopped aviation database and executed SELECT 1 in approximately seven
  seconds, with no retries and one-second timing resolution. Its machine
  865eddb7251248 exited zero and was destroyed. Full MCP cold-start measurement
  still awaits the serving image.
- Some shell Fly calls are still rejected by automatic approval review under
  approval policy never. Purpose-built Fly tools work. Their command string is
  one argument; a shell probe needs entrypoint `/bin/sh -c` and a single script
  command. No credential values were printed or written into the repository.

## Independent work while upstream CIFP is pending (2026-10-28)

- The user explicitly will fix SwiftCIFP upstream and instructed us to wait
  for their confirmation. Do not add server workarounds, update that pin, or
  publish its data before that confirmation. Hosting, weather, aircraft and
  obstacle work continue independently.
- The user installed FLY_INGEST_API_TOKEN in RISCfuture/Aviation-MCP; its presence
  was verified by secret name/update time only. No image variable has been set
  and the workflow has not been pushed or executed yet.
- Full local source acquisition/publication succeeded for 656,884 DOF obstacles
  and 388 aircraft profiles, with download provenance retained in source
  validation metadata. The DOF publication took several minutes in debug mode.
- Open-Meteo receives only fields not already covered by AWC. The existing
  provider-priority test failed before the change and passed afterward.
- Airport public-use, facility-type and paved-runway filters are implemented.
  Runway length and pavement predicates must match the same runway. The existing
  query integration test failed before the change and passed afterward. Its
  database setup moved into a shared fixture file to respect lint limits.
- Private-job shell checks exercise success, failed job exit and cleanup
  failure. Cleanup failure initially returned zero; it now fails the workflow.
  Shellcheck, actionlint, hadolint, YAML and Swift format checks pass. Latest
  macOS/Linux suites are being rerun after the fixture extraction.
- Docker now uses a locked BuildKit cache for Swift packages/build artifacts.
  The current single-job x86 image build predates this cache and the latest
  weather/filter/CIFP publication-guard changes; it can bootstrap migrations
  and independent ingestion, but a current image is required before final
  deployment acceptance. It has progressed beyond the large SwiftSyntax build.

## Geometry result verification (2026-10-28)

- The 30-test macOS and native Linux suites passed after the shared fixture
  extraction. Geometry responses now apply a shared 32 KB budget to nested
  shapes and positions per record, preserving leg sequence and restrictions
  and marking omissions. Its test failed before the implementation, then
  passed after correcting a JSON integer-versus-double assertion.
- Source validation now aggregates spatial limitations by record kind, so a
  search with no matching records still reports missing polygon/footprint
  coverage. NASR adapter 4 labels ARTCC facility and boundary points and
  parachute centers accordingly. The empty-boundary-search test failed before
  the change; all 32 macOS tests passed afterward. Linux is being verified.
- Initial Fly discovery is limited to obstacles, aircraft, weather, NOTAMs,
  geography and status until paired navigation data passes acceptance. The
  image build is still in progress; this is configuration, not a deployment.

## Independent source and live weather checks (2026-10-28)

- All 33 tests passed on macOS and native Linux after adding explicit uncertain
  NOTAM scope annotations and preserving reserved weather budget metadata on
  network/decoding failures. Both behavior tests failed before the fixes.
- Live local MCP calls against the smoke database returned B738 FAA approach
  category D and spatial DOF results. A combined weather call used AWC METAR
  temperature/wind and Open-Meteo pressure levels, with field-level times,
  modeled labels, attribution and local budget balances. An Open-Meteo-only
  request also succeeded. These are local checks, not hosted acceptance.
- A future weather test caught METAR observations being used for requests
  thirty minutes ahead. Future instants now select the TAF path; current and
  recent-past instants retain observation priority. All 34 tests pass on macOS
  and native Linux release mode. Swift format, SwiftLint, actionlint, hadolint,
  shellcheck, yamllint and Markdown lint checks pass.
- Agent tooling audit reports unmapped Resend integrations in two unrelated
  repositories; no tooling changes were made there.

## Production bootstrap and signed checkpoint (2026-10-28)

- Signed commit b23d391 was pushed by the user after automatic approval review
  rejected the agent's Git push under approval policy never. GitHub has the
  exact signed commit and started the server and six-library workflows.
- The bootstrap x86 Linux image built and pushed at 141 MB, digest
  `sha256:354d78d6870652bc2dfdac675b6f26fe9f8d7da4ef86aa570ccc6216b914d16d`.
  Depot reported a timeout releasing its builder after the successful push.
  A separate image of b23d391 is building in the ingestion registry with the
  new Swift cache. The bootstrap image predates the latest result fixes.
- Production migrations succeeded with the ingestion role. The migration
  machine was removed. Aircraft acquisition/publication succeeded with 388
  profiles; that job machine was removed. DOF machine 857597a47e4498 is still
  importing and must be checked and removed after completion.
- Post-migration verification exposed Fly-created memberships in
  pg_read_all_data and pg_write_all_data. The privilege script now revokes
  both from the serving and ingestion roles. Production checks confirm the
  serving role can SELECT aviation records, cannot mutate them, can maintain
  weather caches, and neither application role inherits those broad roles.
- Private serving startup successfully validated the NOTAM role through the
  cross-organization Flycast connection. Full private MCP query verification
  is ongoing; no public serving deployment is claimed.
- The Fly machine-run tool joins multiple environment entries into one value;
  use shell exports for the bounded private probes. Its machine-update tool
  incorrectly dispatched machine-create and rejected --wait-timeout. Failed
  probe machines were removed, including 2862d2da0dd498 after its query check.
  GitHub's job connector
  returns Unknown tool; gh is being used to follow Actions.

## Production NOTAM query correction (2026-10-28)

- The first private MCP NOTAM query failed. PostgreSQL logs identified the
  cursor generation's whole-table count/max scan hitting its ten-second
  statement timeout on the 784 MB NOTAM table. Generation now uses the same
  location/time/scope predicate as the result query. A production EXPLAIN
  ANALYZE for the restricted aggregate used idx_notams_icao_location and took
  5.405 ms. The existing pagination test now checks unrelated changes remain
  resumable and matching-record changes expire the cursor; it failed before
  the fix and passed afterward.
- Production poll timestamps have fractional seconds. Timestamp parsing now
  accepts them for freshness checks and client times. Both related checks
  failed before the fix. All 34 tests pass on macOS and native Linux.
- Replayed the 44 captured KSFO overlap records through the current local MCP
  server using a read-only NOTAM role. Aerodrome scope returned 43 records,
  including 38 explicitly uncertain scope matches and 34 uncertain runway
  matches. Schedules and the exact ingestion freshness timestamp are preserved;
  no service error or spurious freshness warning remains. Hosted verification
  still needs the updated image.
- All six independent GitHub Linux library jobs passed. Server/container CI
  is still running. Ingestion commands now log normalization and publication
  phases to make full-distribution job progress observable.

## Retry metadata and rewritten dependency revisions (2026-10-28)

- Concurrent commit f8897ee repinned SwiftNASR, SwiftMETAR and SwiftGeographic
  after their upstream histories were rewritten. The library verification script
  and NASR provenance stamp now match those revisions; SwiftCIFP remains pinned
  and blocked pending the user's confirmation.
- Extended the existing cache/coalescing test to HTTP 503 with Retry-After.
  It failed because only HTTP 429 honored that header. Non-success responses now
  preserve supplied retry times and coordinate provider cooldowns; ordinary
  failures without a supplied retry time retain a bounded local estimate.
- All 34 tests pass on macOS and native Linux release mode with the revised
  pins. Swift format, SwiftLint, actionlint, hadolint, shellcheck and YAML lint
  pass. GitHub's b23d391 Linux server and deployment-container jobs passed; its
  macOS lint job is still queued.
- The production DOF job stopped making observable progress before publication.
  Its temporary source files are gone, its worker threads are idle, and no DOF
  version is published. Thread stacks were captured on the disposable job
  machine. A current-code Linux ingestion probe is being prepared to identify
  the phase; neither the import nor public deployment is complete.

## Verified image and full-distribution Linux probe (2026-10-28)

- Signed checkpoint 3c5c587 is on GitHub. All six library jobs passed with the
  rewritten revisions. The latest server/container jobs are still running and
  the macOS lint runner is queued.
- The image for 3c5c587 built and pushed at
  `registry.fly.io/aviation-mcp-ingest@sha256:d07e73ffe70c7062f2f78bb36a815fc724fbfac20ae324864b7fedd19fb29db0`.
  Its incremental compile took 182 seconds after the 2,017-second cache fill;
  the image remains 141 MB. Depot again reported a builder-release timeout
  after the successful push.
- Current-code native Linux acquisition/publication completed all 656,884 DOF
  records in 6m35s and exited zero. The representative 5 NM query used the
  aviation_geometry index and executed in 106.658 ms.
- Stopped and removed stalled bootstrap DOF machine 857597a47e4498 and marked
  its operational run failed. A separate purge command connected successfully;
  the stall's root cause remains undetermined. A retry omitted APP_ROLE=ingest
  and failed at startup; that machine was removed. Correctly configured retry
  811093f94de668 is now normalizing with the verified image and phase logging.
- Private serving machine 8d9e3ece0d7d78 returned 43 production KSFO NOTAM
  records through Flycast with correct fractional freshness timestamps and
  uncertainty warnings, plus the published B738 category D record. A live
  weather query fell back from an observation older than one hour to TAF wind
  and modeled temperature/pressure levels, with explicit field provenance.
  This private helper and its local proxy must be removed after verification.
- GitHub has the ingestion workflow on its default branch but its workflow
  endpoint returns 404 and it is absent from the registered-workflow list.
  Source-check-only push triggers now validate pipeline edits and provide an
  initial execution path. Publication and purge still require schedule/manual
  events. Actionlint and YAML lint pass. The image-variable write was rejected
  by automatic approval review under policy never and is pending user action.

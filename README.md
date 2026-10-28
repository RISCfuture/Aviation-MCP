# Aviation MCP

Swift 6.4/Vapor aviation server using the official MCP SDK at `/mcp`.
Implementation is ongoing; no hosted deployment is available yet. The local
server supports weather, supplied-report parsing, coordinate calculations,
source status and database-backed queries. Dataset acquisition, complete source
mappings and acceptance parity remain in progress.

## Linux dependency verification

Install Docker and start its daemon, then run:

```sh
docker pull swift:6.4.1-noble
scripts/verify-linux-libraries.sh
```

The script builds each pinned library target in a fresh Linux container in
release mode. It checks every library even if one fails and exits nonzero when
any build fails. To check one library, pass its name:

```sh
scripts/verify-linux-libraries.sh SwiftMETAR
```

Evidence is written to `.build/linux-libraries/`: one log per library, a TSV
containing revisions and exit codes, and the resolved container image digest.
Use a distinct `VERIFICATION_OUTPUT` directory for concurrent invocations.
`SWIFT_IMAGE` can select another pre-pulled Swift toolchain image.

GitHub Actions runs all six checks as independent matrix jobs and uploads the
logs even when a build fails. The workflow must pass before source-dependent
features are accepted. These are library build checks, not library test runs.

## Implementation references

- [Progress and decisions](docs/implementation-progress.md)
- [Original acceptance cases and Squawk comparison](docs/acceptance.md)

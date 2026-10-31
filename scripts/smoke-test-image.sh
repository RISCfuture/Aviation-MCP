#!/usr/bin/env bash
# Checks that a deployment image links, starts serving without a database and
# can run the terrain worker's Python stack.
set -euo pipefail

image=${1:?Supply the image to test}
port=${SMOKE_PORT:-18080}
container="aviation-mcp-smoke-$$"
# NOTAMs need their database at boot, so they are the one group left out.
groups=airports,navigation,airspace,procedures,obstacles,aircraft,weather,geography,status,terrain

# shellcheck disable=SC2329 # Invoked by the EXIT trap.
cleanup() {
  docker rm --force "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT

check_staging_commands() {
  docker run --rm --env APP_ROLE=stage "$image" --help >/dev/null
}

check_terrain_runtime() {
  docker run --rm --workdir /app/terrain --entrypoint /opt/terrain/bin/python "$image" \
    -c 'import numpy, pyproj, rasterio, worker'
}

check_serve_without_database() {
  docker run --detach --name "$container" --publish "127.0.0.1:$port:8080" \
    --env DATABASE_URL=postgres://aviation@127.0.0.1:9/unreachable \
    --env AVIATION_GROUPS="$groups" "$image" >/dev/null
  if ! curl --fail --silent --show-error --max-time 5 --retry 15 --retry-delay 1 \
    --retry-all-errors "http://127.0.0.1:$port/health" | jq -e '.status == "ok"' >/dev/null; then
    docker logs "$container" >&2
    return 1
  fi
}

check_staging_commands
check_terrain_runtime
check_serve_without_database
printf 'Image %s passed smoke tests.\n' "$image"

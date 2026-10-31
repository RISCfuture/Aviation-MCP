#!/usr/bin/env bash
# Checks that a deployment image links, migrates a fresh PostGIS database, serves under the
# serving role, refuses a role that can modify aviation data, and can run the terrain worker's
# Python stack.
set -euo pipefail

image=${1:?Supply the image to test}
postgis_image=${SMOKE_POSTGIS_IMAGE:-postgis/postgis:17-3.5}
port=${SMOKE_PORT:-18080}
privileges="$(dirname "$0")/database-privileges.sql"
network="aviation-mcp-smoke-$$"
database="$network-db" server="$network-serve" refused="$network-refused"
owner_url="postgres://postgres:smoke@$database:5432/aviation?sslmode=disable"
serving_url="postgres://aviation_serve:smoke@$database:5432/aviation?sslmode=disable"
# NOTAMs need their own database, so they are the one group left out.
groups=airports,navigation,airspace,procedures,obstacles,aircraft,weather,geography,status,terrain

# shellcheck disable=SC2329 # Invoked by the EXIT trap.
cleanup() {
  docker rm --force "$server" "$refused" "$database" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT

check_staging_commands() {
  docker run --rm --env APP_ROLE=stage "$image" --help >/dev/null
}

check_terrain_runtime() {
  docker run --rm --workdir /app/terrain --entrypoint /opt/terrain/bin/python "$image" \
    -c 'import numpy, pyproj, rasterio, worker'
}

# Waits for the final server; the image's initialization server accepts no TCP connections.
start_database() {
  docker network create "$network" >/dev/null
  docker run --detach --name "$database" --network "$network" \
    --env POSTGRES_PASSWORD=smoke --env POSTGRES_DB=aviation "$postgis_image" >/dev/null
  for _ in {1..90}; do
    if docker exec "$database" pg_isready --quiet --host 127.0.0.1 --username postgres; then
      return
    fi
    sleep 1
  done
  docker logs "$database" >&2
  return 1
}

psql() {
  docker exec --interactive --env PGOPTIONS=--client-min-messages=error "$database" \
    psql --quiet --username postgres --dbname aviation "$@"
}

check_migrations() {
  docker run --rm --network "$network" --env APP_ROLE=ingest \
    --env INGEST_DATABASE_URL="$owner_url" "$image" migrate --yes >/dev/null
}

create_roles() {
  psql --command "CREATE ROLE aviation_serve LOGIN PASSWORD 'smoke'" \
    --command "CREATE ROLE aviation_ingest LOGIN PASSWORD 'smoke'"
  psql <"$privileges" >/dev/null
}

serve() {
  local name=$1 url=$2
  shift 2
  docker run --detach --name "$name" --network "$network" --env DATABASE_URL="$url" \
    --env AVIATION_GROUPS="$groups" "$@" "$image" >/dev/null
}

check_serving_role() {
  serve "$server" "$serving_url" --publish "127.0.0.1:$port:8080"
  local request=(curl --fail --silent --show-error --max-time 5 --retry 15 --retry-delay 1
    --retry-all-errors)
  if ! "${request[@]}" "http://127.0.0.1:$port/health" | jq -e '.status == "ok"' >/dev/null \
    || ! "${request[@]}" "http://127.0.0.1:$port/ready" | jq -e '.status == "ready"' >/dev/null
  then
    docker logs "$server" >&2
    return 1
  fi
}

check_privileged_role_refused() {
  serve "$refused" "$owner_url"
  for _ in {1..30}; do
    [[ $(docker inspect --format '{{.State.Running}}' "$refused") == false ]] && break
    sleep 1
  done
  if ! docker logs "$refused" 2>&1 | grep 'DATABASE_URL must use the serving role' >/dev/null; then
    docker logs "$refused" >&2
    return 1
  fi
}

check_staging_commands
check_terrain_runtime
start_database
check_migrations
create_roles
check_serving_role
check_privileged_role_refused
printf 'Image %s passed smoke tests.\n' "$image"

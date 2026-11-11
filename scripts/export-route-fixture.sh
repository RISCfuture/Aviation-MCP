#!/usr/bin/env bash
# Exports the published NASR and CIFP records that the routes in
# Tests/AviationMCPTestData/RouteResolutionTests.txt can name, as the fixture the route
# resolution tests publish. Run it against a database holding a full ingested cycle whenever
# that file gains a route, then review the expectations in RouteResolutionTests.swift.
#
# Usage: DATABASE_URL=postgres://... scripts/export-route-fixture.sh
#    or: PSQL='docker exec -i CONTAINER psql -U postgres -d aviation' scripts/export-route-fixture.sh
set -euo pipefail

cd "$(dirname "$0")/.."
routes=Tests/AviationMCPTestData/RouteResolutionTests.txt
output=Tests/AviationMCPTestData/RouteResolutionRecords.jsonl
if [[ -n "${PSQL:-}" ]]; then
  read -r -a psql <<< "$PSQL"
else
  psql=(psql "${DATABASE_URL:?Set DATABASE_URL or PSQL}")
fi

# Every element of every route, split as the tool splits them and without speed suffixes.
names=$(tr -s ' .\t\r' '\n' < "$routes" | tr '[:lower:]' '[:upper:]' | sed 's|/.*||' \
  | grep -E '^[A-Z0-9]{1,8}$' | sort -u | paste -sd, -)

"${psql[@]}" -v ON_ERROR_STOP=1 -v names="$names" --no-psqlrc --quiet --tuples-only --no-align \
  > "$output" <<'SQL'
WITH names AS (SELECT unnest(string_to_array(:'names', ',')) AS name),
published AS (
  SELECT v.id, v.source, v.cycle FROM source_versions v
  JOIN manifest_versions mv ON mv.version_id = v.id
  JOIN active_manifest m ON m.manifest_id = mv.manifest_id
  WHERE v.source IN ('nasr', 'cifp') AND v.effective_from <= now() AND v.effective_until > now()),
airports AS (
  SELECT r.* FROM aviation_records r JOIN published p ON p.id = r.version_id AND p.source = 'nasr'
  WHERE r.kind = 'airport' AND (upper(r.identifier) IN (SELECT name FROM names)
    OR upper(r.data->>'faa_lid') IN (SELECT name FROM names))),
codes AS (
  SELECT upper(identifier) AS code FROM airports
  UNION SELECT upper(data->>'faa_lid') FROM airports
  UNION SELECT upper(data->>'icao_identifier') FROM airports),
selected AS (
  SELECT 'nasr' AS source, a.* FROM airports a
  UNION ALL
  SELECT 'nasr', r.* FROM aviation_records r
  JOIN published p ON p.id = r.version_id AND p.source = 'nasr'
  WHERE r.kind IN ('fix', 'navaid', 'airway') AND upper(r.identifier) IN (SELECT name FROM names)
  UNION ALL
  SELECT 'cifp', r.* FROM aviation_records r
  JOIN published p ON p.id = r.version_id AND p.source = 'cifp'
  WHERE r.kind = 'procedure' AND upper(r.identifier) IN (SELECT name FROM names)
    AND upper(r.airport) IN (SELECT code FROM codes)
    AND r.data->>'procedure_type' IN ('departure', 'arrival'))
SELECT jsonb_strip_nulls(jsonb_build_object(
  'source', s.source, 'cycle', p.cycle, 'kind', s.kind, 'id', s.id,
  'identifier', s.identifier, 'name', s.name, 'airport', s.airport, 'data', s.data,
  'geometry', ST_AsGeoJSON(s.geometry)::jsonb))::text
FROM selected s JOIN published p ON p.source = s.source
ORDER BY s.source, s.kind, s.id;
SQL
printf 'Wrote %s records to %s\n' "$(wc -l < "$output" | tr -d ' ')" "$output"

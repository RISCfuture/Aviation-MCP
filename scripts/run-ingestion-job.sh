#!/usr/bin/env bash
set -euo pipefail

: "${FLY_API_TOKEN:?Set the ingestion app deployment token}"
: "${AVIATION_INGEST_IMAGE:?Set a verified immutable image reference}"
command_name=${1:?Supply an ingestion command}
shift
case "$command_name" in
  ingest-sources|purge|migrate) ;;
  *) exit 2 ;;
esac

api=https://api.machines.dev/v1/apps/aviation-mcp-ingest/machines
work_dir=$(mktemp -d)
machine_id=
# shellcheck disable=SC2329 # Invoked by the EXIT trap.
cleanup() {
  local result=$?
  if [[ -n "$machine_id" ]]; then
    if ! curl --fail --silent --show-error --max-time 60 --request DELETE \
      --header "Authorization: Bearer $FLY_API_TOKEN" "$api/$machine_id?force=true" >/dev/null; then
      printf 'Cleanup failed for ingestion machine %s\n' "$machine_id" >&2
      result=1
    fi
  fi
  rm -rf "$work_dir"
  trap - EXIT
  exit "$result"
}
trap 'cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

jq -n --arg image "$AVIATION_INGEST_IMAGE" --arg command "$command_name" \
  --args '{region:"sjc", config:{image:$image,
    init:{exec:(["/usr/bin/timeout","2400","/app/aviation-mcp",$command] + $ARGS.positional)},
    env:{APP_ROLE:"ingest"}, restart:{policy:"no"}, auto_destroy:false,
    guest:{cpu_kind:"shared",cpus:4,memory_mb:8192},
    metadata:{aviation_job:"source-ingestion"}}}' -- "$@" > "$work_dir/request.json"
curl --fail-with-body --silent --show-error --max-time 120 --request POST \
  --header "Authorization: Bearer $FLY_API_TOKEN" --header 'Content-Type: application/json' \
  --data-binary "@$work_dir/request.json" "$api" > "$work_dir/machine.json"
machine_id=$(jq -er '.id' "$work_dir/machine.json")
printf 'Started private ingestion machine %s\n' "$machine_id"

for ((attempt = 0; attempt < 250; attempt++)); do
  curl --fail-with-body --silent --show-error --max-time 30 --retry 3 \
    --header "Authorization: Bearer $FLY_API_TOKEN" "$api/$machine_id" > "$work_dir/state.json"
  state=$(jq -r '.state' "$work_dir/state.json")
  if [[ "$state" == stopped ]]; then
    jq -e '
      [.events[] | select(.type == "exit")] | sort_by(.timestamp) | last |
      (.request.MonitorEvent.exit_event // .request.exit_event) |
      . != null and (.exit_code // 0) == 0 and (.guest_exit_code // 0) == 0
      and (.oom_killed != true) and (.requested_stop != true)
    ' "$work_dir/state.json" >/dev/null
    printf 'Ingestion machine completed successfully.\n'
    exit 0
  fi
  sleep 10
done
printf 'Ingestion job timed out.\n' >&2
exit 1

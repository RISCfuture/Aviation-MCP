#!/usr/bin/env bash
set -euo pipefail

: "${FLY_API_TOKEN:?Set the ingestion app deployment token}"
: "${AVIATION_INGEST_IMAGE:?Set a verified immutable image reference}"
command_name=${1:?Supply an ingestion command}
shift
# Each command's machine size and in-machine time limit in seconds. The GitHub job timeouts
# in .github/workflows/ingestion.yml allow each machine its limit plus poll_margin.
case "$command_name" in
  ingest-sources) cpus=4 memory_mb=8192 machine_timeout=3000 ;;
  migrate) cpus=1 memory_mb=2048 machine_timeout=1800 ;;
  purge) cpus=1 memory_mb=2048 machine_timeout=1200 ;;
  import-terrain) cpus=1 memory_mb=2048 machine_timeout=600 ;;
  *) exit 2 ;;
esac
poll_margin=300

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

last_exit_event() {
  jq '
    [.events[] | select(.type == "exit")] | sort_by(.timestamp) | last |
    (.request.MonitorEvent.exit_event // .request.exit_event)
  ' "$work_dir/state.json"
}

# Exits with the machine's own exit status, which reports a withheld release distinctly.
finish() {
  local event status
  event=$(last_exit_event)
  status=$(jq -r '
    if . == null or .oom_killed == true or .requested_stop == true then 1
    else [.guest_exit_code // 0, .exit_code // 0] | map(select(. != 0)) | first // 0
    end
  ' <<< "$event")
  if [[ "$status" == 0 ]]; then
    printf 'Ingestion machine completed successfully.\n'
    exit 0
  fi
  printf 'Ingestion machine %s failed: %s\n' "$machine_id" "$(jq -c . <<< "$event")" >&2
  exit $((status > 0 && status < 256 ? status : 1))
}

jq -n --arg image "$AVIATION_INGEST_IMAGE" --arg command "$command_name" \
  --arg timeout "$machine_timeout" --argjson cpus "$cpus" --argjson memory "$memory_mb" \
  --args '{region:"sjc", config:{image:$image,
    init:{exec:(["/usr/bin/timeout",$timeout,"/app/aviation-mcp",$command] + $ARGS.positional)},
    env:{APP_ROLE:"ingest"}, restart:{policy:"no"}, auto_destroy:false,
    guest:{cpu_kind:"shared",cpus:$cpus,memory_mb:$memory},
    metadata:{aviation_job:"source-ingestion"}}}' -- "$@" > "$work_dir/request.json"
curl --fail-with-body --silent --show-error --max-time 120 --request POST \
  --header "Authorization: Bearer $FLY_API_TOKEN" --header 'Content-Type: application/json' \
  --data-binary "@$work_dir/request.json" "$api" > "$work_dir/machine.json"
machine_id=$(jq -er '.id' "$work_dir/machine.json")
printf 'Started private ingestion machine %s\n' "$machine_id"

deadline=$((SECONDS + machine_timeout + poll_margin))
while ((SECONDS < deadline)); do
  curl --fail-with-body --silent --show-error --max-time 30 --retry 3 \
    --header "Authorization: Bearer $FLY_API_TOKEN" "$api/$machine_id" > "$work_dir/state.json"
  state=$(jq -r '.state' "$work_dir/state.json")
  case "$state" in
    stopped) finish ;;
    failed | destroying | destroyed)
      printf 'Ingestion machine %s entered state %s: %s\n' "$machine_id" "$state" \
        "$(last_exit_event | jq -c .)" >&2
      exit 1
      ;;
  esac
  sleep 10
done
printf 'Ingestion job timed out.\n' >&2
exit 1

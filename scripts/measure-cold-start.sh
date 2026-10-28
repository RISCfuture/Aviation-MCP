#!/usr/bin/env bash
set -euo pipefail

endpoint=${1:-https://aviation-mcp.org/mcp}
output_dir=${2:-.build/cold-start}
mkdir -p "$output_dir"

stop_app() {
  local app=$1
  local machines
  machines=$(fly machine list --app "$app" --json | jq -r '.[] | select(.state == "started") | .id')
  while IFS= read -r machine; do
    if [[ -n "$machine" ]]; then
      fly machine stop "$machine" --app "$app" --timeout 120 --wait-timeout 150s
    fi
  done <<< "$machines"
}

measure() {
  local label=$1
  curl --fail-with-body --silent --show-error --max-time 60 \
    --header 'Content-Type: application/json' \
    --header 'Accept: application/json' \
    --header 'MCP-Protocol-Version: 2025-06-18' \
    --data '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_data_status"}}' \
    --output "$output_dir/$label.json" \
    --write-out "$label: HTTP %{http_code}, first byte %{time_starttransfer}s, total %{time_total}s\n" \
    "$endpoint"
  jq -e '.result.isError != true and .result.structuredContent.results != null' \
    "$output_dir/$label.json" >/dev/null
}

stop_app aviation-mcp-server
stop_app aviation-mcp-db
measure cold
measure warm

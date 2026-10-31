#!/usr/bin/env bash
# Cold-starts the public endpoint through the edge and confirms the serving
# machines run the expected image.
set -euo pipefail

expected_image=${1:?Supply the image the serving app should run}
site=${2:-https://aviation-mcp.org}
scripts=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

request() {
  curl --fail-with-body --silent --show-error --max-time 60 \
    --retry 6 --retry-delay 10 --retry-all-errors "$@"
}

check_ready() {
  request "$site/ready" | jq -e '.status == "ready"' >/dev/null
}

check_tools() {
  request --header 'Content-Type: application/json' \
    --header 'Accept: application/json, text/event-stream' \
    --header 'MCP-Protocol-Version: 2025-06-18' \
    --data '{"jsonrpc":"2.0","id":"deploy-smoke","method":"tools/list"}' \
    "$site/mcp" | jq -e '.result.tools | length > 0' >/dev/null
}

check_serving_image() {
  local serving
  serving=$("$scripts/deployed-image.sh")
  if [[ "$serving" != "$expected_image" ]]; then
    printf 'Serving %s instead of %s\n' "$serving" "$expected_image" >&2
    return 1
  fi
}

check_ready
check_tools
check_serving_image
printf 'Deployment of %s answered through %s.\n' "$expected_image" "$site"

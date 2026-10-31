#!/usr/bin/env bash
# Prints the immutable image reference every serving machine runs, failing
# unless they all run the same one.
set -euo pipefail

: "${FLY_API_TOKEN:?Set a token that can read the serving app}"
app=${1:-aviation-mcp-server}

curl --fail-with-body --silent --show-error --max-time 30 --retry 3 \
  --header "Authorization: Bearer $FLY_API_TOKEN" \
  "https://api.machines.dev/v1/apps/$app/machines" |
  jq -er '
    [.[] | select(.config.metadata.fly_process_group == "app") | .image_ref
      | "\(.registry)/\(.repository)@\(.digest)"] | unique
    | if length == 1 then .[0]
      else error("Expected one serving image, found \(length): \(join(", "))") end
  '

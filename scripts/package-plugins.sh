#!/usr/bin/env bash
# Validates the Aviation MCP plugin and builds its OpenAI and Claude submission ZIPs.
# Usage: scripts/package-plugins.sh [output-directory]  (default: dist/plugins)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
plugin="$root/plugins/aviation-mcp"
output="${1:-$root/dist/plugins}"
openai_manifest="$plugin/plugin.json"
claude_manifest="$plugin/.claude-plugin/plugin.json"

manifest_field() {
  jq --raw-output --arg field "$2" '.[$field]' "$1"
}

check_manifests_agree() {
  local field openai claude
  for field in name version description; do
    openai="$(manifest_field "$openai_manifest" "$field")"
    claude="$(manifest_field "$claude_manifest" "$field")"
    if [[ "$openai" != "$claude" ]]; then
      echo "Manifests disagree on $field: plugin.json has '$openai'," \
        ".claude-plugin/plugin.json has '$claude'." >&2
      exit 1
    fi
  done
}

validate() {
  claude plugin validate --strict "$plugin"
  claude plugin validate --strict "$root/.claude-plugin/marketplace.json"
}

# Zips the named entries of the plugin directory, without macOS metadata or extra attributes.
build_zip() {
  local archive="$1"
  shift
  rm -f "$archive"
  (cd "$plugin" && zip --quiet --recurse-paths -X "$archive" "$@" --exclude '*.DS_Store')
  echo "Built $archive"
}

check_manifests_agree
validate
version="$(manifest_field "$openai_manifest" version)"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
build_zip "$output/aviation-mcp-openai-$version.zip" plugin.json mcp.json assets skills
build_zip "$output/aviation-mcp-claude-$version.zip" \
  .claude-plugin .mcp.json assets skills README.md LICENSE

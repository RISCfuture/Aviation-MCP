#!/usr/bin/env bash
set -euo pipefail

source_name=${1:?Supply a source group}
checked_dir=${2:?Supply the checked release directory}
report_file=${3:?Supply the result report path}
# The exit status of an ingestion job whose release was withheld as incomplete.
withheld_status=3
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
mkdir -p "$(dirname "$report_file")"

case "$source_name" in
  navigation) checked=("$checked_dir/nasr.json" "$checked_dir/cifp.json") ;;
  *) checked=("$checked_dir/$source_name.json") ;;
esac
for file in "${checked[@]}"; do
  if [[ -f "$file" ]]; then jq -c '.[] | [.]' "$file"; fi
done > "$work_dir/plans.jsonl"
if [[ ! -s "$work_dir/plans.jsonl" ]]; then
  printf 'No checked releases available for %s\n' "$source_name" >&2
  exit 1
fi
jq -s 'map({downloads: ., status: "pending"})' "$work_dir/plans.jsonl" > "$report_file"

failed=false
index=0
while IFS= read -r plan; do
  jq -r '.[] | "Checking \(.source) cycle \(.cycle), effective \(.effectiveFrom)"' <<< "$plan"
  encoded=$(jq -r '@base64' <<< "$plan")
  if scripts/run-ingestion-job.sh ingest-sources "$encoded"; then
    status=success
  elif (($? == withheld_status)); then
    status=withheld
    failed=true
  else
    status=failure
    failed=true
  fi
  jq --argjson index "$index" --arg status "$status" '.[$index].status = $status' \
    "$report_file" > "$work_dir/report.json"
  mv "$work_dir/report.json" "$report_file"
  index=$((index + 1))
done < "$work_dir/plans.jsonl"

[[ "$failed" == false ]]

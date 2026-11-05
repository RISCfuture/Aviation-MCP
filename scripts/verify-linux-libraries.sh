#!/usr/bin/env bash
set -euo pipefail

readonly image="${SWIFT_IMAGE:-swift:6.4-noble}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly root
readonly output="${VERIFICATION_OUTPUT:-$root/.build/linux-libraries}"
readonly library="${1:-all}"
# Each library as owner/repository/target; the repository name selects it on the command line.
readonly libraries=(
  RISCfuture/SwiftNASR/SwiftNASR
  RISCfuture/SwiftCIFP/SwiftCIFP
  RISCfuture/SwiftDOF/SwiftDOF
  RISCfuture/SwiftACD/SwiftACD
  RISCfuture/SwiftMETAR/SwiftMETAR
  RISCfuture/SwiftGeographic/SwiftGeographic
  SF50-TOLD/SF50-Performance/SF50Performance
  RISCfuture/MeasurementKit/MeasurementKit
)
mkdir -p "$output"

pinned_revision() {
  jq -er --arg name "$1" \
    '.pins[] | select(.identity == ($name | ascii_downcase)) | .state.revision' \
    "$root/Package.resolved"
}

verify_library() {
  local owner="$1" name="$2" target="$3" revision result=0
  if [[ "$library" != all && "$library" != "$name" ]]; then
    return
  fi
  # shellcheck disable=SC2310 # The lookup is one jq call; its status is what is tested.
  if ! revision=$(pinned_revision "$name"); then
    printf '%s has no pinned revision in Package.resolved\n' "$name" | tee "$output/$name.log"
    printf '%s\t%s\t%s\n' "$name" unpinned 1 >> "$output/results.tsv"
    failed=1
    return
  fi
  printf 'Building %s/%s at %s\n' "$owner" "$name" "$revision"
  docker run --rm --init \
    "$image" bash -c '
      set -euo pipefail
      owner="$1"
      name="$2"
      revision="$3"
      target="$4"
      git clone --quiet "https://github.com/$owner/$name.git" /library
      cd /library
      git checkout --quiet "$revision"
      swift --version
      swift build --build-system native --target "$target" --configuration release --jobs 4
    ' bash "$owner" "$name" "$revision" "$target" > "$output/$name.log" 2>&1 || result=$?
  printf '%s\t%s\t%s\n' "$name" "$revision" "$result" >> "$output/results.tsv"
  tail -n 15 "$output/$name.log"
  if (( result != 0 )); then
    failed=1
  fi
}

matches=0
for entry in "${libraries[@]}"; do
  [[ "$entry" == */"$library"/* ]] && matches=1
done
if [[ "$library" != all ]] && (( matches == 0 )); then
  printf 'Unknown library: %s\n' "$library" >&2
  exit 2
fi

docker image inspect "$image" --format '{{index .RepoDigests 0}}' > "$output/image.txt"
: > "$output/results.tsv"
failed=0
for entry in "${libraries[@]}"; do
  IFS=/ read -r owner name target <<< "$entry"
  verify_library "$owner" "$name" "$target"
done
exit "$failed"

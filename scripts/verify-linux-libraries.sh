#!/usr/bin/env bash
set -euo pipefail

readonly image="${SWIFT_IMAGE:-swift:6.4.1-noble}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly root
readonly output="${VERIFICATION_OUTPUT:-$root/.build/linux-libraries}"
readonly library="${1:-all}"
mkdir -p "$output"

pinned_revision() {
  jq -er --arg name "$1" \
    '.pins[] | select(.identity == ($name | ascii_downcase)) | .state.revision' \
    "$root/Package.resolved"
}

verify_library() {
  local name="$1" revision result=0
  if [[ "$library" != all && "$library" != "$name" ]]; then
    return
  fi
  revision=$(pinned_revision "$name")
  printf 'Building %s at %s\n' "$name" "$revision"
  docker run --rm --init \
    "$image" bash -c '
      set -euo pipefail
      name="$1"
      revision="$2"
      git clone --quiet "https://github.com/RISCfuture/$name.git" /library
      cd /library
      git checkout --quiet "$revision"
      swift --version
      swift build --build-system native --target "$name" --configuration release --jobs 4
    ' bash "$name" "$revision" > "$output/$name.log" 2>&1 || result=$?
  printf '%s\t%s\t%s\n' "$name" "$revision" "$result" >> "$output/results.tsv"
  tail -n 15 "$output/$name.log"
  if (( result != 0 )); then
    failed=1
  fi
}

case "$library" in
  all|SwiftNASR|SwiftCIFP|SwiftDOF|SwiftACD|SwiftMETAR|SwiftGeographic) ;;
  *) printf 'Unknown library: %s\n' "$library" >&2; exit 2 ;;
esac

docker image inspect "$image" --format '{{index .RepoDigests 0}}' > "$output/image.txt"
: > "$output/results.tsv"
failed=0
for name in SwiftNASR SwiftCIFP SwiftDOF SwiftACD SwiftMETAR SwiftGeographic; do
  verify_library "$name"
done
exit "$failed"

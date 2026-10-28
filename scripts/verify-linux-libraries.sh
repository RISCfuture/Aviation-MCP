#!/usr/bin/env bash
set -euo pipefail

readonly image="${SWIFT_IMAGE:-swift:6.4.1-noble}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly root
readonly output="${VERIFICATION_OUTPUT:-$root/.build/linux-libraries}"
readonly library="${1:-all}"
mkdir -p "$output"

verify_library() {
  local name="$1" revision="$2" result=0
  if [[ "$library" != all && "$library" != "$name" ]]; then
    return
  fi
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
verify_library SwiftNASR 43793427d3ff4cac842981405a38aad62bb15e57
verify_library SwiftCIFP e80a87c3b8edba9cd60ad00bf69b1aa4e164af46
verify_library SwiftDOF 5630d134e371347c5302f0d0b17440103dbacbf8
verify_library SwiftACD 9c70df543447d3c886211aa3669fead87ce41258
verify_library SwiftMETAR 0e7d39936dd0d4c8b3c4f78d09e1a908648fc647
verify_library SwiftGeographic 49fad28c575a8efd6e8a154fdf579982d2eeebf9
exit "$failed"

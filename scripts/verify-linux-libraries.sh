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
verify_library SwiftNASR a4d56cc686e148460a200eeff5751c2beed36847
verify_library SwiftCIFP d57301f98db1b850b9c57d823c7f7dcf996fc730
verify_library SwiftDOF 5afe24c34e7ee72c9f31ae8ac23e754bc6ba1217
verify_library SwiftACD 2d01856fb7b78b11fe614e01b5c4c4483add09f6
verify_library SwiftMETAR 649e70912e0c1cc21c275545bd26af126bd79326
verify_library SwiftGeographic 5b166c0730dc3dd7ba85242ab2696556202d73a9
exit "$failed"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
study="$(git rev-parse --show-toplevel)/.cache/pair-study"
output="${1:-$study/confirmation-results}"
app=dist/PelagiVex.app/Contents/MacOS/PelagiVexNative
mkdir -p "$output"

for spec in "trace-10fps.json 1 2 tum-10hz-crossing1" "trace-10fps.json 67 92 tum-10hz-crossing2" \
  "trace.json 1 2 tum-5hz-crossing1" "trace.json 81 106 tum-5hz-crossing2"; do
  read -r trace a b name <<< "$spec"
  "$app" --pair-replay "$study/$trace" "$a" "$b" > "$output/$name.md"
done

for spec in "bonn-chairs-near 2 1 8" "bonn-chairs-far 1 2 6" "bonn-crowd3 27 1 2"; do
  read -r clip a b cap <<< "$spec"
  trace="$study/$clip/trace.json"
  reference="$study/$clip/independent.json"
  "$app" --pair-replay "$trace" "$a" "$b" "$reference" > "$output/$clip-independent.md"
  "$app" --pair-replay "$trace" "$a" "$b" > "$output/$clip-shared.md"
  if [[ "$clip" != bonn-crowd3 ]]; then
    "$app" --pair-replay "$trace" "$a" "$b" "$reference" --cap "$cap" > "$output/$clip-matched.md"
  fi
done

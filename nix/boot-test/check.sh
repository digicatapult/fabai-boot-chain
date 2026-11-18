#!/usr/bin/env bash
# Passes or fails the boot test on the verdict run.sh recorded. On a pass, the
# logs become this derivation's output; on a failure, the build log ends with
# the reasons and the tail of both consoles.
# Usage: check.sh <run.sh output directory> <output directory>
set -euo pipefail

run="$1"
out="$2"

cat "$run/verdict"
if [[ "$(head -n 1 "$run/verdict")" == PASS* ]]; then
  mkdir -p "$out"
  cp "$run"/*.log "$out/"
  exit 0
fi

printf '\n--- serial console (last 200 lines) ---\n'
tail -n 200 "$run/serial.log"
if [[ -s "$run/debugcon.log" ]]; then
  printf '\n--- debug console (last 200 lines) ---\n'
  tail -n 200 "$run/debugcon.log"
fi
exit 1

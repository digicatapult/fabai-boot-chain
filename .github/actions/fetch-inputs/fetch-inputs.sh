#!/usr/bin/env bash
# Fetches the flake inputs quietly. Called by action.yml, which sets EDK2_REV;
# the runner sets RUNNER_TEMP and GITHUB_STEP_SUMMARY. Run from the flake root.
set -euo pipefail

log="$RUNNER_TEMP/fetch-inputs.log"
: > "$log"

run_quietly() {
  if ! "$@" >> "$log" 2>&1; then
    printf 'failed: %s\n--- last 200 lines of output ---\n' "$*"
    tail -n 200 "$log"
    exit 1
  fi
}

if [[ -n "$EDK2_REV" ]]; then
  if [[ ! "$EDK2_REV" =~ ^[0-9a-f]{40}$ ]]; then
    printf 'edk2-rev must be a full commit SHA, got: %s\n' "$EDK2_REV"
    exit 1
  fi
  printf 'Re-locking edk2 to master at %s\n' "$EDK2_REV"
  run_quietly nix flake lock --override-input edk2 \
    "git+https://github.com/tianocore/edk2?ref=master&rev=${EDK2_REV}&submodules=1&shallow=1"
fi

started=$SECONDS
run_quietly nix flake archive
printf 'Fetched flake inputs in %ss (%s lines of output, not shown)\n' \
  "$((SECONDS - started))" "$(wc -l < "$log")"

locked_rev="$(jq -r '.nodes.edk2.locked.rev' flake.lock)"
if [[ -n "$EDK2_REV" && "$locked_rev" != "$EDK2_REV" ]]; then
  printf 'flake.lock has edk2 %s after re-locking to %s\n' "$locked_rev" "$EDK2_REV"
  exit 1
fi
printf 'edk2: %s\n' "$locked_rev"

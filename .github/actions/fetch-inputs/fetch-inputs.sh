#!/usr/bin/env bash
# Called by action.yml. Run from the flake root.
#   prepare  re-lock edk2 to EDK2_REV if set; write cache-key to GITHUB_OUTPUT
#   export   fetch the inputs, then write them as a Nix binary cache, with
#            flake.lock, to CACHE_DIR
# Fetching edk2 with its submodules prints around 100,000 lines of git progress
# and refs, so that output goes to a file and is only printed on failure.
set -euo pipefail

log="$RUNNER_TEMP/fetch-inputs.log"
touch "$log"

run_quietly() {
  if ! "$@" 2>> "$log"; then
    printf 'failed: %s\n--- last 200 lines of output ---\n' "$*"
    tail -n 200 "$log"
    exit 1
  fi
}

prepare() {
  if [[ -n "$EDK2_REV" ]]; then
    if [[ ! "$EDK2_REV" =~ ^[0-9a-f]{40}$ ]]; then
      printf 'edk2-rev must be a full commit SHA, got: %s\n' "$EDK2_REV"
      exit 1
    fi
    printf 'Re-locking edk2 to master at %s (fetches edk2)\n' "$EDK2_REV"
    run_quietly nix flake lock --override-input edk2 \
      "git+https://github.com/tianocore/edk2?ref=master&rev=${EDK2_REV}&submodules=1&shallow=1"
    local locked_rev
    locked_rev="$(jq -r '.nodes.edk2.locked.rev' flake.lock)"
    if [[ "$locked_rev" != "$EDK2_REV" ]]; then
      printf 'flake.lock has edk2 %s after re-locking to %s\n' "$locked_rev" "$EDK2_REV"
      exit 1
    fi
  fi

  # Bump v1 to discard every cached entry, for example if the format changes.
  local key
  key="flake-inputs-v1-$(sha256sum flake.lock | cut -d ' ' -f 1)"
  printf 'edk2 %s, cache key %s\n' "$(jq -r '.nodes.edk2.locked.rev' flake.lock)" "$key"
  printf 'cache-key=%s\n' "$key" >> "$GITHUB_OUTPUT"
}

export_inputs() {
  local started=$SECONDS archive
  archive="$RUNNER_TEMP/flake-archive.json"
  run_quietly nix flake archive --json > "$archive"
  printf 'Fetched flake inputs in %ss (%s lines of output, not shown)\n' \
    "$((SECONDS - started))" "$(wc -l < "$log")"

  # The inputs only: the flake's own source changes with every commit, and
  # each job has it from its checkout.
  local paths
  mapfile -t paths < <(jq -r '.inputs | .. | objects | select(has("path")) | .path' "$archive")
  if ((${#paths[@]} == 0)); then
    printf 'nix flake archive listed no inputs:\n'
    cat "$archive"
    exit 1
  fi

  rm -rf "$CACHE_DIR"
  run_quietly nix copy --to "file://${CACHE_DIR}?compression=zstd" "${paths[@]}"
  cp flake.lock "$CACHE_DIR/flake.lock"
  printf 'Exported %s to %s (%s)\n' "${paths[*]}" "$CACHE_DIR" "$(du -sh "$CACHE_DIR" | cut -f 1)"
}

case "${1:-}" in
  prepare) prepare ;;
  export) export_inputs ;;
  *)
    printf 'usage: %s prepare|export\n' "$0"
    exit 1
    ;;
esac

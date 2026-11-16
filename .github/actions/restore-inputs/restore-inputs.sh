#!/usr/bin/env bash
# Imports the binary cache written by fetch-inputs into the Nix store, and puts
# its flake.lock in the workspace. Called by action.yml, which sets CACHE_KEY
# and CACHE_DIR. Run from the flake root.
set -euo pipefail

# The key is the SHA-256 of the flake.lock it was saved with.
expected="${CACHE_KEY##*-}"
actual="$(sha256sum "$CACHE_DIR/flake.lock" | cut -d ' ' -f 1)"
if [[ "$actual" != "$expected" ]]; then
  printf 'Cached flake.lock is %s, but the cache key says %s\n' "$actual" "$expected"
  exit 1
fi
# The same lock for stable builds; the re-locked one for HEAD builds.
cp "$CACHE_DIR/flake.lock" flake.lock

started=$SECONDS
nix copy --from "file://${CACHE_DIR}" --all
rm -rf "$CACHE_DIR"
printf 'Imported flake inputs in %ss; edk2 %s\n' \
  "$((SECONDS - started))" "$(jq -r '.nodes.edk2.locked.rev' flake.lock)"

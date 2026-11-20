#!/usr/bin/env bash
# Watches tianocore/edk2 for what may need a firmware release, and raises each
# event once as an issue in this repository (README, "Upstream watch"):
#   - stable tags newer than the pin (tags.sh)
#   - security advisories published since the cut-off (advisories.sh)
#   - commits on master touching the SEV paths, not in the pin (sev-commits.sh)
# Opens issues and comments, edits its own markers, reopens a closed issue it
# reports an update on (removing `triaged`), closes SEV-commit issues of
# earlier pins, and creates its labels. Nothing else.
#
# Run from the repository root. Environment:
#   GITHUB_REPOSITORY  where to raise issues
#   GH_TOKEN           needs issues: write (read-only with DRY_RUN=true)
#   DRY_RUN            true to print every write instead of making it
set -euo pipefail
# So that a failure inside $(…) fails the assignment it feeds.
shopt -s inherit_errexit

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly here
# shellcheck source=scripts/upstream-watch/lib.sh
source "$here/lib.sh"
# shellcheck source=scripts/upstream-watch/tags.sh
source "$here/tags.sh"
# shellcheck source=scripts/upstream-watch/advisories.sh
source "$here/advisories.sh"
# shellcheck source=scripts/upstream-watch/sev-commits.sh
source "$here/sev-commits.sh"

REPO="${GITHUB_REPOSITORY:?}"
DRY_RUN="${DRY_RUN:-false}"
[[ "$DRY_RUN" == true || "$DRY_RUN" == false ]] || fail "DRY_RUN must be true or false, got $DRY_RUN"
WORK="$(mktemp -d)"
ISSUES="$WORK/issues.json"
readonly REPO DRY_RUN WORK ISSUES
trap 'rm -rf "$WORK"' EXIT

# The pin, from flake.lock: checked before anything upstream is read.
PIN_TAG="$(jq -r '.nodes.edk2.original.ref // "" | ltrimstr("refs/tags/")' flake.lock)"
PIN_COMMIT="$(jq -r '.nodes.edk2.locked.rev // ""' flake.lock)"
readonly PIN_TAG PIN_COMMIT
[[ "$PIN_TAG" =~ $STABLE_TAG ]] ||
  fail "flake.lock must pin edk2 to a stable tag, refs/tags/edk2-stableYYYYMM[.NN], got $(jq -r '.nodes.edk2.original.ref' flake.lock)"
[[ "$PIN_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "flake.lock must lock edk2 to a full commit SHA, got $PIN_COMMIT"
printf 'Pinned: %s (%s)\n' "$PIN_TAG" "$PIN_COMMIT"
if [[ "$DRY_RUN" == true ]]; then
  printf 'Dry run: nothing will be written\n'
fi

load_issues
watch_tags
watch_advisories
watch_sev_commits

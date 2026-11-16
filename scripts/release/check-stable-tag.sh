#!/usr/bin/env bash
# Checks a stable release tag before anything is built. Run from a full clone
# (fetch-depth: 0) at the tagged commit. Environment:
#   TAG          the pushed tag, ovmf-edk2-stableYYYYMM[.NN]-rN
#   GITHUB_SHA   the tagged commit
# Writes edk2-tag and edk2-rev to GITHUB_OUTPUT.
set -euo pipefail

readonly tag_pattern='^ovmf-(edk2-stable[0-9]{6}(\.[0-9]{2})?)-r[1-9][0-9]*$'
readonly edk2_url='https://github.com/tianocore/edk2'

fail() {
  printf 'error: %s\n' "$1"
  exit 1
}

[[ "$TAG" =~ $tag_pattern ]] || fail "tag $TAG doesn't match ovmf-edk2-stableYYYYMM[.NN]-rN"
edk2_tag="${BASH_REMATCH[1]}"

# The tag names the edk2 release; flake.lock decides what is built.
original_ref="$(jq -r '.nodes.edk2.original.ref' flake.lock)"
locked_ref="$(jq -r '.nodes.edk2.locked.ref' flake.lock)"
locked_rev="$(jq -r '.nodes.edk2.locked.rev' flake.lock)"
for ref in "$original_ref" "$locked_ref"; do
  [[ "$ref" == "refs/tags/${edk2_tag}" ]] ||
    fail "tag $TAG is for ${edk2_tag}, but flake.lock pins edk2 ${ref}"
done

# flake.lock must pin the commit upstream's tag points at today. An annotated
# tag is listed twice; the peeled (^{}) line is the commit.
upstream="$(git ls-remote "$edk2_url" "refs/tags/${edk2_tag}" "refs/tags/${edk2_tag}^{}")"
upstream_rev="$(awk '$2 ~ /\^\{\}$/ { print $1; found = 1 } END { if (!found) exit 1 }' <<< "$upstream" ||
  awk 'NR == 1 { print $1 }' <<< "$upstream")"
[[ -n "$upstream_rev" ]] || fail "${edk2_tag} doesn't exist in ${edk2_url}"
[[ "$upstream_rev" == "$locked_rev" ]] ||
  fail "flake.lock pins edk2 ${locked_rev}, but upstream ${edk2_tag} is ${upstream_rev}"

# Only reviewed code is released.
git merge-base --is-ancestor "$GITHUB_SHA" origin/main ||
  fail "tag $TAG points at ${GITHUB_SHA}, which is not on main"

printf 'Releasing %s: edk2 %s (%s), overlay %s\n' "$TAG" "$edk2_tag" "$locked_rev" "$GITHUB_SHA"
{
  printf 'edk2-tag=%s\n' "$edk2_tag"
  printf 'edk2-rev=%s\n' "$locked_rev"
} >> "$GITHUB_OUTPUT"

#!/usr/bin/env bash
# Decides whether today's HEAD release should run. Environment:
#   GITHUB_SHA, GITHUB_REPOSITORY, GH_TOKEN
# Writes to GITHUB_OUTPUT:
#   skip       true if this (edk2 master commit, overlay commit) pair is
#              already released, or today's tag for this edk2 commit exists
#   edk2-rev   the edk2 master commit to build
#   tag        ovmf-head-YYYYMMDD-<edk2 commit, 12 characters>
#   title      the release title
set -euo pipefail

readonly edk2_url='https://github.com/tianocore/edk2'

edk2_rev="$(git ls-remote "$edk2_url" refs/heads/master | cut -f 1)"
if [[ ! "$edk2_rev" =~ ^[0-9a-f]{40}$ ]]; then
  printf 'error: could not resolve edk2 master, got: %s\n' "$edk2_rev"
  exit 1
fi

today="$(date -u +%Y%m%d)"
tag="ovmf-head-${today}-${edk2_rev:0:12}"
# Written into every HEAD release's notes by scripts/release/assemble.sh.
marker="<!-- fabai-head edk2=${edk2_rev} overlay=${GITHUB_SHA} -->"

skip=false
# Read every HEAD release's notes before searching them: a failed API call
# then fails the job instead of looking like "not released", and grep -q
# can't cut gh off mid-stream (SIGPIPE under pipefail).
notes="$(gh api --paginate "repos/${GITHUB_REPOSITORY}/releases?per_page=100" \
  --jq '.[] | select(.tag_name | startswith("ovmf-head-")) | .body')"
tag_status=0
git ls-remote --exit-code --tags "https://github.com/${GITHUB_REPOSITORY}" \
  "refs/tags/${tag}" > /dev/null || tag_status=$?

if grep -qF -- "$marker" <<< "$notes"; then
  printf 'Already released: edk2 %s with overlay %s\n' "$edk2_rev" "$GITHUB_SHA"
  skip=true
elif ((tag_status == 0)); then
  # Same edk2 commit, same day, but a newer overlay commit. Tomorrow's run
  # releases it under a new date.
  printf '%s already exists for an older overlay commit; retrying tomorrow\n' "$tag"
  skip=true
elif ((tag_status == 2)); then
  printf 'Releasing %s: edk2 master %s, overlay %s\n' "$tag" "$edk2_rev" "$GITHUB_SHA"
else
  # 2 means no such tag; anything else is an error, not an answer.
  printf 'error: git ls-remote for %s failed with status %s\n' "$tag" "$tag_status"
  exit 1
fi

{
  printf 'skip=%s\n' "$skip"
  printf 'edk2-rev=%s\n' "$edk2_rev"
  printf 'tag=%s\n' "$tag"
  printf 'title=OVMF HEAD %s-%s-%s (edk2 %s)\n' "${today:0:4}" "${today:4:2}" "${today:6:2}" "${edk2_rev:0:12}"
} >> "$GITHUB_OUTPUT"

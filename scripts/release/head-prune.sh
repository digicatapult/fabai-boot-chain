#!/usr/bin/env bash
# Keeps the newest KEEP HEAD prereleases and deletes the rest, with their tags.
# Stable releases are never touched. Environment:
#   KEEP, GITHUB_REPOSITORY, GH_TOKEN
set -euo pipefail

[[ "$KEEP" =~ ^[1-9][0-9]*$ ]] || {
  printf 'error: KEEP must be a positive integer, got: %s\n' "$KEEP"
  exit 1
}

mapfile -t tags < <(
  gh api --paginate "repos/${GITHUB_REPOSITORY}/releases?per_page=100" \
    --jq '.[] | select(.prerelease and (.draft | not) and (.tag_name | startswith("ovmf-head-")))
              | [.created_at, .tag_name] | @tsv' |
    sort -r | cut -f 2
)

printf '%d HEAD releases, keeping %d\n' "${#tags[@]}" "$KEEP"
for tag in "${tags[@]:KEEP}"; do
  printf 'Deleting %s\n' "$tag"
  gh release delete "$tag" --repo "$GITHUB_REPOSITORY" --cleanup-tag --yes
done

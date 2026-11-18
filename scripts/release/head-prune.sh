#!/usr/bin/env bash
# Keeps the newest KEEP HEAD prereleases and deletes the rest, with their tags.
# Also deletes every HEAD draft: a publish that failed, was cancelled or timed
# out after creating its draft leaves one behind, and the next day's tag never
# matches it. This runs after a successful publish, and release-head.yml runs
# one at a time, so any HEAD draft left is stale. Stable releases are never
# touched. Needs a token with contents: write, which can see drafts.
# Environment:
#   KEEP, GITHUB_REPOSITORY, GH_TOKEN
set -euo pipefail

[[ "$KEEP" =~ ^[1-9][0-9]*$ ]] || {
  printf 'error: KEEP must be a positive integer, got: %s\n' "$KEEP"
  exit 1
}

releases="$(gh api --paginate "repos/${GITHUB_REPOSITORY}/releases?per_page=100" \
  --jq '.[] | select(.tag_name | startswith("ovmf-head-"))
            | [(.draft | tostring), (.prerelease | tostring), .created_at, (.id | tostring), .tag_name]
            | @tsv')"

# A draft has no tag yet, so it is deleted by ID rather than by tag name.
mapfile -t drafts < <(awk -F '\t' '$1 == "true" { print $4 "\t" $5 }' <<< "$releases")
printf '%d stale HEAD drafts\n' "${#drafts[@]}"
for draft in "${drafts[@]}"; do
  printf 'Deleting draft %s (release %s)\n' "${draft#*$'\t'}" "${draft%%$'\t'*}"
  gh api --method DELETE "repos/${GITHUB_REPOSITORY}/releases/${draft%%$'\t'*}" > /dev/null
done

mapfile -t tags < <(
  awk -F '\t' '$1 == "false" && $2 == "true" { print $3 "\t" $5 }' <<< "$releases" |
    sort -r | cut -f 2
)
printf '%d HEAD releases, keeping %d\n' "${#tags[@]}" "$KEEP"
for tag in "${tags[@]:KEEP}"; do
  printf 'Deleting %s\n' "$tag"
  gh release delete "$tag" --repo "$GITHUB_REPOSITORY" --cleanup-tag --yes
done

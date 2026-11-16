#!/usr/bin/env bash
# Publishes the assembled release. The release is created as a draft with all
# its assets, then published in one step, so nobody downloads a half-uploaded
# release. Environment:
#   TRACK    stable: the tag already exists (pushed by a maintainer)
#            head: the tag is created at GITHUB_SHA; prerelease, never latest
#   TAG, TITLE, DIST, NOTES, GH_TOKEN, GITHUB_SHA, GITHUB_REPOSITORY
set -euo pipefail

fail() {
  printf 'error: %s\n' "$1"
  exit 1
}

# A draft left by a failed attempt can be replaced; a published release can't.
if is_draft="$(gh release view "$TAG" --repo "$GITHUB_REPOSITORY" --json isDraft --jq .isDraft 2> /dev/null)"; then
  [[ "$is_draft" == true ]] || fail "release $TAG is already published"
  printf 'Deleting the draft left by an earlier attempt\n'
  gh release delete "$TAG" --repo "$GITHUB_REPOSITORY" --yes
fi

args=(--repo "$GITHUB_REPOSITORY" --draft --title "$TITLE" --notes-file "$NOTES")
case "$TRACK" in
  stable) args+=(--verify-tag) ;;
  head) args+=(--target "$GITHUB_SHA" --prerelease --latest=false) ;;
  *) fail "unknown TRACK: $TRACK" ;;
esac

gh release create "$TAG" "${args[@]}" "$DIST"/*

publish=(--repo "$GITHUB_REPOSITORY" --draft=false)
if [[ "$TRACK" == head ]]; then
  publish+=(--latest=false)
fi
gh release edit "$TAG" "${publish[@]}"

url="$(gh release view "$TAG" --repo "$GITHUB_REPOSITORY" --json url --jq .url)"
printf 'Published %s\n' "$url"
printf 'Published [%s](%s)\n' "$TAG" "$url" >> "$GITHUB_STEP_SUMMARY"

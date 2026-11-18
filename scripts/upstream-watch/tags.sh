#!/usr/bin/env bash
# The stable-tag watch, sourced by watch.sh: one issue per edk2-stable tag
# newer than the pin (PIN_TAG), with the steps to move to it.
# shellcheck disable=SC2016 # Backticks in issue text are Markdown.

readonly STABLE_TAG='^edk2-stable([0-9]{6})(\.([0-9]{2}))?$'

# tag_order TAG: YYYYMMNN, where no suffix is 00, for numeric comparison.
tag_order() {
  [[ "$1" =~ $STABLE_TAG ]] || fail "not a stable tag: $1"
  printf '%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]:-00}"
}

# tag_commit REF_JSON: the commit a matching-refs entry points to, peeling an
# annotated tag.
tag_commit() {
  local type sha
  type="$(jq -r .object.type <<< "$1")"
  sha="$(jq -r .object.sha <<< "$1")"
  if [[ "$type" == tag ]]; then
    local peeled
    peeled="$(api "repos/${UPSTREAM}/git/tags/${sha}")"
    type="$(jq -r .object.type <<< "$peeled")"
    sha="$(jq -r .object.sha <<< "$peeled")"
  fi
  [[ "$type" == commit && "$sha" =~ ^[0-9a-f]{40}$ ]] || fail "can't resolve the commit of $(jq -r .ref <<< "$1")"
  printf '%s\n' "$sha"
}

# The NixOS release that may move with this edk2 tag: nixos-YY.MM for May and
# November tags, the months NixOS releases in.
nixpkgs_item() {
  local tag="$1" month year branch found
  [[ "$tag" =~ $STABLE_TAG ]]
  year="${BASH_REMATCH[1]:2:2}"
  month="${BASH_REMATCH[1]:4:2}"
  if [[ -n "${BASH_REMATCH[3]}" || ("$month" != 05 && "$month" != 11) ]]; then
    printf 'nixpkgs: no NixOS release matches this tag, so keep the nixpkgs pin.'
    return
  fi
  branch="nixos-${year}.${month}"
  found="$(api "repos/NixOS/nixpkgs/git/matching-refs/heads/${branch}" |
    jq --arg ref "refs/heads/${branch}" 'any(.[]; .ref == $ref)')"
  if [[ "$found" == true ]]; then
    printf 'nixpkgs: `%s` exists. Move `nixpkgs.url` to it in the same PR (see the comment in `flake.nix`), or note why not.' "$branch"
  else
    printf 'nixpkgs: `%s` doesn'\''t exist yet. Decide whether to wait for it (see the comment in `flake.nix`).' "$branch"
  fi
}

release_body() {
  local tag="$1" commit="$2" nixpkgs
  # Assigned first: a failure inside $(…) in the heredoc would be ignored.
  nixpkgs="$(nixpkgs_item "$tag")"
  cat << EOF
tianocore/edk2 has tagged [\`${tag}\`](https://github.com/${UPSTREAM}/tree/${tag}) at commit \`${commit}\`. This repository pins \`${PIN_TAG}\` (\`${PIN_COMMIT}\`).

- [ ] In \`flake.nix\`, set the \`edk2\` input to \`ref=refs/tags/${tag}\`, then run \`nix flake lock\`.
- [ ] ${nixpkgs}
- [ ] Merge once CI is green, then push \`ovmf-${tag}-r1\` on that \`main\` commit (README, "Making a stable release").
- [ ] After the release, pin it in \`.github/actions/measure-snp/firmware.json\`, and update the FabAI vector in \`nix/measure-snp/regression.sh\`, which fails until then.
- [ ] Nothing to do for the SEV-commits issue of \`${PIN_TAG}\`: the watcher closes it once \`flake.lock\` moves.

$(marker "kind=release" "tag=${tag}")
EOF
}

watch_tags() {
  local refs raised pin_order ref tag commit body
  refs="$(api_all "repos/${UPSTREAM}/git/matching-refs/tags/edk2-stable?per_page=100")"
  raised="$(issues_of release | jq -c '[.[].tag]')"
  pin_order="$(tag_order "$PIN_TAG")"
  local count=0
  while IFS= read -r ref; do
    tag="$(jq -r '.ref | ltrimstr("refs/tags/")' <<< "$ref")"
    [[ "$tag" =~ $STABLE_TAG ]] || continue
    (($(tag_order "$tag") > pin_order)) || continue
    count=$((count + 1))
    if jq -e --arg tag "$tag" 'index($tag)' <<< "$raised" > /dev/null; then
      printf 'edk2 %s: already raised\n' "$tag"
      continue
    fi
    commit="$(tag_commit "$ref")"
    body="$(release_body "$tag" "$commit")"
    open_issue edk2-release "edk2 ${tag} released: move the firmware pin" "$body"
  done < <(jq -c '.[]' <<< "$refs")
  printf 'edk2 stable tags newer than %s: %d\n' "$PIN_TAG" "$count"
}

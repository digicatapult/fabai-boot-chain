#!/usr/bin/env bash
# Fixtures, runs and checks for nix/upstream-watch/test.sh, which sources this.
# Each case is a directory holding a flake.lock and the fake gh's state
# (fake-gh.sh). setup starts a quiet upstream: pinned to edk2-stable202608,
# no newer tag, no advisory, no SEV commit and no FabAI release.

readonly REPO_NAME=digicatapult/fabai-boot-chain
readonly PIN_208=2970e5699ba6267f3384ffab20f96647578aebc8
# shellcheck disable=SC2034 # Used by test.sh.
readonly PIN_211=46548b1adac8000000000000000000000000beef
readonly SEV_PATH_LIST=(OvmfPkg/AmdSev OvmfPkg/Library/BaseMemEncryptSevLib OvmfPkg/Library/CcExitLib)
# Who the fake gh writes as (GITHUB_TOKEN), and anyone else with an account.
# shellcheck disable=SC2034 # Used by the tests.
readonly WATCHER_USER='{"login": "github-actions[bot]", "type": "Bot"}'
readonly OUTSIDER_USER='{"login": "mallory", "type": "User"}'
CHECKS=0
FAILURES=0

# sha TEXT: a deterministic fake commit SHA.
sha() {
  printf '%s' "$1" | sha1sum | cut -d ' ' -f 1
}

# api_set ENDPOINT JSON
api_set() {
  jq --arg endpoint "$1" --argjson value "$2" '.[$endpoint] = $value' "$STATE/api.json" > "$STATE/api.new"
  mv "$STATE/api.new" "$STATE/api.json"
}

# api_add ENDPOINT JSON: appends to a list response.
api_add() {
  jq --arg endpoint "$1" --argjson value "$2" '.[$endpoint] += [$value]' "$STATE/api.json" > "$STATE/api.new"
  mv "$STATE/api.new" "$STATE/api.json"
}

# pin TAG COMMIT DATE: writes flake.lock, and the pinned commit's date.
pin() {
  jq -n --arg ref "refs/tags/$1" --arg rev "$2" \
    '{nodes: {edk2: {original: {ref: $ref}, locked: {ref: $ref, rev: $rev}}}}' > "$CASE/flake.lock"
  api_set "repos/tianocore/edk2/commits/$2" "$(jq -n --arg date "$3" '{commit: {committer: {date: $date}}}')"
  local since path ref
  since="$(date -u -d "$3 - 30 days" +%Y-%m-%dT%H:%M:%SZ)"
  for path in "${SEV_PATH_LIST[@]}"; do
    for ref in master "$2"; do
      api_set "repos/tianocore/edk2/commits?sha=${ref}&path=${path}&since=${since}&per_page=100" '[]'
    done
  done
  SINCE="$since"
  PIN="$2"
}

setup() {
  CASE="$WORK/$((CHECKS + 1))-$RANDOM"
  STATE="$CASE/state"
  mkdir -p "$STATE"
  printf '[]\n' > "$STATE/issues.json"
  printf '[]\n' > "$STATE/labels.json"
  printf '{}\n' > "$STATE/comments.json"
  printf '{}\n' > "$STATE/api.json"
  : > "$STATE/calls.log"
  api_set 'repos/tianocore/edk2/git/matching-refs/tags/edk2-stable?per_page=100' "$(jq -n --arg pin "$PIN_208" '[
    {ref: "refs/tags/edk2-stable202605", object: {type: "commit", sha: "b03a21a63e3b0000000000000000000000000000"}},
    {ref: "refs/tags/edk2-stable202608", object: {type: "commit", sha: $pin}}]')"
  api_set 'repos/tianocore/edk2/security-advisories?state=published&per_page=100' '[]'
  api_set "repos/${REPO_NAME}/releases?per_page=100" '[]'
  pin edk2-stable202608 "$PIN_208" 2026-08-21T00:00:00Z
}

# add_tag TAG COMMIT [annotated]
add_tag() {
  local ref
  if [[ "${3:-}" == annotated ]]; then
    local object
    object="$(sha "tag object $1")"
    api_set "repos/tianocore/edk2/git/tags/${object}" "$(jq -n --arg sha "$2" '{object: {type: "commit", sha: $sha}}')"
    ref="$(jq -n --arg ref "refs/tags/$1" --arg sha "$object" '{ref: $ref, object: {type: "tag", sha: $sha}}')"
  else
    ref="$(jq -n --arg ref "refs/tags/$1" --arg sha "$2" '{ref: $ref, object: {type: "commit", sha: $sha}}')"
  fi
  api_add 'repos/tianocore/edk2/git/matching-refs/tags/edk2-stable?per_page=100' "$ref"
}

# nixos_branch NAME: makes NixOS/nixpkgs have branch NAME (and NAME-small).
nixos_branch() {
  api_set "repos/NixOS/nixpkgs/git/matching-refs/heads/$1" \
    "$(jq -n --arg ref "refs/heads/$1" '[{ref: $ref}, {ref: "\($ref)-small"}]')"
}

# advisory GHSA PUBLISHED UPDATED PACKAGE PATCHED [SUMMARY]: one advisory.
advisory() {
  jq -n --arg ghsa "$1" --arg published "$2" --arg updated "$3" --arg package "$4" --arg patched "$5" \
    --arg summary "${6:-Test advisory $1}" '{
      ghsa_id: $ghsa, cve_id: "CVE-2026-0001", severity: "high", summary: $summary,
      html_url: "https://github.com/tianocore/edk2/security/advisories/\($ghsa)",
      published_at: $published, updated_at: $updated,
      vulnerabilities: [{package: {ecosystem: "other", name: $package},
        vulnerable_version_range: "<= 202608", patched_versions: $patched}]}'
}

add_advisory() {
  api_add 'repos/tianocore/edk2/security-advisories?state=published&per_page=100' "$1"
}

set_advisories() {
  api_set 'repos/tianocore/edk2/security-advisories?state=published&per_page=100' "$1"
}

# add_sev SHA PATH DATE TITLE ahead|behind: a commit on master touching PATH,
# which the pin lacks (ahead) or contains (behind: in the pin's history too).
add_sev() {
  local commit
  commit="$(jq -n --arg sha "$1" --arg date "$3" --arg title "$4" \
    '{sha: $sha, html_url: "https://github.com/tianocore/edk2/commit/\($sha)",
      commit: {committer: {date: $date}, message: "\($title)\n\nSigned-off-by: Someone"}}')"
  api_add "repos/tianocore/edk2/commits?sha=master&path=$2&since=${SINCE}&per_page=100" "$commit"
  if [[ "$5" == behind ]]; then
    api_add "repos/tianocore/edk2/commits?sha=${PIN}&path=$2&since=${SINCE}&per_page=100" "$commit"
  fi
  api_set "repos/tianocore/edk2/commits/$1" \
    "$(jq -n --arg file "$2/File.c" '{files: [{filename: $file}, {filename: "MdePkg/Other.c"}]}')"
}

# add_release TAG SOURCES_LINES: a stable FabAI release with this SOURCES.txt.
add_release() {
  printf '%s\n' "$2" > "$CASE/SOURCES.txt"
  api_add "repos/${REPO_NAME}/releases?per_page=100" "$(jq -n --arg tag "$1" \
    '{tag_name: $tag, draft: false, prerelease: false, published_at: "2026-11-20T00:00:00Z",
      assets: [{name: "OVMF.fd", id: 6}, {name: "SOURCES.txt", id: 7}]}')"
  api_set "repos/${REPO_NAME}/releases/assets/7" "$(jq -n --arg file "$CASE/SOURCES.txt" '{"$file": $file}')"
}

# watch [DRY_RUN]: one run in the case directory; 0 if it succeeded.
watch() {
  : > "$STATE/calls.log"
  (cd "$CASE" && env GITHUB_REPOSITORY="$REPO_NAME" GH_TOKEN=test-token DRY_RUN="${1:-false}" \
    FAKE_STATE="$STATE" FAKE_FAIL="${FAKE_FAIL:-}" bash "$SCRIPTS/watch.sh") >> "$CASE/log" 2>&1
}

# issues KIND [STATE]: how many issues of KIND exist (in STATE, if given).
issues() {
  jq --arg kind "kind=$1" --arg state "${2:-}" \
    '[.[] | select((.body | contains($kind)) and ($state == "" or .state == $state))] | length' "$STATE/issues.json"
}

# body KIND: the body of the newest issue of KIND.
body() {
  jq -r --arg kind "kind=$1" '[.[] | select(.body | contains($kind))] | last | .body' "$STATE/issues.json"
}

# comments NUMBER: the comments on issue NUMBER, joined.
comments() {
  jq -r --arg number "$1" '.[$number] // [] | map(.body) | join("\n---\n")' "$STATE/comments.json"
}

comment_count() {
  jq -r --arg number "$1" '.[$number] // [] | length' "$STATE/comments.json"
}

# outsider_comment NUMBER BODY: someone other than the watcher comments.
outsider_comment() {
  jq --arg number "$1" --arg body "$2" --argjson user "$OUTSIDER_USER" \
    '.[$number] += [{body: $body, user: $user}]' "$STATE/comments.json" > "$STATE/comments.new"
  mv "$STATE/comments.new" "$STATE/comments.json"
}

# edit_issue NUMBER JQ_UPDATE: a person changes issue NUMBER, such as closing
# or relabelling it.
edit_issue() {
  jq --argjson number "$1" "map(if .number == \$number then $2 else . end)" "$STATE/issues.json" > "$STATE/issues.new"
  mv "$STATE/issues.new" "$STATE/issues.json"
}

# issue_json NUMBER: issue NUMBER as stored, with its label names as .names.
issue_json() {
  jq -c --argjson number "$1" '.[] | select(.number == $number) | . + {names: [.labels[].name]}' "$STATE/issues.json"
}

# writes: POST and PATCH calls in the last run.
writes() {
  grep -cE '^(POST|PATCH) ' "$STATE/calls.log" || true
}

# check NAME COMMAND…: a test passes if COMMAND succeeds.
check() {
  local name="$1"
  shift
  CHECKS=$((CHECKS + 1))
  if "$@"; then
    printf 'ok   %s\n' "$name"
  else
    printf 'FAIL %s\n' "$name"
    if [[ -f "${CASE:-}/log" ]]; then
      sed 's/^/     | /' "$CASE/log" | tail -n 40
    fi
    FAILURES=$((FAILURES + 1))
  fi
}

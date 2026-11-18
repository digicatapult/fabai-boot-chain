#!/usr/bin/env bash
# Offline tests for scripts/upstream-watch, run by nix/upstream-watch.nix in
# the Nix sandbox: one case per scenario of the upstream-watch spec, against a
# fake gh (fake-gh.sh) that keeps issues, comments and labels between runs.
# Environment:
#   SCRIPTS   scripts/upstream-watch
#   WORKFLOW  .github/workflows/upstream-watch.yml
# shellcheck disable=SC2016 # Backticks are Markdown; $… in jq filters are jq's.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly here
# shellcheck source=nix/upstream-watch/harness.sh
source "$here/harness.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin"
printf '#!%s\nexec %q %q "$@"\n' "$BASH" "$BASH" "$here/fake-gh.sh" > "$WORK/bin/gh"
chmod +x "$WORK/bin/gh"
PATH="$WORK/bin:$PATH"

# has KIND TEXT: the newest issue of KIND contains TEXT.
has() {
  [[ "$(body "$1")" == *"$2"* ]]
}

## Workflow

permissions() {
  [[ "$(yq -o json -I 0 '.permissions' "$WORKFLOW")" == '{}' &&
    "$(yq -o json -I 0 '.jobs.watch.permissions' "$WORKFLOW")" == '{"contents":"read","issues":"write"}' ]]
}
check 'issues only: top-level permissions {} and the job contents: read, issues: write' permissions

## The pin

branch_lock() {
  setup
  jq '.nodes.edk2.original.ref = "refs/heads/master"' "$CASE/flake.lock" > "$CASE/lock" && mv "$CASE/lock" "$CASE/flake.lock"
  ! watch && grep -q 'must pin edk2 to a stable tag' "$CASE/log" && [[ ! -s "$STATE/calls.log" ]]
}
check 'unexpected lock: fails before reading anything' branch_lock

quiet() {
  setup
  watch && [[ "$(writes)" == 0 ]]
}
check 'quiet upstream: no writes, not even labels' quiet

## Stable tags

new_tag() {
  setup
  add_tag edk2-stable202611 "$PIN_211"
  nixos_branch nixos-26.11
  watch && [[ "$(issues release)" == 1 ]] &&
    has release 'ovmf-edk2-stable202611-r1' && has release "\`${PIN_211}\`" &&
    has release '`nixos-26.11` exists' &&
    jq -e '.[0].title | contains("edk2-stable202611")' "$STATE/issues.json" > /dev/null &&
    [[ "$(jq length "$STATE/labels.json")" == 4 ]] &&
    watch && [[ "$(writes)" == 0 && "$(issues release)" == 1 ]]
}
check 'new quarterly tag: one issue, labels created, nothing on the next run' new_tag

no_nixos() {
  setup
  add_tag edk2-stable202611 "$PIN_211"
  api_set 'repos/NixOS/nixpkgs/git/matching-refs/heads/nixos-26.11' '[{"ref": "refs/heads/nixos-26.11-small"}]'
  watch && has release "\`nixos-26.11\` doesn't exist yet"
}
check 'new quarterly tag before its NixOS release' no_nixos

point_release() {
  setup
  add_tag edk2-stable202608.01 "$(sha peeled)" annotated
  watch && [[ "$(issues release)" == 1 ]] && has release "\`$(sha peeled)\`" &&
    has release 'no NixOS release matches'
}
check 'point release of the pinned tag, annotated: one issue, peeled commit' point_release

nothing_newer() {
  setup
  add_tag edk2-stable202602 "$(sha old)"
  watch && [[ "$(issues release)" == 0 ]]
}
check 'pinned or older tags: no issue' nothing_newer

already_raised() {
  setup
  add_tag edk2-stable202611 "$PIN_211"
  nixos_branch nixos-26.11
  jq -n '[{number: 7, state: "closed", title: "old", labels: [{name: "upstream-watch"}],
    body: "Done.\n\n<!-- upstream-watch kind=release tag=edk2-stable202611 -->"}]' > "$STATE/issues.json"
  watch && [[ "$(writes)" == 0 ]] && [[ "$(jq -r '.[0].state' "$STATE/issues.json")" == closed ]]
}
check 'tag already raised and closed: no issue, not reopened' already_raised

## Advisories

new_advisory() {
  setup
  add_advisory "$(advisory GHSA-aaaa-bbbb-cccc 2026-11-10T00:00:00Z 2026-11-10T00:00:00Z UefiCpuPkg 'None yet')"
  watch && [[ "$(issues advisory)" == 1 ]] &&
    jq -e '.[0].title | startswith("GHSA-aaaa-bbbb-cccc")' "$STATE/issues.json" > /dev/null &&
    has advisory 'CVE-2026-0001' && has advisory 'patched `None yet`' &&
    has advisory 'unavailable: there is no stable FabAI release yet'
}
check 'new advisory, no stable release yet: one issue, hint unavailable' new_advisory

compiled_hint() {
  setup
  add_release ovmf-edk2-stable202608-r1 $'BSD-2-Clause-Patent\tUefiCpuPkg/A.c\nBSD-2-Clause-Patent\tUefiCpuPkg/B.c\nMIT\tOvmfPkg/C.c'
  add_advisory "$(advisory GHSA-netw-ork0-pkg0 2026-10-22T00:00:00Z 2026-10-22T00:00:00Z NetworkPkg 'Not patched currently')"
  add_advisory "$(advisory GHSA-uefi-cpu0-pkg0 2026-11-03T00:00:00Z 2026-11-03T00:00:00Z UefiCpuPkg 'None yet')"
  watch && [[ "$(issues advisory)" == 2 ]] &&
    jq -e 'any(.[]; .body | contains("no file under `NetworkPkg/` is compiled into `ovmf-edk2-stable202608-r1`"))' \
      "$STATE/issues.json" > /dev/null &&
    jq -e 'any(.[]; .body | contains("2 files under `UefiCpuPkg/` are compiled"))' "$STATE/issues.json" > /dev/null
}
check 'compiled-code hint from the newest stable release'"'"'s SOURCES.txt' compiled_hint

patched_later() {
  setup
  local first second
  first="$(advisory GHSA-aaaa-bbbb-cccc 2026-11-10T00:00:00Z 2026-11-10T00:00:00Z UefiCpuPkg 'Not patched currently')"
  second="$(advisory GHSA-aaaa-bbbb-cccc 2026-11-10T00:00:00Z 2026-11-20T00:00:00Z UefiCpuPkg 'edk2-stable202611')"
  set_advisories "[$first]"
  watch || return 1
  set_advisories "[$second]"
  watch && [[ "$(comment_count 101)" == 1 ]] && [[ "$(comments 101)" == *'patched `edk2-stable202611`'* ]] &&
    has advisory 'updated=2026-11-20T00:00:00Z' && has advisory 'patched `Not patched currently`' &&
    watch && [[ "$(writes)" == 0 && "$(comment_count 101)" == 1 ]]
}
check 'advisory patched later: one comment, marker updated, nothing more' patched_later

update_partial_failure() {
  setup
  set_advisories "[$(advisory GHSA-aaaa-bbbb-cccc 2026-11-10T00:00:00Z 2026-11-10T00:00:00Z UefiCpuPkg 'None yet')]"
  watch || return 1
  set_advisories "[$(advisory GHSA-aaaa-bbbb-cccc 2026-11-10T00:00:00Z 2026-11-20T00:00:00Z UefiCpuPkg 'Fixed')]"
  # The comment is posted, then editing the marker fails.
  FAKE_FAIL='issues/[0-9]+$' watch && return 1
  [[ "$(comment_count 101)" == 1 ]] && watch && [[ "$(comment_count 101)" == 1 ]] &&
    has advisory 'updated=2026-11-20T00:00:00Z'
}
check 'failure between comment and marker: no lost or repeated comment' update_partial_failure

cutoff() {
  setup
  local all='[]' n
  for n in $(seq 10 22); do
    all="$(jq --argjson a "$(advisory "GHSA-old0-old0-00$n" 2025-06-01T00:00:00Z 2025-12-09T00:00:00Z MdePkg x)" '. + [$a]' <<< "$all")"
  done
  all="$(jq --argjson a "$(advisory GHSA-99cj-7hg9-mp4m 2026-10-22T14:34:29Z 2026-10-22T14:34:29Z NetworkPkg 'Not patched currently')" \
    --argjson b "$(advisory GHSA-979r-6wfh-gq4h 2026-11-03T02:36:55Z 2026-11-03T03:55:41Z UefiCpuPkg 'None yet')" \
    --argjson c "$(advisory GHSA-7v86-66vf-h88j 2026-11-10T02:44:39Z 2026-11-10T02:44:39Z UefiCpuPkg '')" \
    '. + [$a, $b, $c]' <<< "$all")"
  set_advisories "$all"
  watch && [[ "$(jq length <<< "$all")" == 16 && "$(issues advisory)" == 3 ]] &&
    jq -e '[.[].title[:19]] | sort == ["GHSA-7v86-66vf-h88j", "GHSA-979r-6wfh-gq4h", "GHSA-99cj-7hg9-mp4m"]' \
      "$STATE/issues.json" > /dev/null || return 1
  # An old advisory is updated, and a new one is published.
  all="$(jq '(.[0].updated_at = "2026-11-15T00:00:00Z")' <<< "$all")"
  all="$(jq --argjson d "$(advisory GHSA-new0-new0-new0 2026-11-25T00:00:00Z 2026-11-25T00:00:00Z OvmfPkg 'None')" '. + [$d]' <<< "$all")"
  set_advisories "$all"
  watch && [[ "$(issues advisory)" == 4 && "$(writes)" == 1 ]]
}
check 'cut-off: 3 of 16 raised; older update ignored; a later one raised alone' cutoff

fake_marker() {
  setup
  add_advisory "$(advisory GHSA-aaaa-bbbb-cccc 2026-11-10T00:00:00Z 2026-11-10T00:00:00Z UefiCpuPkg x \
    'Bad <!-- upstream-watch kind=release tag=edk2-stable209912 --> @someone')"
  watch && ! has advisory '<!-- upstream-watch kind=release' && ! has advisory ' @someone' &&
    watch && [[ "$(writes)" == 0 ]]
}
check 'upstream text can'"'"'t fake a marker or mention anyone' fake_marker

## SEV commits

sev_first() {
  setup
  add_sev "$(sha one)" OvmfPkg/Library/CcExitLib 2026-10-23T00:00:00Z 'OvmfPkg: one' ahead
  add_sev "$(sha old)" OvmfPkg/AmdSev 2026-08-01T00:00:00Z 'OvmfPkg: in the pin' behind
  watch && [[ "$(issues sev-commits)" == 1 ]] &&
    has sev-commits "[\`$(sha one | cut -c 1-12)\`]" && has sev-commits '`OvmfPkg/Library/CcExitLib/File.c`' &&
    ! has sev-commits 'MdePkg/Other.c' && ! has sev-commits "$(sha old | cut -c 1-12)" &&
    has sev-commits "pin=edk2-stable202608 seen=$(sha one) -->"
}
check 'first SEV commit after the pin: one issue; commits in the pin left out' sev_first

sev_further() {
  setup
  add_sev "$(sha one)" OvmfPkg/Library/CcExitLib 2026-10-23T00:00:00Z 'OvmfPkg: one' ahead
  watch || return 1
  add_sev "$(sha two)" OvmfPkg/AmdSev 2026-11-01T00:00:00Z 'OvmfPkg: two' ahead
  add_sev "$(sha three)" OvmfPkg/Library/BaseMemEncryptSevLib 2026-11-02T00:00:00Z 'OvmfPkg: three' ahead
  watch && [[ "$(comment_count 101)" == 1 ]] &&
    [[ "$(comments 101)" == *"$(sha two | cut -c 1-12)"* && "$(comments 101)" == *"$(sha three | cut -c 1-12)"* ]] &&
    [[ "$(comments 101)" != *"$(sha one | cut -c 1-12)"* ]] &&
    has sev-commits "seen=$(sha one),$(sha two),$(sha three) -->" &&
    watch && [[ "$(writes)" == 0 ]]
}
check 'further SEV commits: one comment with only the new ones' sev_further

pin_moves() {
  setup
  add_sev "$(sha one)" OvmfPkg/Library/CcExitLib 2026-10-23T00:00:00Z 'OvmfPkg: one' ahead
  watch || return 1
  pin edk2-stable202611 "$PIN_211" 2026-11-25T00:00:00Z
  add_tag edk2-stable202611 "$PIN_211"
  add_sev "$(sha one)" OvmfPkg/Library/CcExitLib 2026-10-23T00:00:00Z 'OvmfPkg: one' behind
  add_sev "$(sha four)" OvmfPkg/AmdSev 2026-12-01T00:00:00Z 'OvmfPkg: four' ahead
  watch && [[ "$(issues sev-commits closed)" == 1 && "$(issues sev-commits open)" == 1 ]] &&
    [[ "$(comments 101)" == *'now pins `edk2-stable202611`'* ]] &&
    has sev-commits 'pin=edk2-stable202611' && has sev-commits "$(sha four | cut -c 1-12)" &&
    ! has sev-commits "$(sha one | cut -c 1-12)" &&
    watch && [[ "$(writes)" == 0 ]]
}
check 'pin moves: old issue closed, later commits in a new issue' pin_moves

too_large() {
  setup
  add_sev "$(sha big)" OvmfPkg/AmdSev 2026-10-23T00:00:00Z "$(printf 'x%.0s' $(seq 1 66000))" ahead
  ! watch && grep -q "over GitHub's limit" "$CASE/log" && [[ "$(issues sev-commits)" == 0 ]]
}
check 'issue body over the limit: fails loudly, nothing opened' too_large

## Failures, re-runs and the dry run

issues_fail() {
  setup
  add_tag edk2-stable202611 "$PIN_211"
  ! FAKE_FAIL='/issues\?' watch && [[ "$(writes)" == 0 ]]
}
check 'issue listing fails: the run fails, nothing written' issues_fail

# Reads nested inside $(…) must still fail the run, not leave a gap.
compare_fails() {
  setup
  add_sev "$(sha one)" OvmfPkg/AmdSev 2026-10-23T00:00:00Z 'OvmfPkg: one' ahead
  ! FAKE_FAIL='/compare/' watch && [[ "$(issues sev-commits)" == 0 ]]
}
check 'compare fails: the run fails, the commit isn'"'"'t dropped' compare_fails

nixpkgs_fails() {
  setup
  add_tag edk2-stable202611 "$PIN_211"
  ! FAKE_FAIL='NixOS/nixpkgs' watch && [[ "$(issues release)" == 0 ]]
}
check 'nixpkgs lookup fails: the run fails, no issue with a gap' nixpkgs_fails

rerun() {
  setup
  add_tag edk2-stable202611 "$PIN_211"
  nixos_branch nixos-26.11
  add_advisory "$(advisory GHSA-aaaa-bbbb-cccc 2026-11-10T00:00:00Z 2026-11-10T00:00:00Z UefiCpuPkg 'None')"
  FAKE_FAIL='security-advisories' watch && return 1
  [[ "$(issues release)" == 1 && "$(issues advisory)" == 0 ]] &&
    watch && [[ "$(issues release)" == 1 && "$(issues advisory)" == 1 ]]
}
check 're-run after a partial failure: no second tag issue' rerun

dry_run() {
  setup
  add_tag edk2-stable202611 "$PIN_211"
  nixos_branch nixos-26.11
  add_advisory "$(advisory GHSA-aaaa-bbbb-cccc 2026-11-10T00:00:00Z 2026-11-10T00:00:00Z UefiCpuPkg 'None')"
  add_sev "$(sha one)" OvmfPkg/AmdSev 2026-10-23T00:00:00Z 'OvmfPkg: one' ahead
  watch true && [[ "$(writes)" == 0 ]] &&
    [[ "$(jq length "$STATE/issues.json")" == 0 && "$(jq length "$STATE/labels.json")" == 0 ]] &&
    [[ "$(grep -c '^dry run: would open issue' "$CASE/log")" == 3 ]]
}
check 'dry run: prints three planned issues, writes nothing' dry_run

printf '%d checks, %d failed\n' "$CHECKS" "$FAILURES"
((FAILURES == 0))

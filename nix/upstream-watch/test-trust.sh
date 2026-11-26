#!/usr/bin/env bash
# Cases for what the watcher trusts and how it reopens issues, sourced by
# nix/upstream-watch/test.sh after its own cases. Issues on this repository
# are public: anyone can comment, open an issue, or relabel one while triaging.
# shellcheck disable=SC2016 # Backticks are Markdown; $… in jq filters are jq's.

## Only the watcher's own issues and comments count

outsider_advisory_key() {
  setup
  set_advisories "[$(advisory GHSA-aaaa-bbbb-cccc 2026-11-10T00:00:00Z 2026-11-10T00:00:00Z UefiCpuPkg 'None yet')]"
  watch || return 1
  # The key is predictable from the public advisory's updated_at.
  outsider_comment 101 '<!-- upstream-watch comment=advisory-updated-2026-11-20T00:00:00Z -->'
  set_advisories "[$(advisory GHSA-aaaa-bbbb-cccc 2026-11-10T00:00:00Z 2026-11-20T00:00:00Z UefiCpuPkg 'Fixed')]"
  watch && [[ "$(comment_count 101)" == 2 && "$(comments 101)" == *'patched `Fixed`'* ]] &&
    has advisory 'updated=2026-11-20T00:00:00Z'
}
check 'outsider posts the next advisory comment key: the update is still reported' outsider_advisory_key

outsider_sev_key() {
  setup
  add_sev "$(sha one)" OvmfPkg/AmdSev 2026-10-23T00:00:00Z 'OvmfPkg: one' ahead
  watch || return 1
  add_sev "$(sha two)" OvmfPkg/AmdSev 2026-11-01T00:00:00Z 'OvmfPkg: two' ahead
  # The key is a hash of public commit SHAs.
  outsider_comment 101 "<!-- upstream-watch comment=sev-commits-$(printf '%s' "$(sha two)" | sha256sum | cut -c 1-12) -->"
  watch && [[ "$(comment_count 101)" == 2 && "$(comments 101)" == *"$(sha two | cut -c 1-12)"* ]] &&
    has sev-commits "seen=$(sha one),$(sha two) -->"
}
check 'outsider posts the next SEV comment key: the commits are still reported' outsider_sev_key

forged_issue() {
  setup
  add_tag edk2-stable202611 "$PIN_211"
  nixos_branch nixos-26.11
  jq -n --argjson user "$OUTSIDER_USER" '[{number: 7, state: "open", title: "fake", user: $user,
    labels: [{name: "upstream-watch"}], body: "<!-- upstream-watch kind=release tag=edk2-stable202611 -->"}]' \
    > "$STATE/issues.json"
  watch && [[ "$(issues release)" == 2 ]] &&
    jq -e '.user.login == "github-actions[bot]"' <<< "$(issue_json 8)" > /dev/null
}
check 'outsider opens an issue with a forged marker: ignored, the tag is still raised' forged_issue

relabelled() {
  setup
  add_tag edk2-stable202611 "$PIN_211"
  nixos_branch nixos-26.11
  watch || return 1
  edit_issue 101 '.state = "closed" | .labels = [{name: "triaged"}]'
  watch && [[ "$(writes)" == 0 && "$(issues release)" == 1 ]]
}
check 'issue closed with upstream-watch swapped for triaged: no duplicate' relabelled

## Updates reopen closed issues

reopen_advisory() {
  setup
  set_advisories "[$(advisory GHSA-aaaa-bbbb-cccc 2026-11-10T00:00:00Z 2026-11-10T00:00:00Z UefiCpuPkg 'None yet')]"
  watch || return 1
  edit_issue 101 '.state = "closed" | .state_reason = "completed" | .labels += [{name: "triaged"}]'
  set_advisories "[$(advisory GHSA-aaaa-bbbb-cccc 2026-11-10T00:00:00Z 2026-11-20T00:00:00Z UefiCpuPkg 'Fixed')]"
  # The comment is posted, then reopening fails; the next run only reopens.
  FAKE_FAIL='issues/[0-9]+$' watch && return 1
  [[ "$(comment_count 101)" == 1 ]] && watch || return 1
  jq -e '.state == "open" and .state_reason == "reopened" and .names == ["upstream-watch", "edk2-advisory"]' \
    <<< "$(issue_json 101)" > /dev/null &&
    [[ "$(comment_count 101)" == 1 && "$(comments 101)" == *'reopened it'* ]] &&
    has advisory 'updated=2026-11-20T00:00:00Z' &&
    watch && [[ "$(writes)" == 0 ]]
}
check 'triaged advisory updated: reopened without triaged, one comment, even after a failed edit' reopen_advisory

reopen_sev() {
  setup
  add_sev "$(sha one)" OvmfPkg/AmdSev 2026-10-23T00:00:00Z 'OvmfPkg: one' ahead
  watch || return 1
  add_sev "$(sha two)" OvmfPkg/AmdSev 2026-11-01T00:00:00Z 'OvmfPkg: two' ahead
  watch && [[ "$(comments 101)" != *'reopened'* ]] || return 1
  edit_issue 101 '.state = "closed" | .state_reason = "not_planned"'
  add_sev "$(sha three)" OvmfPkg/AmdSev 2026-11-02T00:00:00Z 'OvmfPkg: three' ahead
  watch && jq -e '.state == "open" and .names == ["upstream-watch", "edk2-sev-commits"]' \
    <<< "$(issue_json 101)" > /dev/null &&
    [[ "$(comment_count 101)" == 2 && "$(comments 101)" == *'reopened it'* ]] &&
    has sev-commits "seen=$(sha one),$(sha two),$(sha three) -->"
}
check 'SEV issue closed by hand, then new commits: reopened; no note while open' reopen_sev

#!/usr/bin/env bash
# The advisory watch, sourced by watch.sh: one issue per tianocore/edk2
# security advisory published on or after the cut-off, and one comment per
# later update to it.
# shellcheck disable=SC2016 # Backticks in issue text are Markdown.

# Older advisories are treated as handled by edk2's maintainers.
readonly ADVISORY_CUTOFF=2026-10-01T00:00:00Z

# Finds the newest stable release's SOURCES.txt, once per run. Sets
# SOURCES_RELEASE to its tag, or empty if there is no stable release yet.
load_sources() {
  [[ -z "${SOURCES_DONE:-}" ]] || return 0
  SOURCES_DONE=1
  SOURCES_RELEASE=''
  local releases release asset
  releases="$(api_all "repos/${REPO}/releases?per_page=100")"
  release="$(jq -c '[.[] | select((.draft | not) and (.prerelease | not)
      and (.tag_name | test("^ovmf-edk2-stable")))] | sort_by(.published_at) | last // empty' <<< "$releases")"
  [[ -n "$release" ]] || return 0
  asset="$(jq -r '.assets[] | select(.name == "SOURCES.txt") | .id' <<< "$release")"
  [[ "$asset" =~ ^[0-9]+$ ]] || fail "release $(jq -r .tag_name <<< "$release") has no SOURCES.txt"
  api "repos/${REPO}/releases/assets/${asset}" -H 'Accept: application/octet-stream' > "$WORK/SOURCES.txt"
  SOURCES_RELEASE="$(jq -r .tag_name <<< "$release")"
}

# compiled_hint PACKAGE: whether any file under PACKAGE/ is compiled into the
# newest stable release's images, from its SOURCES.txt (both variants).
compiled_hint() {
  local package="$1" count
  if [[ -z "$SOURCES_RELEASE" ]]; then
    printf 'unavailable: there is no stable FabAI release yet, so no `SOURCES.txt` to check.'
    return
  fi
  if [[ ! "$package" =~ ^[A-Za-z0-9_][A-Za-z0-9_./-]*$ ]]; then
    printf 'unavailable: the advisory names no edk2 package path.'
    return
  fi
  count="$(awk -F '\t' -v prefix="${package}/" 'index($2, prefix) == 1 { n++ } END { print n + 0 }' "$WORK/SOURCES.txt")"
  if ((count == 0)); then
    printf 'no file under `%s/` is compiled into `%s` (`SOURCES.txt`, both variants), so this advisory is unlikely to affect its images.' \
      "$package" "$SOURCES_RELEASE"
  else
    printf '%d files under `%s/` are compiled into `%s` (`SOURCES.txt`, both variants together). Check whether the vulnerable code is among them.' \
      "$count" "$package" "$SOURCES_RELEASE"
  fi
}

# packages ADVISORY_JSON: one line per affected package, for issue bodies.
packages() {
  local vulnerability package vulnerable patched hint
  while IFS= read -r vulnerability; do
    package="$(jq -r '.package.name // ""' <<< "$vulnerability")"
    vulnerable="$(sanitise "$(jq -r '.vulnerable_version_range // "not given"' <<< "$vulnerability")")"
    patched="$(sanitise "$(jq -r '.patched_versions // "not given"' <<< "$vulnerability")")"
    hint="$(compiled_hint "$package")"
    printf -- '- **`%s`**: vulnerable `%s`; patched `%s`.\n  Compiled code: %s\n' \
      "$(sanitise "${package:-not given}")" "$vulnerable" "$patched" "$hint"
  done < <(jq -c '.vulnerabilities // [] | .[]' <<< "$1")
}

advisory_body() {
  local advisory="$1" ghsa url cve severity summary published updated affected
  ghsa="$(jq -r .ghsa_id <<< "$advisory")"
  url="$(jq -r .html_url <<< "$advisory")"
  cve="$(sanitise "$(jq -r '.cve_id // "none"' <<< "$advisory")")"
  severity="$(sanitise "$(jq -r '.severity // "not given"' <<< "$advisory")")"
  summary="$(sanitise "$(jq -r '.summary // ""' <<< "$advisory")")"
  published="$(jq -r .published_at <<< "$advisory")"
  updated="$(jq -r .updated_at <<< "$advisory")"
  affected="$(packages "$advisory")"
  cat << EOF
tianocore/edk2 published security advisory [${ghsa}](${url}): ${summary}

- **CVE:** ${cve}
- **Severity:** ${severity}
- **Published:** ${published}, last updated ${updated}

Affected packages, as the advisory states them:

${affected:-- none given}

Triage, then close this issue with the verdict as a comment and label it \`triaged\`:

- [ ] Affects \`OVMF.fd\` (cc)
- [ ] Affects \`OVMF-noncc.fd\`
- [ ] Fixed in the pinned tag, \`${PIN_TAG}\`
- [ ] Action needed: a new release, or a patch

$(marker "kind=advisory" "ghsa=${ghsa}" "updated=${updated}")
EOF
}

update_body() {
  local advisory="$1" affected
  affected="$(packages "$advisory")"
  cat << EOF
The advisory was updated at $(jq -r .updated_at <<< "$advisory"). Affected packages now:

${affected:-- none given}
EOF
}

watch_advisories() {
  local advisories raised advisory ghsa published updated issue body title
  advisories="$(api_all "repos/${UPSTREAM}/security-advisories?state=published&per_page=100")"
  jq -e 'all(.[]; (.ghsa_id | test("^GHSA-[a-z0-9-]+$"))
      and (.published_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))
      and (.updated_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")))' <<< "$advisories" > /dev/null ||
    fail "unexpected shape in tianocore/edk2's security advisories"
  raised="$(issues_of advisory)"
  local count=0
  while IFS= read -r advisory; do
    count=$((count + 1))
    ghsa="$(jq -r .ghsa_id <<< "$advisory")"
    updated="$(jq -r .updated_at <<< "$advisory")"
    issue="$(jq -c --arg ghsa "$ghsa" '[.[] | select(.ghsa == $ghsa)] | first // empty' <<< "$raised")"
    if [[ -z "$issue" ]]; then
      load_sources
      body="$(advisory_body "$advisory")"
      title="$(jq -r '"\(.ghsa_id): \(.summary // "" | .[:200])"' <<< "$advisory")"
      title="$(sanitise "$title")"
      open_issue edk2-advisory "$title" "$body"
    elif [[ "$updated" > "$(jq -r '.updated // ""' <<< "$issue")" ]]; then
      local number
      number="$(jq -r .number <<< "$issue")"
      load_sources
      body="$(update_body "$advisory")"
      # Comment first, then the marker: a run that fails in between repeats
      # neither (comment_once).
      comment_once "$number" "advisory-updated-${updated}" "$body"
      set_marker "$number" "$(marker "kind=advisory" "ghsa=${ghsa}" "updated=${updated}")"
    else
      printf '%s: already raised, unchanged\n' "$ghsa"
    fi
  done < <(jq -c --arg cutoff "$ADVISORY_CUTOFF" '.[] | select(.published_at >= $cutoff)' <<< "$advisories")
  printf 'Advisories published since %s: %d\n' "$ADVISORY_CUTOFF" "$count"
}

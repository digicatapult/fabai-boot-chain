#!/usr/bin/env bash
# The SEV-commit watch, sourced by watch.sh: one issue per pinned tag listing
# the commits on edk2 master that touch the SEV paths and aren't in the pin,
# with a comment for each batch of new ones.
# shellcheck disable=SC2016 # Backticks in issue text are Markdown.

readonly SEV_PATHS=(
  OvmfPkg/AmdSev
  OvmfPkg/Library/BaseMemEncryptSevLib
  OvmfPkg/Library/CcExitLib
)

# Closes the SEV-commit issues of earlier pins, once flake.lock has moved.
close_moved_pins() {
  local number pin
  while IFS=$'\t' read -r number pin; do
    comment_once "$number" "pin-moved-${PIN_TAG}" \
      "\`flake.lock\` now pins \`${PIN_TAG}\`, so this list for \`${pin}\` is closed. Commits after \`${PIN_TAG}\` go into a new issue."
    close_issue "$number"
  done < <(issues_of sev-commits |
    jq -r --arg pin "$PIN_TAG" '.[] | select(.state == "open" and .pin != $pin) | "\(.number)\t\(.pin)"')
}

# touching REF SINCE: every commit in REF's history since SINCE touching a
# watched path, oldest first, as a JSON array of {sha, date, title, url}.
touching() {
  local path all='[]' page
  for path in "${SEV_PATHS[@]}"; do
    page="$(api_all "repos/${UPSTREAM}/commits?sha=${1}&path=${path}&since=${2}&per_page=100")"
    all="$(jq -c --argjson page "$page" '. + [$page[] | {sha, date: .commit.committer.date,
      title: (.commit.message | split("\n") | first), url: .html_url}]' <<< "$all")"
  done
  jq -c 'unique_by(.sha) | sort_by(.date)' <<< "$all"
}

# commit_line COMMIT_JSON: one Markdown list item, with the watched files the
# commit touches.
commit_line() {
  local sha files prefixes
  sha="$(jq -r .sha <<< "$1")"
  prefixes="$(printf '%s/\n' "${SEV_PATHS[@]}" | jq -R . | jq -sc .)"
  files="$(api "repos/${UPSTREAM}/commits/${sha}" |
    jq -r --argjson prefixes "$prefixes" '[.files[].filename | select(. as $f | any($prefixes[]; . as $p | $f | startswith($p)))]
      | map("`\(.)`") | join(", ")')"
  printf -- '- [`%s`](%s) %s %s\n  %s\n' "${sha:0:12}" "$(jq -r .url <<< "$1")" \
    "$(jq -r '.date[:10]' <<< "$1")" "$(sanitise "$(jq -r .title <<< "$1")")" "${files:-no watched file listed}"
}

sev_body() {
  local paths
  paths="$(printf '`%s/`, ' "${SEV_PATHS[@]}")"
  cat << EOF
Commits on tianocore/edk2 \`master\` that touch the SEV paths and aren't in the pinned \`${PIN_TAG}\` (\`${PIN_COMMIT}\`). SEV mitigations can land as ordinary commits with no advisory, so check whether any of these needs a release before the next stable tag.

Watched paths: ${paths%, }.

$1

New commits are added as comments, and reopen this issue if it has been closed. The watcher closes it when \`flake.lock\` moves to a newer tag.

$(marker "kind=sev-commits" "pin=${PIN_TAG}" "seen=$2")
EOF
}

watch_sev_commits() {
  close_moved_pins

  local pin_date since all contained issue seen='' candidate sha new=() lines='' line
  pin_date="$(api "repos/${UPSTREAM}/commits/${PIN_COMMIT}" | jq -r .commit.committer.date)"
  [[ "$pin_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]] || fail "can't read the date of $PIN_COMMIT"
  # A margin, because committer dates can predate when a commit landed. The
  # pin's own history, not the date, decides what the pin contains: listed
  # with the same filters, in a fixed number of calls however many commits
  # there are. One this listing missed would be reported, never dropped.
  since="$(date -u -d "$pin_date - 30 days" +%Y-%m-%dT%H:%M:%SZ)"
  all="$(touching master "$since")"
  contained="$(touching "$PIN_COMMIT" "$since" | jq -c 'map(.sha)')"
  all="$(jq -c --argjson contained "$contained" 'map(select(.sha | IN($contained[]) | not))' <<< "$all")"
  issue="$(issues_of sev-commits | jq -c --arg pin "$PIN_TAG" '[.[] | select(.pin == $pin)] | first // empty')"
  if [[ -n "$issue" ]]; then
    seen="$(jq -r '.seen // ""' <<< "$issue")"
  fi

  while IFS= read -r candidate; do
    sha="$(jq -r .sha <<< "$candidate")"
    [[ ",${seen}," != *",${sha},"* ]] || continue
    new+=("$sha")
    line="$(commit_line "$candidate")"
    lines+="${line}"$'\n'
  done < <(jq -c '.[]' <<< "$all")

  if ((${#new[@]} == 0)); then
    printf 'SEV commits after %s: nothing new\n' "$PIN_TAG"
    return
  fi
  local joined body
  joined="$(IFS=,; printf '%s' "${new[*]}")"
  if [[ -z "$issue" ]]; then
    body="$(sev_body "${lines%$'\n'}" "$joined")"
    open_issue edk2-sev-commits "SEV commits on edk2 master since ${PIN_TAG}" "$body"
    return
  fi
  local number key
  number="$(jq -r .number <<< "$issue")"
  key="sev-commits-$(printf '%s' "$joined" | sha256sum | cut -c 1-12)"
  body="New commits that touch the SEV paths (${#new[@]}):"$'\n\n'"${lines%$'\n'}"
  body+="$(reopen_note "$number")"
  comment_once "$number" "$key" "$body"
  set_marker "$number" "$(marker "kind=sev-commits" "pin=${PIN_TAG}" "seen=${seen:+${seen},}${joined}")"
}

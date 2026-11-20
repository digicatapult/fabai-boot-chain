#!/usr/bin/env bash
# Shared by the upstream watches; sourced by watch.sh, which sets:
#   REPO      this repository (owner/name), where issues are raised
#   DRY_RUN   true to print every write instead of making it
#   WORK      a scratch directory
#   ISSUES    $WORK/issues.json: every issue the watcher opened, with its
#             marker parsed (load_issues)
# Every GitHub read fails the run if it fails, so a failed or partial read
# never looks like "nothing new". Every write goes through `write`.
# Issues here are public, so anyone can post a marker: only issues and
# comments the watcher wrote itself count, never labels or others' text.

# shellcheck disable=SC2034 # Used by the watches watch.sh sources.
readonly UPSTREAM=tianocore/edk2
readonly MARKER_PREFIX='<!-- upstream-watch '
# Who GITHUB_TOKEN writes as.
readonly WATCHER_LOGIN='github-actions[bot]'
readonly WATCHER_TYPE=Bot
# Removed when the watcher reopens an issue, which then needs triage again.
readonly TRIAGED_LABEL=triaged
# GitHub rejects issue and comment bodies longer than this.
readonly MAX_BODY=65536

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

# api ENDPOINT [gh api flags…]: one GET.
api() {
  gh api "$@" || fail "GitHub API request failed: gh api $*"
}

# api_all ENDPOINT: every page of a list endpoint, as one JSON array.
api_all() {
  local pages
  pages="$(gh api --paginate "$1")" || fail "GitHub API request failed: gh api --paginate $1"
  jq -s 'add // [] | if type == "array" then . else error("not a list") end' <<< "$pages" ||
    fail "unexpected response from $1"
}

# Upstream text goes into issue bodies: stop it from mentioning people or
# opening an HTML comment.
sanitise() {
  jq -rn --arg text "$1" --arg quote "'" '$text | gsub("@"; "@\u2060") | gsub("<"; "&lt;") | gsub("`"; $quote)'
}

# marker KEY=VALUE…: the marker line ending a body the watcher writes.
marker() {
  printf '%s%s -->' "$MARKER_PREFIX" "$*"
}

# write METHOD ENDPOINT SUMMARY PAYLOAD: the only way anything is changed.
write() {
  local method="$1" endpoint="$2" summary="$3" payload="$4"
  local body_length
  jq -e 'type == "object" and length > 0' <<< "$payload" > /dev/null 2>&1 ||
    fail "$summary: the payload isn't a JSON object: \"$payload\""
  body_length="$(jq -r '.body // "" | length' <<< "$payload")"
  ((body_length <= MAX_BODY)) ||
    fail "$summary: body is $body_length characters, over GitHub's limit of $MAX_BODY"
  if [[ "$DRY_RUN" == true ]]; then
    printf 'dry run: would %s (%s %s)\n' "$summary" "$method" "$endpoint"
    jq -r 'if .body then .body else . end' <<< "$payload" | sed 's/^/  | /'
    return
  fi
  gh api --method "$method" "$endpoint" --input - <<< "$payload" > /dev/null ||
    fail "$summary failed ($method $endpoint)"
  printf '%s\n' "$summary"
}

# Every issue the watcher opened, open or closed, through the issues endpoint
# rather than search, whose index lags behind new issues. Found by author, not
# label, so relabelling one while triaging it can't cause a duplicate. Each
# gets its labels and the attributes of its body's last marker, so text
# quoted above the marker can't override it.
load_issues() {
  local creator
  creator="$(jq -rn --arg login "$WATCHER_LOGIN" '$login | @uri')"
  api_all "repos/${REPO}/issues?state=all&creator=${creator}&per_page=100" |
    jq --arg prefix "$MARKER_PREFIX" --arg login "$WATCHER_LOGIN" --arg type "$WATCHER_TYPE" '[
      .[] | select((.pull_request | not) and .user.login == $login and .user.type == $type)
      | (.body // "") as $body
      | ([$body | scan("\($prefix)([^>]*) -->")] | last) as $attrs
      | select($attrs)
      | {number, title, state, body: $body, labels: [.labels[].name]}
        + ($attrs[0] | split(" ") | map(select(contains("=")) | capture("^(?<key>[^=]+)=(?<value>.*)$"))
           | from_entries)
    ]' > "$ISSUES" || fail "can't parse the watcher's issues"
  printf 'Found %s issues opened by the watcher\n' "$(jq length "$ISSUES")"
}

# issues_of KIND: the parsed issues of one kind, as a JSON array.
issues_of() {
  jq --arg kind "$1" '[.[] | select(.kind == $kind)]' "$ISSUES"
}

# Creates any missing upstream-watch labels, once per run, before the first
# issue is opened.
ensure_labels() {
  [[ -z "${LABELS_DONE:-}" ]] || return 0
  LABELS_DONE=1
  local existing name colour description payload
  existing="$(api_all "repos/${REPO}/labels?per_page=100" | jq -c '[.[].name]')"
  while IFS=$'\t' read -r name colour description; do
    if ! jq -e --arg name "$name" 'index($name)' <<< "$existing" > /dev/null; then
      payload="$(jq -n --arg name "$name" --arg color "$colour" --arg description "$description" \
        '{name: $name, color: $color, description: $description}')"
      write POST "repos/${REPO}/labels" "create label $name" "$payload"
    fi
  done <<'EOF'
upstream-watch	5319e7	Raised by the upstream-watch workflow
edk2-release	0e8a16	A new edk2 stable tag to move the firmware pin to
edk2-advisory	d93f0b	A tianocore/edk2 security advisory to triage
edk2-sev-commits	fbca04	SEV commits on edk2 master that the pinned tag lacks
EOF
}

# Payloads are always assigned before `write`: as an argument, a failed $(…)
# would go unnoticed and send an empty payload.

# open_issue LABEL TITLE BODY: BODY must end with the marker.
open_issue() {
  local payload
  ensure_labels
  payload="$(jq -n --arg title "$2" --arg body "$3" --arg kind "$1" \
    '{title: $title, body: $body, labels: ["upstream-watch", $kind]}')"
  write POST "repos/${REPO}/issues" "open issue \"$2\"" "$payload"
}

# comment_once NUMBER KEY BODY: posts BODY unless a comment the watcher wrote
# on the issue already carries KEY, so a repeated run never posts it twice.
# Keys are predictable from public data, so anyone else's copy is ignored.
comment_once() {
  local number="$1" key="$2" body comments payload
  body="$3"$'\n\n'"$(marker "comment=$key")"
  # Read first: inside the `if`, a failed read would look like "not posted".
  comments="$(api_all "repos/${REPO}/issues/${number}/comments?per_page=100")"
  if jq -e --arg marker "$(marker "comment=$key")" --arg login "$WATCHER_LOGIN" --arg type "$WATCHER_TYPE" \
    'any(.[]; .user.login == $login and .user.type == $type and ((.body // "") | contains($marker)))' \
    <<< "$comments" > /dev/null; then
    printf 'issue #%s already has comment %s\n' "$number" "$key"
    return
  fi
  payload="$(jq -n --arg body "$body" '{body: $body}')"
  write POST "repos/${REPO}/issues/${number}/comments" "comment on issue #$number ($key)" "$payload"
}

# reopen_note NUMBER: for a closed issue, a paragraph for the update comment
# saying that set_marker reopens it; otherwise nothing.
reopen_note() {
  jq -r --argjson number "$1" --arg triaged "$TRIAGED_LABEL" '.[] | select(.number == $number and .state == "closed")
    | "\n\nThis issue was closed, so the watcher has reopened it and removed any `\($triaged)` label: triage it again."' \
    "$ISSUES"
}

# set_marker NUMBER NEW_MARKER: replaces the last marker in the issue's body.
# The issue is reporting something new, so if it's closed, the same edit
# reopens it and removes TRIAGED_LABEL, putting it back on the open list.
set_marker() {
  local number="$1" issue body payload summary
  issue="$(jq -c --argjson number "$number" '.[] | select(.number == $number)' "$ISSUES")"
  body="$(jq -r .body <<< "$issue")"
  body="$(jq -rn --arg body "$body" --arg new "$2" --arg prefix "$MARKER_PREFIX" '
    $body | [match("\($prefix)[^>]* -->"; "g")] | last as $m
    | $body[:$m.offset] + $new + $body[$m.offset + $m.length:]')"
  payload="$(jq -n --arg body "$body" --argjson issue "$issue" --arg triaged "$TRIAGED_LABEL" '{body: $body}
    + if $issue.state != "closed" then {}
      else {state: "open", state_reason: "reopened"}
        + if $issue.labels | index($triaged) then {labels: ($issue.labels - [$triaged])} else {} end
      end')"
  summary="update the marker of issue #$number"
  if [[ "$(jq -r .state <<< "$issue")" == closed ]]; then
    summary="reopen issue #$number and update its marker"
  fi
  write PATCH "repos/${REPO}/issues/${number}" "$summary" "$payload"
}

close_issue() {
  write PATCH "repos/${REPO}/issues/$1" "close issue #$1" '{"state": "closed", "state_reason": "completed"}'
}

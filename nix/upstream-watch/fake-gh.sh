#!/usr/bin/env bash
# Stands in for gh in the upstream-watch tests (nix/upstream-watch/test.sh).
# Supports only `gh api [--paginate] [--method M] [-H H] [--input -] ENDPOINT`.
# State lives in FAKE_STATE:
#   api.json       GET endpoint -> response; {"$file": path} serves a file raw
#   issues.json    this repository's issues; POST and PATCH change them
#   comments.json  issue number -> comments; POST adds to them
#   labels.json    this repository's labels; POST adds to them
#   calls.log      one "METHOD ENDPOINT" line per call
# An endpoint matching the regex FAKE_FAIL fails, as a network error would.
# shellcheck disable=SC2016 # $payload in jq filters is jq's.
set -euo pipefail

[[ "${1:-}" == api ]] || {
  printf 'fake gh: unsupported command: %s\n' "$*" >&2
  exit 2
}
shift
method=GET
endpoint=''
while (($#)); do
  case "$1" in
    --paginate) ;;
    --method)
      method="$2"
      shift
      ;;
    -H | --input) shift ;;
    -*)
      printf 'fake gh: unsupported flag: %s\n' "$1" >&2
      exit 2
      ;;
    *) endpoint="$1" ;;
  esac
  shift
done

state="$FAKE_STATE"
printf '%s %s\n' "$method" "$endpoint" >> "$state/calls.log"
if [[ -n "${FAKE_FAIL:-}" && "$endpoint" =~ $FAKE_FAIL ]]; then
  printf 'fake gh: HTTP 502 for %s\n' "$endpoint" >&2
  exit 1
fi

own="repos/${GITHUB_REPOSITORY}"
update() {
  jq "$@" > "$file.new"
  mv "$file.new" "$file"
}

case "$method ${endpoint%%\?*}" in
  "GET $own/issues")
    # Like GitHub: state defaults to open.
    wanted=open
    if [[ "$endpoint" =~ [?\&]state=([a-z]+) ]]; then
      wanted="${BASH_REMATCH[1]}"
    fi
    jq --arg wanted "$wanted" '[.[] | select(any(.labels[]; .name == "upstream-watch"))
      | select($wanted == "all" or .state == $wanted)]' "$state/issues.json"
    ;;
  "GET $own/labels")
    cat "$state/labels.json"
    ;;
  "POST $own/labels")
    file="$state/labels.json"
    update --slurpfile payload /dev/stdin '. + [{name: $payload[0].name}]' "$file"
    ;;
  "POST $own/issues")
    file="$state/issues.json"
    update --slurpfile payload /dev/stdin '. + [{
      number: ((map(.number) | max // 100) + 1), state: "open",
      title: $payload[0].title, body: $payload[0].body,
      labels: ($payload[0].labels | map({name: .}))
    }]' "$file"
    ;;
  "PATCH $own/issues/"*)
    file="$state/issues.json"
    update --slurpfile payload /dev/stdin --argjson number "${endpoint##*/}" \
      'map(if .number == $number then . + ($payload[0] | {body, state} | with_entries(select(.value))) else . end)' "$file"
    ;;
  "GET $own/issues/"*/comments)
    number="${endpoint#"$own/issues/"}"
    jq --arg number "${number%%/*}" '.[$number] // []' "$state/comments.json"
    ;;
  "POST $own/issues/"*/comments)
    number="${endpoint#"$own/issues/"}"
    file="$state/comments.json"
    update --slurpfile payload /dev/stdin --arg number "${number%%/*}" \
      '.[$number] += [{body: $payload[0].body}]' "$file"
    ;;
  GET\ *)
    response="$(jq -c --arg endpoint "$endpoint" '.[$endpoint] // empty' "$state/api.json")"
    if [[ -z "$response" ]]; then
      printf 'fake gh: HTTP 404 for %s\n' "$endpoint" >&2
      exit 1
    fi
    if jq -e 'type == "object" and has("$file")' <<< "$response" > /dev/null; then
      cat "$(jq -r '.["$file"]' <<< "$response")"
    else
      printf '%s\n' "$response"
    fi
    ;;
  *)
    printf 'fake gh: unsupported write: %s %s\n' "$method" "$endpoint" >&2
    exit 2
    ;;
esac

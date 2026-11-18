#!/usr/bin/env bash
# Stands in for curl in the offline tests (nix/measure-snp/test.sh). Expects
# measure-snp.sh's form, `curl [flags…] --output DEST URL`, and copies the
# file that FAKE_CURL_MAP (a JSON object, URL -> path) gives for URL. Unknown
# URLs fail as a 404 would with --fail. Each call is appended to CALL_LOG.
set -euo pipefail

args=("$@")
count=${#args[@]}
if ((count < 3)) || [[ "${args[count - 3]}" != --output ]]; then
  printf 'fake curl: expected --output DEST URL last: %s\n' "$*" >&2
  exit 2
fi
dest="${args[count - 2]}"
url="${args[count - 1]}"
printf 'curl %s\n' "$url" >> "$CALL_LOG"

source="$(jq -r --arg url "$url" '.[$url] // empty' "$FAKE_CURL_MAP")"
if [[ -z "$source" ]]; then
  printf 'curl: (22) The requested URL returned error: 404\n' >&2
  exit 22
fi
cp -- "$source" "$dest"

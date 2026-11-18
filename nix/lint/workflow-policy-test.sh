#!/usr/bin/env bash
# Tests for workflow-policy.sh: each case is a one-workflow repository that the
# policy must accept or reject. Run from the repository root.
set -euo pipefail

readonly policy="$PWD/nix/lint/workflow-policy.sh"
readonly sha=0123456789abcdef0123456789abcdef01234567
readonly header=$'on: push\npermissions: {}\njobs:\n  test:\n    runs-on: ubuntu-24.04\n    steps:'

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
cases=0

# check <pass|fail> <name> <steps> [expected output on failure]
check() {
  local want="$1" name="$2" steps="$3" expect="${4:-}" dir output got
  cases=$((cases + 1))
  dir="$work/$cases"
  mkdir -p "$dir/.github/workflows"
  printf '%s\n%s\n' "${HEADER:-$header}" "$steps" > "$dir/.github/workflows/test.yml"

  got=pass
  output="$(cd "$dir" && bash "$policy" 2>&1)" || got=fail
  if [[ "$got" != "$want" ]]; then
    printf 'FAIL %s: expected %s, got %s:\n%s\n' "$name" "$want" "$got" "$output"
    failures=$((failures + 1))
  elif [[ -n "$expect" && "$output" != *"$expect"* ]]; then
    printf 'FAIL %s: output lacks "%s":\n%s\n' "$name" "$expect" "$output"
    failures=$((failures + 1))
  else
    printf 'ok   %s\n' "$name"
  fi
}

check pass 'pinned' "      - uses: actions/checkout@$sha # v7"
check pass 'local action' '      - uses: ./.github/actions/install-nix'
check pass 'quoted value' "      - uses: \"actions/checkout@$sha\""
check pass 'uses as a later key' $'      - name: Checkout\n'"        uses: actions/checkout@$sha"
check pass 'comment and longer key names' \
  "      # uses: actions/checkout@v7"$'\n'"      - uses: actions/checkout@$sha"$'\n'"        with:"$'\n'"          causes: x"

check fail 'unpinned tag' '      - uses: actions/checkout@v7' 'not pinned'
check fail 'short SHA' '      - uses: actions/checkout@0123456' 'not pinned'
check fail 'value on the next line' $'      - uses:\n          actions/checkout@v7' 'not pinned'
check fail 'flow style' \
  "      - uses: actions/checkout@$sha"$'\n''      - { uses: actions/upload-artifact@v7 }' 'unsupported form'
check fail 'quoted key' \
  "      - uses: actions/checkout@$sha"$'\n''      - "uses": actions/upload-artifact@v7' 'unsupported form'
check fail 'space before the colon' \
  "      - uses: actions/checkout@$sha"$'\n''      - uses : actions/upload-artifact@v7' 'unsupported form'
HEADER=$'on: push\njobs:\n  test:\n    runs-on: ubuntu-24.04\n    steps:' \
  check fail 'no top-level permissions' "      - uses: actions/checkout@$sha" 'permissions: {}'

printf '%d cases, %d failed\n' "$cases" "$failures"
((failures == 0))

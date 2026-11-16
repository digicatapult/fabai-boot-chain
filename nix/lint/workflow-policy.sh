#!/usr/bin/env bash
# Repository policy for GitHub Actions that actionlint doesn't cover:
#   - every `uses:` is a local action or pinned to a full commit SHA
#   - every workflow has a top-level `permissions: {}`, so jobs get only the
#     permissions they ask for
# Run from the repository root.
set -euo pipefail

readonly pinned_ref='^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}$'

status=0
refs=0

while IFS= read -r match; do
  file="${match%%:*}"
  rest="${match#*:}"
  line="${rest%%:*}"
  ref="${rest#*uses:}"
  ref="${ref%%#*}"
  ref="${ref//[\"\']/}"
  ref="${ref//[[:space:]]/}"
  refs=$((refs + 1))

  if [[ "$ref" == ./* || "$ref" =~ $pinned_ref ]]; then
    continue
  fi
  printf '%s:%s: not pinned to a full commit SHA: %s\n' "$file" "$line" "$ref"
  status=1
done < <(grep -rnE --include='*.yml' --include='*.yaml' \
  '^[[:space:]]*(-[[:space:]]+)?uses:' .github || true)

# Guards against the pattern above silently matching nothing.
if ((refs == 0)); then
  printf 'no "uses:" found under .github; is this the repository root?\n'
  exit 1
fi

for workflow in .github/workflows/*.yml .github/workflows/*.yaml; do
  [[ -e "$workflow" ]] || continue
  if ! grep -qxE 'permissions:[[:space:]]*\{\}[[:space:]]*' "$workflow"; then
    printf '%s: missing top-level "permissions: {}"\n' "$workflow"
    status=1
  fi
done

if ((status == 0)); then
  printf 'checked %d action references\n' "$refs"
fi
exit "$status"

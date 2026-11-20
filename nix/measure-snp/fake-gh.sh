#!/usr/bin/env bash
# Stands in for gh in the offline tests (nix/measure-snp/test.sh). Supports
# only `gh attestation verify FILE` with the flags measure-snp.sh passes, and
# answers from FAKE_GH_ATTESTATIONS, a JSON array of the attestations that
# exist:
#   {sha256, repo, signerWorkflow, sourceRef, predicateType, runner}
# Verification passes if one attestation for the file's digest matches every
# flag given, as the real gh requires. Each call is appended to CALL_LOG.
set -euo pipefail

printf 'gh %s\n' "$*" >> "$CALL_LOG"

if [[ "${1:-}" != attestation || "${2:-}" != verify || $# -lt 3 ]]; then
  printf 'fake gh: unsupported command: %s\n' "$*" >&2
  exit 2
fi
file="$3"
shift 3

repo=''
signer=''
ref=''
predicate=https://slsa.dev/provenance/v1
deny_self_hosted=false
while (($#)); do
  case "$1" in
    --repo) repo="$2" ;;
    --signer-workflow) signer="$2" ;;
    --source-ref) ref="$2" ;;
    --predicate-type) predicate="$2" ;;
    --deny-self-hosted-runners)
      deny_self_hosted=true
      shift
      continue
      ;;
    *)
      printf 'fake gh: unsupported flag: %s\n' "$1" >&2
      exit 2
      ;;
  esac
  shift 2
done
[[ -n "$repo" ]] || {
  printf 'fake gh: --repo is required\n' >&2
  exit 2
}

digest="$(sha256sum -- "$file" | cut -d ' ' -f 1)"
matches="$(jq \
  --arg digest "$digest" --arg repo "$repo" --arg signer "$signer" --arg ref "$ref" \
  --arg predicate "$predicate" --argjson deny "$deny_self_hosted" \
  '[.[] | select(
    .sha256 == $digest and .repo == $repo and .predicateType == $predicate
    and ($signer == "" or .signerWorkflow == $signer)
    and ($ref == "" or .sourceRef == $ref)
    and (($deny | not) or .runner == "github-hosted")
  )] | length' "$FAKE_GH_ATTESTATIONS")"

if ((matches == 0)); then
  printf 'fake gh: no attestation of %s matches\n' "$file" >&2
  exit 1
fi
printf 'fake gh: verified %s\n' "$file"

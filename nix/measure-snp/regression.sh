#!/usr/bin/env bash
# Measurement regression vectors for measure-snp.sh's core, against Tinfoil's
# published deployment of confidential-model-router v0.0.178 (cvmimage
# v0.14.19, 8 vCPUs). Needs the network and a GitHub token, so it runs in
# test.yml's advisory "Measurement regression" job, not in Nix. Every Tinfoil
# input is pinned by digest and its attestation verified before measuring:
#   1. Tinfoil's OVMF.fd v0.0.4 must reproduce the published measurement.
#   2. FabAI's cc OVMF.fd (CC_IMAGE) with the same inputs must give the FabAI
#      vector. The vector holds for one cc image only, so a cc image with
#      another digest fails here until the vector is updated.
# Environment: MEASURE_SNP_TOOLS (the measure-snp-tools package), GH_TOKEN,
# CC_IMAGE (path to FabAI's cc OVMF.fd).
set -euo pipefail

readonly measure="$PWD/.github/actions/measure-snp/measure-snp.sh"
PATH="$MEASURE_SNP_TOOLS/bin:$PATH"

readonly deployment_url=https://github.com/tinfoilsh/confidential-model-router/releases/download/v0.0.178/tinfoil-deployment.json
readonly deployment_sha256=d9beadbdb487812581c2432a6eaf2b6483d88565e70bd7eb39a78ad93eebbdba
readonly manifest_url=https://github.com/tinfoilsh/cvmimage/releases/download/v0.14.19/tinfoil-inference-v0.14.19-manifest.json
readonly manifest_sha256=9e6e8b1ffe6a95857621835084930bdeacff2bba015e064568b108de9d5bf81a
readonly images=https://images.tinfoil.sh/cvm/tinfoil-inference-v0.14.19
readonly tinfoil_ovmf_url=https://github.com/tinfoilsh/edk2/releases/download/v0.0.4/OVMF.fd
readonly tinfoil_ovmf_sha256=78c890175928167a1bc095d4bf3bb4ad81de80cd7e4e9e683477fc359119c1c4
readonly tinfoil_vector=fc6a1c627b66f661b3748edddf4e5bce47358dedbaaa3f0d244f50e555ce24996fb9f36bf96c1836547510e965d0c6e4
readonly fabai_cc_sha256=a395a4995dafb944f6a7ac2f4d44d889ccd522d25505481e86d169e7328cfde2
readonly fabai_vector=e7d8f6fc2f2a00541db05aff5142152d319bb63d71caebc1e378e908fc79bb2e6005804b63150b1e9aa4fa9029e85cbc
readonly cpus=8

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

# fetch URL DEST SHA256
fetch() {
  curl --fail --silent --show-error --location --retry 3 \
    --proto '=https' --proto-redir '=https' --tlsv1.2 --output "$2" "$1"
  check_sha256 "$2" "$3"
}

check_sha256() {
  local actual
  actual="$(sha256sum -- "$1" | cut -d ' ' -f 1)"
  [[ "$actual" == "$2" ]] || fail "$1 has SHA-256 ${actual}, expected $2"
}

# verify FILE REPO SIGNER_WORKFLOW SOURCE_REF PREDICATE_TYPE
verify() {
  gh attestation verify "$1" --repo "$2" --signer-workflow "$3" --source-ref "$4" \
    --predicate-type "$5" --deny-self-hosted-runners
}

# check_vector NAME FIRMWARE EXPECTED
check_vector() {
  local result measurement cmdline
  result="$(bash "$measure" core "$2" "$work/kernel" "$work/initrd" "$root" "$work/config.yml" "$cpus")"
  measurement="$(jq -r .measurement <<< "$result")"
  cmdline="$(jq -r .cmdline <<< "$result")"
  printf '%s: %s\n' "$1" "$measurement"
  [[ "$cmdline" == "$(jq -r .cmdline "$work/deployment.json")" ]] ||
    fail "$1: cmdline differs from the published one: $cmdline"
  [[ "$measurement" == "$3" ]] || fail "$1: expected $3"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    # shellcheck disable=SC2016 # Backticks in the summary are Markdown.
    printf -- '- %s: `%s`\n' "$1" "$measurement" >> "$GITHUB_STEP_SUMMARY"
  fi
}

[[ -f "${CC_IMAGE:?}" ]] || fail "CC_IMAGE is not a file: $CC_IMAGE"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fetch "$deployment_url" "$work/deployment.json" "$deployment_sha256"
verify "$work/deployment.json" tinfoilsh/confidential-model-router \
  tinfoilsh/confidential-model-router/.github/workflows/tinfoil-release-publish.yml \
  refs/tags/v0.0.178 https://tinfoil.sh/predicate/snp-tdx-multiplatform/v1
jq -r .config "$work/deployment.json" | base64 -d > "$work/config.yml"
tinfoil-config "$work/config.yml"

fetch "$manifest_url" "$work/manifest.json" "$manifest_sha256"
verify "$work/manifest.json" tinfoilsh/cvmimage tinfoilsh/cvmimage/.github/workflows/release.yml \
  refs/tags/v0.14.19 https://slsa.dev/provenance/v1
root="$(jq -r .root "$work/manifest.json")"
fetch "${images}.vmlinuz" "$work/kernel" "$(jq -r .kernel "$work/manifest.json")"
fetch "${images}.initrd" "$work/initrd" "$(jq -r .initrd "$work/manifest.json")"

# Tinfoil's firmware is attested with Tinfoil's own predicate type, and at two
# tags; only v0.0.4 is accepted here.
fetch "$tinfoil_ovmf_url" "$work/OVMF-tinfoil.fd" "$tinfoil_ovmf_sha256"
verify "$work/OVMF-tinfoil.fd" tinfoilsh/edk2 tinfoilsh/edk2/.github/workflows/release.yml \
  refs/tags/v0.0.4 https://tinfoil.sh/predicate/component-artifact/v1

[[ "$(jq -r .snp_measurement "$work/deployment.json")" == "$tinfoil_vector" ]] ||
  fail "the published deployment's snp_measurement isn't the Tinfoil vector"
check_sha256 "$CC_IMAGE" "$fabai_cc_sha256"

check_vector 'Tinfoil OVMF.fd v0.0.4' "$work/OVMF-tinfoil.fd" "$tinfoil_vector"
check_vector 'FabAI cc OVMF.fd' "$CC_IMAGE" "$fabai_vector"

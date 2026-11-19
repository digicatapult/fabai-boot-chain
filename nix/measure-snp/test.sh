#!/usr/bin/env bash
# Offline tests for .github/actions/measure-snp/measure-snp.sh, run by
# nix/measure-snp.nix in the Nix sandbox. Environment:
#   ACTION_DIR          .github/actions (measure-snp and install-nix)
#   TOOLS               the measure-snp-tools package
#   OVMF_FIXTURE        a small AmdSevX64 OVMF image that sev-snp-measure parses
#   TINFOIL_DEPLOYMENT  confidential-model-router v0.0.178 tinfoil-deployment.json
#   TINFOIL_MANIFEST    cvmimage v0.14.19 manifest
#
# Each action case runs a copy of measure-snp.sh with its own firmware.json and
# supported.json, fixture inputs, and fake gh and curl (fake-gh.sh,
# fake-curl.sh). tinfoil-config and sev-snp-measure are the real ones, wrapped
# to log their calls, so a case can check what ran and in which order.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly here
PATH="$TOOLS/bin:$PATH"

readonly image_tag=v0.14.19
readonly image_repo=tinfoilsh/cvmimage
readonly image_signer=tinfoilsh/cvmimage/.github/workflows/release.yml
readonly manifest_url="https://github.com/${image_repo}/releases/download/${image_tag}/tinfoil-inference-${image_tag}-manifest.json"
readonly kernel_url="https://images.tinfoil.sh/cvm/tinfoil-inference-${image_tag}.vmlinuz"
readonly initrd_url="https://images.tinfoil.sh/cvm/tinfoil-inference-${image_tag}.initrd"
readonly fw_tag=ovmf-edk2-stable202608-r1
readonly fw_repo=digicatapult/fabai-boot-chain
readonly fw_signer="$fw_repo/.github/workflows/release.yml"
readonly fw_url="https://github.com/${fw_repo}/releases/download/${fw_tag}/OVMF.fd"
readonly slsa=https://slsa.dev/provenance/v1
readonly bash_path="$BASH"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cases=0
checks=0
failures=0

sha256() {
  sha256sum -- "$1" | cut -d ' ' -f 1
}

# edit_json FILE FILTER [jq args…]
edit_json() {
  local file="$1" filter="$2"
  shift 2
  jq "$@" "$filter" "$file" > "$file.new"
  mv "$file.new" "$file"
}

# write_config CVM_VERSION CPUS [extra YAML]
write_config() {
  printf 'cvm-version: %s\ncpus: %s\nmemory: 8192\n%s\nshim:\n  upstream-port: 8080\ncontainers:\n  - name: app\n    image: example.com/app@sha256:%s\n' \
    "$1" "$2" "${3:-}" "$(printf 'a%.0s' {1..64})" > "$fixtures/config.yml"
}

# wrap NAME COMMAND…: a tool that logs its call, then runs COMMAND.
wrap() {
  local name="$1"
  shift
  {
    printf '#!%s\n' "$bash_path"
    # shellcheck disable=SC2016 # Expands in the wrapper, not here.
    printf 'printf '\''%%s %%s\\n'\'' %q "$*" >> "$CALL_LOG"\n' "$name"
    printf 'exec'
    printf ' %q' "$@"
    printf ' "$@"\n'
  } > "$case_dir/tools/bin/$name"
  chmod +x "$case_dir/tools/bin/$name"
}

# A fresh case: fixtures, pins, attestations, downloads and tools that all
# agree, so the action succeeds unless the case changes something.
setup() {
  cases=$((cases + 1))
  case_dir="$work/$cases"
  fixtures="$case_dir/fixtures"
  mkdir -p "$case_dir"/{actions/measure-snp,tmp,tools/bin,tools/share/measure-snp} "$fixtures"
  cp "$ACTION_DIR/measure-snp/measure-snp.sh" "$case_dir/actions/measure-snp/"
  : > "$case_dir/github-output"
  : > "$case_dir/calls"

  printf 'test kernel\n' > "$fixtures/kernel"
  printf 'test initrd\n' > "$fixtures/initrd"
  cp "$OVMF_FIXTURE" "$fixtures/OVMF.fd"
  chmod u+w "$fixtures/OVMF.fd"
  jq -n --arg version "$image_tag" --arg kernel "$(sha256 "$fixtures/kernel")" \
    --arg initrd "$(sha256 "$fixtures/initrd")" --arg root "$(printf 'r%.0s' {1..32} | sha256sum | cut -d ' ' -f 1)" \
    '{version: $version, root: $root, initrd: $initrd, kernel: $kernel, raw: $root}' > "$fixtures/manifest.json"
  manifest_sha256="$(sha256 "$fixtures/manifest.json")"
  write_config "0.14.19@sha256:${manifest_sha256}" 4

  jq -n --arg tag "$fw_tag" --arg sha256 "$(sha256 "$fixtures/OVMF.fd")" --arg signer "$fw_signer" \
    '{tag: $tag, sha256: $sha256, "signer-workflow": $signer}' > "$case_dir/actions/measure-snp/firmware.json"
  jq -n --arg sha256 "$manifest_sha256" '{"0.14.19": {"manifest-sha256": $sha256}}' \
    > "$case_dir/actions/measure-snp/supported.json"

  jq -n \
    --arg manifest "$manifest_sha256" --arg imageRepo "$image_repo" --arg imageSigner "$image_signer" \
    --arg imageRef "refs/tags/$image_tag" \
    --arg firmware "$(sha256 "$fixtures/OVMF.fd")" --arg fwRepo "$fw_repo" --arg fwSigner "$fw_signer" \
    --arg fwRef "refs/tags/$fw_tag" --arg slsa "$slsa" \
    '[
      {sha256: $manifest, repo: $imageRepo, signerWorkflow: $imageSigner, sourceRef: $imageRef,
       predicateType: $slsa, runner: "github-hosted"},
      {sha256: $firmware, repo: $fwRepo, signerWorkflow: $fwSigner, sourceRef: $fwRef,
       predicateType: $slsa, runner: "github-hosted"}
    ]' > "$case_dir/attestations.json"
  jq -n --arg manifest "$manifest_url" --arg kernel "$kernel_url" --arg initrd "$initrd_url" \
    --arg firmware "$fw_url" --arg dir "$fixtures" \
    '{($manifest): "\($dir)/manifest.json", ($kernel): "\($dir)/kernel",
      ($initrd): "\($dir)/initrd", ($firmware): "\($dir)/OVMF.fd"}' > "$case_dir/downloads.json"

  local tool
  for tool in "$TOOLS"/bin/*; do
    ln -s "$tool" "$case_dir/tools/bin/"
  done
  rm "$case_dir/tools/bin/"{gh,sev-snp-measure,tinfoil-config}
  wrap sev-snp-measure "$TOOLS/bin/sev-snp-measure"
  wrap tinfoil-config "$TOOLS/bin/tinfoil-config"
  printf '#!%s\nexec %q %q "$@"\n' "$bash_path" "$bash_path" "$here/fake-gh.sh" > "$case_dir/tools/bin/gh"
  printf '#!%s\nexec %q %q "$@"\n' "$bash_path" "$bash_path" "$here/fake-curl.sh" > "$case_dir/tools/bin/curl"
  chmod +x "$case_dir/tools/bin/"{gh,curl}
  cp "$TOOLS/share/measure-snp/versions.json" "$case_dir/tools/share/measure-snp/"
}

run_action() {
  env -u GITHUB_STEP_SUMMARY \
    CONFIG_FILE="$fixtures/config.yml" \
    GH_TOKEN=test-token \
    MEASURE_SNP_TOOLS="$case_dir/tools" \
    RUNNER_TEMP="$case_dir/tmp" \
    GITHUB_OUTPUT="$case_dir/github-output" \
    CALL_LOG="$case_dir/calls" \
    FAKE_GH_ATTESTATIONS="$case_dir/attestations.json" \
    FAKE_CURL_MAP="$case_dir/downloads.json" \
    "$bash_path" "$case_dir/actions/measure-snp/measure-snp.sh" action > "$case_dir/log" 2>&1
}

output() {
  sed -n "s/^$1=//p" "$case_dir/github-output"
}

report() {
  checks=$((checks + 1))
  if (($# == 1)); then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s: %s\n' "$1" "$2"
    if [[ -f "${case_dir:-}/log" ]]; then
      sed 's/^/     | /' "$case_dir/log"
    fi
    failures=$((failures + 1))
  fi
}

# expect_failure NAME MESSAGE [no-downloads]: the run fails with MESSAGE,
# before any measurement, and leaves no documents and no outputs.
expect_failure() {
  local name="$1" message="$2"
  if run_action; then
    report "$name" "succeeded"
  elif ! grep -qF -- "$message" "$case_dir/log"; then
    report "$name" "output lacks \"$message\""
  elif grep -q '^sev-snp-measure' "$case_dir/calls"; then
    report "$name" "sev-snp-measure ran"
  elif [[ -n "$(ls -A "$case_dir/tmp")" ]]; then
    report "$name" "left files behind: $(ls -A "$case_dir/tmp")"
  elif [[ -s "$case_dir/github-output" ]]; then
    report "$name" "set outputs: $(cat "$case_dir/github-output")"
  elif [[ "${3:-}" == no-downloads ]] && grep -q '^curl' "$case_dir/calls"; then
    report "$name" "downloaded before failing: $(grep '^curl' "$case_dir/calls")"
  else
    report "$name"
  fi
}

# The order in which a successful run calls its tools.
readonly expected_calls="tinfoil-config
curl $manifest_url
gh attestation verify
curl $kernel_url
curl $initrd_url
curl $fw_url
gh attestation verify
sev-snp-measure"

check_success() {
  local name=success
  if ! run_action; then
    report "$name" "failed"
    return
  fi
  local measurement document entry calls
  measurement="$(output measurement)"
  document="$(output document)"
  entry="$(output allowlist-entry)"
  calls="$(sed -E 's/^(tinfoil-config|sev-snp-measure|gh attestation verify).*/\1/' "$case_dir/calls")"

  local direct
  direct="$(MEASURE_SNP_TOOLS="$TOOLS" bash "$ACTION_DIR/measure-snp/measure-snp.sh" core \
    "$fixtures/OVMF.fd" "$fixtures/kernel" "$fixtures/initrd" "$(jq -r .root "$fixtures/manifest.json")" \
    "$fixtures/config.yml" 4 | jq -r .measurement)"

  if [[ ! "$measurement" =~ ^[0-9a-f]{96}$ ]]; then
    report "$name" "measurement output: \"$measurement\""
  elif [[ "$(output document-sha256)" != "$(sha256 "$document")" ]]; then
    report "$name" "document-sha256 doesn't match the document"
  elif [[ "$(jq -r .measurement "$document")" != "$measurement" ]]; then
    report "$name" "the document's measurement differs from the output"
  elif [[ "$measurement" != "$direct" ]]; then
    report "$name" "measurement $measurement differs from core's $direct"
  elif [[ "$calls" != "$expected_calls" ]]; then
    report "$name" "calls in the wrong order:"$'\n'"$calls"
  elif grep '^gh ' "$case_dir/calls" | grep -v -e '--deny-self-hosted-runners' -e "--predicate-type $slsa" | grep -q .; then
    report "$name" "a gh call lacks --deny-self-hosted-runners or --predicate-type"
  elif ! jq -e \
    --arg tag "$fw_tag" --arg firmware "$(sha256 "$fixtures/OVMF.fd")" --arg manifest "$manifest_sha256" \
    --arg config "$(sha256 "$fixtures/config.yml")" --arg configBase64 "$(base64 -w 0 "$fixtures/config.yml")" \
    '.firmware == {repository: "digicatapult/fabai-boot-chain", tag: $tag, asset: "OVMF.fd", sha256: $firmware}
     and .runtimeImage.version == "0.14.19" and .runtimeImage.manifestSha256 == $manifest
     and .config == {sha256: $config, base64: $configBase64}
     and (.cmdline | endswith("tinfoil-config-hash=\($config)"))
     and .vmShape == {cpus: 4, vcpuType: "EPYC-v4", vcpuSignature: "0x800f12", memory: 8192, gpus: null}
     and .launch.guestFeatures == "0x1"
     and .tools["sev-snp-measure"] == "0.0.12" and .tools["tinfoil-config"] == "0.1.23"' \
    "$document" > /dev/null; then
    report "$name" "unexpected document: $(cat "$document")"
  elif ! jq -e --slurpfile doc "$document" \
    '.measurement == $doc[0].measurement and .cmdline == $doc[0].cmdline
     and .configSha256 == $doc[0].config.sha256 and .firmware.sha256 == $doc[0].firmware.sha256
     and .runtimeImage.kernelSha256 == $doc[0].runtimeImage.kernelSha256
     and .vmShape.cpus == 4 and .guestFeatures == "0x1"' "$entry" > /dev/null; then
    report "$name" "unexpected allowlist entry: $(cat "$entry")"
  else
    report "$name"
  fi
}

## The action's interface

inputs="$(yq -o json -I 0 '.inputs | keys' "$ACTION_DIR/measure-snp/action.yml")"
if [[ "$inputs" == '["config-file","github-token"]' ]]; then
  report 'no input selects the firmware'
else
  report 'no input selects the firmware' "inputs are $inputs"
fi

setup
check_success

## Pins

setup
edit_json "$case_dir/actions/measure-snp/firmware.json" '.tag = null | .sha256 = null'
expect_failure 'no firmware release pinned' 'pins no firmware release yet' no-downloads

setup
edit_json "$case_dir/actions/measure-snp/firmware.json" '.tag = "ovmf-head-20261117-0123456789ab"'
expect_failure 'HEAD release pinned' 'is not a stable release tag' no-downloads

setup
edit_json "$case_dir/actions/measure-snp/firmware.json" \
  '."signer-workflow" = "digicatapult/fabai-boot-chain/.github/workflows/release-head.yml"'
expect_failure 'HEAD signer pinned' 'signer-workflow must be' no-downloads

## Config

setup
write_config "0.14.19@sha256:${manifest_sha256}" 4 'unknown-key: 1'
expect_failure 'invalid config' 'rejected by tinfoil-config' no-downloads

setup
write_config 0.14.19 4
expect_failure 'unpinned cvm-version' 'cvm-version must be' no-downloads

setup
write_config "0.15.4@sha256:${manifest_sha256}" 4
expect_failure 'cvm-version 0.15 (IGVM)' 'cvm-version must be' no-downloads

setup
write_config "0.14.15@sha256:${manifest_sha256}" 4
expect_failure 'cvm-version 0.14.15 (CVE-2026-98432 kernel) not in supported.json' 'is not supported' no-downloads

setup
write_config "0.14.19@sha256:$(printf '0%.0s' {1..64})" 4
expect_failure 'cvm-version pins another manifest' 'but supported.json has' no-downloads

setup
write_config "0.14.19@sha256:${manifest_sha256}" 0
expect_failure 'cpus 0' 'cpus must be a positive decimal integer' no-downloads

setup
write_config "0.14.19@sha256:${manifest_sha256}" 0x4
expect_failure 'cpus in hex' 'cpus must be a positive decimal integer' no-downloads

setup
write_config "0.14.19@sha256:${manifest_sha256}" '"4"'
expect_failure 'cpus as a string' 'tinfoil-config' no-downloads

## Runtime image

setup
printf '\n' >> "$fixtures/manifest.json"
expect_failure 'manifest digest mismatch' "has SHA-256 $(sha256 "$fixtures/manifest.json"), expected $manifest_sha256"
if grep -q '^gh' "$case_dir/calls"; then
  report 'manifest digest checked before its attestation' 'gh ran'
else
  report 'manifest digest checked before its attestation'
fi

setup
edit_json "$case_dir/attestations.json" 'del(.[0])'
expect_failure 'manifest not attested' 'has no attestation'

setup
edit_json "$case_dir/attestations.json" '.[0].signerWorkflow = "tinfoilsh/cvmimage/.github/workflows/platform-release.yml"'
expect_failure 'manifest signed by another workflow' 'has no attestation'

setup
edit_json "$case_dir/attestations.json" '.[0].sourceRef = "refs/tags/v0.14.14"'
expect_failure 'manifest signed at another tag' 'has no attestation'

setup
edit_json "$case_dir/attestations.json" '.[0].runner = "self-hosted"'
expect_failure 'manifest signed on a self-hosted runner' 'has no attestation'

setup
printf 'tampered kernel\n' > "$fixtures/kernel"
expect_failure 'tampered kernel' 'kernel has SHA-256'
if grep -q "^curl $fw_url" "$case_dir/calls"; then
  report 'kernel checked before the firmware' 'firmware downloaded'
else
  report 'kernel checked before the firmware'
fi

setup
printf 'tampered initrd\n' > "$fixtures/initrd"
expect_failure 'tampered initrd' 'initrd has SHA-256'

## Firmware

setup
pinned="$(jq -r .sha256 "$case_dir/actions/measure-snp/firmware.json")"
printf 'x' >> "$fixtures/OVMF.fd"
expect_failure 'firmware digest mismatch names both digests' \
  "has SHA-256 $(sha256 "$fixtures/OVMF.fd"), expected $pinned"

setup
edit_json "$case_dir/attestations.json" \
  '.[1].signerWorkflow = "digicatapult/fabai-boot-chain/.github/workflows/release-head.yml"
   | .[1].sourceRef = "refs/heads/main"'
expect_failure 'HEAD-signed firmware refused' 'has no attestation'

setup
edit_json "$case_dir/attestations.json" '.[1].sourceRef = "refs/tags/ovmf-edk2-stable202605-r1"'
expect_failure 'firmware signed at another tag' 'has no attestation'

setup
edit_json "$case_dir/attestations.json" '.[1].runner = "self-hosted"'
expect_failure 'firmware signed on a self-hosted runner' 'has no attestation'

## Measurement core

setup
core() {
  MEASURE_SNP_TOOLS="$TOOLS" bash "$ACTION_DIR/measure-snp/measure-snp.sh" core \
    "$fixtures/OVMF.fd" "$fixtures/kernel" "$fixtures/initrd" "$(jq -r .root "$fixtures/manifest.json")" "$@"
}
four="$(core "$fixtures/config.yml" 4 | jq -r .measurement)"
eight="$(core "$fixtures/config.yml" 8 | jq -r .measurement)"
if [[ "$four" =~ ^[0-9a-f]{96}$ && "$eight" =~ ^[0-9a-f]{96}$ && "$four" != "$eight" ]]; then
  report 'vCPU count changes the measurement'
else
  report 'vCPU count changes the measurement' "4: $four, 8: $eight"
fi

sed 's/^cpus: 4$/cpus:  4/' "$fixtures/config.yml" > "$fixtures/spaced.yml"
plain="$(core "$fixtures/config.yml" 4)"
spaced="$(core "$fixtures/spaced.yml" 4)"
if [[ "$(jq -r .configSha256 <<< "$plain")" != "$(jq -r .configSha256 <<< "$spaced")" &&
  "$(jq -r .measurement <<< "$plain")" != "$(jq -r .measurement <<< "$spaced")" ]]; then
  report 'config hash covers the raw bytes'
else
  report 'config hash covers the raw bytes' 'whitespace made no difference'
fi

if core "$fixtures/config.yml" 0 > /dev/null 2>&1; then
  report 'core rejects cpus 0' 'accepted'
else
  report 'core rejects cpus 0'
fi

## Installing Nix: the pins come from install-nix's action.yml

setup
mkdir "$case_dir/actions/install-nix"
cp "$ACTION_DIR/install-nix/action.yml" "$case_dir/actions/install-nix/"
# shellcheck disable=SC2016 # Expands in the stand-in installer, not here.
printf 'printf '\''%%s %%s\\n'\'' "$NIX_VERSION" "$NIX_INSTALLER_SHA256"\n' > "$case_dir/actions/install-nix/install-nix.sh"
if command -v nix > /dev/null; then
  report 'install-nix reads the pins' 'nix is on PATH, so the install is skipped'
else
  pins="$(GH_TOKEN=test-token "$bash_path" "$case_dir/actions/measure-snp/measure-snp.sh" install-nix)"
  if [[ "$pins" =~ ^[0-9]+\.[0-9]+\.[0-9]+\ [0-9a-f]{64}$ ]]; then
    report 'install-nix reads the pins'
  else
    report 'install-nix reads the pins' "got \"$pins\""
  fi
fi

## Tinfoil's published deployment (confidential-model-router v0.0.178)

config="$work/tinfoil-config.yml"
jq -r .config "$TINFOIL_DEPLOYMENT" | base64 -d > "$config"
cmdline="$(bash "$ACTION_DIR/measure-snp/measure-snp.sh" cmdline "$(jq -r .root "$TINFOIL_MANIFEST")" "$config")"
if [[ "$cmdline" == "$(jq -r .cmdline "$TINFOIL_DEPLOYMENT")" ]]; then
  report 'cmdline matches the published deployment'
else
  report 'cmdline matches the published deployment' "built: $cmdline"
fi

if tinfoil-config "$config" > /dev/null && ! { cat "$config" && printf 'unknown-key: 1\n'; } |
  tinfoil-config /dev/stdin > /dev/null 2>&1; then
  report 'tinfoil-config accepts the published config and rejects a broken one'
else
  report 'tinfoil-config accepts the published config and rejects a broken one' 'wrong verdict'
fi

# 0.14.19 only: earlier 0.14.x kernels lack the CVE-2026-98432 fix.
supported="$(jq -c '.' "$ACTION_DIR/measure-snp/supported.json")"
expected="$(jq -nc --arg sha256 "$(sha256 "$TINFOIL_MANIFEST")" '{"0.14.19": {"manifest-sha256": $sha256}}')"
if [[ "$supported" == "$expected" ]]; then
  report 'supported.json pins only the published 0.14.19 manifest'
else
  report 'supported.json pins only the published 0.14.19 manifest' "supported.json has $supported"
fi

printf '%d checks, %d failed\n' "$checks" "$failures"
((failures == 0))

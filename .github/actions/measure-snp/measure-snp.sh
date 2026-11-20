#!/usr/bin/env bash
# Computes the SEV-SNP launch measurement of a cvmimage 0.14.x deployment on
# this repository's pinned cc firmware (README, "Measuring a deployment").
#
# Called by action.yml, in this order:
#   install-nix  install Nix with ../install-nix/install-nix.sh, unless Nix is
#                already on PATH
#   tools        build the pinned tools from this repository's flake; write
#                their store path to GITHUB_OUTPUT as `path`
#   action       verify every input, measure, and write the documents. Reads
#                CONFIG_FILE, GH_TOKEN, MEASURE_SNP_TOOLS, RUNNER_TEMP and
#                GITHUB_OUTPUT
# and by the tests:
#   cmdline ROOT CONFIG
#       print the kernel cmdline for a manifest root hash and a config file
#   core FIRMWARE KERNEL INITRD ROOT CONFIG CPUS
#       print {cmdline, configSha256, measurement} as JSON
#
# `core` trusts its arguments. Only `action` verifies inputs, and action.yml
# never calls `core`, so the firmware can't be chosen through the action: it is
# always the release pinned in firmware.json.
set -euo pipefail

action_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly action_dir

readonly sha256_pattern='^[0-9a-f]{64}$'
readonly positive_int='^[1-9][0-9]*$'
readonly slsa_predicate=https://slsa.dev/provenance/v1

# Firmware: stable releases of this repository only, never HEAD prereleases,
# and only the cc image. release.yml signs OVMF-noncc.fd too, so the asset
# name and the pinned digest are what exclude it.
readonly firmware_asset=OVMF.fd
readonly stable_tag='^ovmf-edk2-stable[0-9]{6}(\.[0-9]{2})?-r[1-9][0-9]*$'
readonly stable_signer='^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/\.github/workflows/release\.yml$'

# Runtime image: cvmimage 0.14.x boots OVMF with QEMU direct boot. 0.15 boots
# IGVM, which sev-snp-measure can't measure (ADR-0008).
readonly image_repo=tinfoilsh/cvmimage
readonly image_signer=tinfoilsh/cvmimage/.github/workflows/release.yml
readonly image_downloads=https://images.tinfoil.sh/cvm
readonly pinned_version='^(0\.14\.(0|[1-9][0-9]*))@sha256:([0-9a-f]{64})$'

# Launch settings. They imply a host launch with -cpu EPYC-v4 (family 23,
# model 1, stepping 2) and sev-snp-guest without IGVM; anything else measures
# differently.
readonly vcpu_type=EPYC-v4
readonly vcpu_signature=0x800f12
readonly vmm_type=QEMU
readonly guest_features=0x1

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

sha256() {
  sha256sum -- "$1" | cut -d ' ' -f 1
}

# check_sha256 FILE EXPECTED WHAT
check_sha256() {
  local actual
  actual="$(sha256 "$1")"
  [[ "$actual" == "$2" ]] || fail "$3 has SHA-256 ${actual}, expected $2"
  printf '%s: SHA-256 %s\n' "$3" "$actual"
}

# fetch URL DEST. The tests' fake curl relies on --output DEST URL coming last.
fetch() {
  printf 'Downloading %s\n' "$1"
  curl --fail --silent --show-error --location --retry 3 \
    --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --output "$2" "$1" || fail "download failed: $1"
}

# verify_attestation FILE REPO SIGNER_WORKFLOW SOURCE_REF PREDICATE_TYPE WHAT
verify_attestation() {
  gh attestation verify "$1" \
    --repo "$2" \
    --signer-workflow "$3" \
    --source-ref "$4" \
    --predicate-type "$5" \
    --deny-self-hosted-runners ||
    fail "$6 has no attestation from $3 at $4"
  printf '%s: attested by %s at %s\n' "$6" "$3" "$4"
}

# config_scalar KEY prints "<YAML tag>\t<value as written>" for a top-level
# key. Aliases are expanded, and the value is kept as written, so that only
# plain decimal integers pass the checks below: those read the same in yq and
# in the guest's YAML parser.
config_scalar() {
  yq -r "explode(.) | .[\"$1\"] | [tag, .] | @tsv" "$CONFIG_FILE" ||
    fail "config-file: $1 must be a scalar"
}

# config_count KEY: a non-negative integer, or null if unset. For information
# only; the measurement doesn't depend on it.
config_count() {
  local tag value
  IFS=$'\t' read -r tag value < <(config_scalar "$1")
  case "$tag" in
    '!!null') printf 'null\n' ;;
    '!!int')
      [[ "$value" == 0 || "$value" =~ $positive_int ]] ||
        fail "config-file: $1 must be a plain decimal integer, got $value"
      printf '%s\n' "$value"
      ;;
    *) fail "config-file: $1 must be an integer, got $tag $value" ;;
  esac
}

build_cmdline() {
  local root="$1" config_sha256="$2"
  printf 'readonly=on pci=realloc,nocrs modprobe.blacklist=nouveau nouveau.modeset=0 root=/dev/mapper/root roothash=%s tinfoil-config-hash=%s' \
    "$root" "$config_sha256"
}

# core FIRMWARE KERNEL INITRD ROOT CONFIG CPUS
core() {
  (($# == 6)) || fail "usage: $0 core FIRMWARE KERNEL INITRD ROOT CONFIG CPUS"
  local firmware="$1" kernel="$2" initrd="$3" root="$4" config="$5" cpus="$6"
  local file
  for file in "$firmware" "$kernel" "$initrd" "$config"; do
    [[ -f "$file" ]] || fail "not a file: $file"
  done
  [[ "$root" =~ $sha256_pattern ]] || fail "root hash must be 64 lowercase hex characters, got $root"
  [[ "$cpus" =~ $positive_int ]] || fail "cpus must be a positive integer, got $cpus"

  local config_sha256 cmdline measurement
  config_sha256="$(sha256 "$config")"
  cmdline="$(build_cmdline "$root" "$config_sha256")"
  measurement="$(sev-snp-measure --mode snp \
    --vcpus "$cpus" \
    --vcpu-type "$vcpu_type" \
    --vmm-type "$vmm_type" \
    --guest-features "$guest_features" \
    --output-format hex \
    --ovmf "$firmware" \
    --kernel "$kernel" \
    --initrd "$initrd" \
    --append "$cmdline")" || fail "sev-snp-measure failed"
  [[ "$measurement" =~ ^[0-9a-f]{96}$ ]] ||
    fail "sev-snp-measure printed \"$measurement\", not 96 lowercase hex characters"

  jq -n --arg cmdline "$cmdline" --arg configSha256 "$config_sha256" --arg measurement "$measurement" \
    '{cmdline: $cmdline, configSha256: $configSha256, measurement: $measurement}'
}

install_nix() {
  if command -v nix > /dev/null; then
    printf 'Using the installed %s\n' "$(nix --version)"
    return
  fi
  # The pins live in install-nix's action.yml, where Renovate updates them.
  local pins="$action_dir/../install-nix/action.yml" version installer_sha256
  version="$(sed -nE 's/^[[:space:]]+NIX_VERSION:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+)[[:space:]]*$/\1/p' "$pins")"
  installer_sha256="$(sed -nE 's/^[[:space:]]+NIX_INSTALLER_SHA256:[[:space:]]*([0-9a-f]{64})[[:space:]]*$/\1/p' "$pins")"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$installer_sha256" =~ $sha256_pattern ]] ||
    fail "can't read NIX_VERSION and NIX_INSTALLER_SHA256 from $pins"
  NIX_VERSION="$version" NIX_INSTALLER_SHA256="$installer_sha256" GITHUB_TOKEN="$GH_TOKEN" \
    bash "$action_dir/../install-nix/install-nix.sh"
}

tools() {
  local flake out
  flake="$(cd "$action_dir/../../.." && pwd)"
  out="$(nix --extra-experimental-features 'nix-command flakes' \
    build --no-link --print-out-paths "${flake}#measure-snp-tools")"
  printf 'Tools: %s\n' "$out"
  printf 'path=%s\n' "$out" >> "$GITHUB_OUTPUT"
}

# Reads and checks firmware.json, this action's firmware pin.
load_pins() {
  local pins="$action_dir/firmware.json"
  firmware_tag="$(jq -r '.tag // empty' "$pins")"
  firmware_sha256="$(jq -r '.sha256 // empty' "$pins")"
  firmware_signer="$(jq -r '."signer-workflow" // empty' "$pins")"
  [[ -n "$firmware_tag" ]] || fail "firmware.json pins no firmware release yet"
  [[ "$firmware_tag" =~ $stable_tag ]] || fail "firmware.json: $firmware_tag is not a stable release tag"
  [[ "$firmware_sha256" =~ $sha256_pattern ]] || fail "firmware.json: malformed sha256: $firmware_sha256"
  [[ "$firmware_signer" =~ $stable_signer ]] ||
    fail "firmware.json: signer-workflow must be a repository's release.yml, got $firmware_signer"
  firmware_repo="${BASH_REMATCH[1]}"
}

verify_config() {
  [[ -f "$CONFIG_FILE" ]] || fail "config-file: not a file: $CONFIG_FILE"
  tinfoil-config "$CONFIG_FILE" || fail "config-file: rejected by tinfoil-config"

  local tag value
  IFS=$'\t' read -r tag value < <(config_scalar cvm-version)
  [[ "$tag" == '!!str' && "$value" =~ $pinned_version ]] ||
    fail "config-file: cvm-version must be a supported 0.14.x release pinned as X.Y.Z@sha256:<manifest digest>, got $value"
  image_version="${BASH_REMATCH[1]}"
  manifest_sha256="${BASH_REMATCH[3]}"
  local supported
  supported="$(jq -r --arg version "$image_version" '.[$version]."manifest-sha256" // empty' "$action_dir/supported.json")"
  [[ -n "$supported" ]] || fail "config-file: cvm-version $image_version is not supported (supported.json)"
  [[ "$manifest_sha256" == "$supported" ]] ||
    fail "config-file: cvm-version pins manifest ${manifest_sha256}, but supported.json has $supported for $image_version"

  IFS=$'\t' read -r tag value < <(config_scalar cpus)
  [[ "$tag" == '!!int' && "$value" =~ $positive_int ]] ||
    fail "config-file: cpus must be a positive decimal integer, got $value"
  cpus="$value"
  memory="$(config_count memory)"
  gpus="$(config_count gpus)"
  config_sha256="$(sha256 "$CONFIG_FILE")"
  printf 'config-file: valid; cvm-version %s, %s vCPUs, SHA-256 %s\n' "$image_version" "$cpus" "$config_sha256"
}

verify_manifest() {
  local tag="v${image_version}"
  manifest="$work/manifest.json"
  fetch "https://github.com/${image_repo}/releases/download/${tag}/tinfoil-inference-${tag}-manifest.json" "$manifest"
  check_sha256 "$manifest" "$manifest_sha256" "cvmimage $tag manifest"
  verify_attestation "$manifest" "$image_repo" "$image_signer" "refs/tags/$tag" "$slsa_predicate" \
    "cvmimage $tag manifest"

  [[ "$(jq -r .version "$manifest")" == "$tag" ]] || fail "cvmimage $tag manifest names another version"
  local field
  for field in root kernel initrd; do
    [[ "$(jq -r --arg field "$field" '.[$field]' "$manifest")" =~ $sha256_pattern ]] ||
      fail "cvmimage $tag manifest: malformed $field"
  done
  root="$(jq -r .root "$manifest")"
}

verify_kernel_initrd() {
  local tag="v${image_version}" part
  for part in kernel initrd; do
    local suffix=$part
    [[ "$part" == kernel ]] && suffix=vmlinuz
    fetch "${image_downloads}/tinfoil-inference-${tag}.${suffix}" "$work/$part"
    check_sha256 "$work/$part" "$(jq -r --arg part "$part" '.[$part]' "$manifest")" "cvmimage $tag $part"
  done
}

verify_firmware() {
  firmware="$work/$firmware_asset"
  fetch "https://github.com/${firmware_repo}/releases/download/${firmware_tag}/${firmware_asset}" "$firmware"
  check_sha256 "$firmware" "$firmware_sha256" "$firmware_tag $firmware_asset"
  verify_attestation "$firmware" "$firmware_repo" "$firmware_signer" "refs/tags/$firmware_tag" \
    "$slsa_predicate" "$firmware_tag $firmware_asset"
}

# write_documents MEASUREMENT CMDLINE DIR
write_documents() {
  local document="$3/snp-measurement.json"
  jq -n \
    --arg measurement "$1" \
    --arg firmwareRepo "$firmware_repo" \
    --arg firmwareTag "$firmware_tag" \
    --arg firmwareAsset "$firmware_asset" \
    --arg firmwareSha256 "$firmware_sha256" \
    --arg imageRepo "$image_repo" \
    --arg imageVersion "$image_version" \
    --arg manifestSha256 "$manifest_sha256" \
    --arg kernelSha256 "$(jq -r .kernel "$manifest")" \
    --arg initrdSha256 "$(jq -r .initrd "$manifest")" \
    --arg root "$root" \
    --arg cmdline "$2" \
    --arg configSha256 "$config_sha256" \
    --arg configBase64 "$(base64 -w 0 "$CONFIG_FILE")" \
    --argjson cpus "$cpus" \
    --argjson memory "$memory" \
    --argjson gpus "$gpus" \
    --arg vcpuType "$vcpu_type" \
    --arg vcpuSignature "$vcpu_signature" \
    --arg vmmType "$vmm_type" \
    --arg guestFeatures "$guest_features" \
    --slurpfile tools "$MEASURE_SNP_TOOLS/share/measure-snp/versions.json" \
    '{
      measurement: $measurement,
      firmware: {repository: $firmwareRepo, tag: $firmwareTag, asset: $firmwareAsset, sha256: $firmwareSha256},
      runtimeImage: {
        repository: $imageRepo, version: $imageVersion, manifestSha256: $manifestSha256,
        kernelSha256: $kernelSha256, initrdSha256: $initrdSha256, root: $root
      },
      cmdline: $cmdline,
      config: {sha256: $configSha256, base64: $configBase64},
      vmShape: {cpus: $cpus, vcpuType: $vcpuType, vcpuSignature: $vcpuSignature, memory: $memory, gpus: $gpus},
      launch: {mode: "snp", vmmType: $vmmType, guestFeatures: $guestFeatures, boot: "ovmf-direct"},
      tools: $tools[0]
    }' > "$document"

  # The measured fields of a measurement-allowlist entry. The allowlist adds
  # its id, HOST_DATA, policy, minimum TCB, provenance and status.
  jq '{
      measurement,
      firmware: {tag: .firmware.tag, sha256: .firmware.sha256},
      runtimeImage: .runtimeImage | {version, manifestSha256, kernelSha256, initrdSha256},
      cmdline,
      configSha256: .config.sha256,
      vmShape: .vmShape | {cpus, vcpuSignature, memory, gpus},
      guestFeatures: .launch.guestFeatures
    }' "$document" > "$3/allowlist-entry.json"
}

action() {
  : "${CONFIG_FILE:?}" "${GH_TOKEN:?}" "${MEASURE_SNP_TOOLS:?}" "${RUNNER_TEMP:?}" "${GITHUB_OUTPUT:?}"

  local firmware_tag firmware_sha256 firmware_signer firmware_repo firmware
  local image_version manifest_sha256 manifest root
  local cpus memory gpus config_sha256
  load_pins

  work="$(mktemp -d "$RUNNER_TEMP/measure-snp.XXXXXXXX")"
  trap 'rm -rf "$work"' EXIT

  # Every input is verified before anything is measured.
  verify_config
  verify_manifest
  verify_kernel_initrd
  verify_firmware

  local result measurement cmdline
  result="$(core "$firmware" "$work/kernel" "$work/initrd" "$root" "$CONFIG_FILE" "$cpus")"
  measurement="$(jq -r .measurement <<< "$result")"
  cmdline="$(jq -r .cmdline <<< "$result")"

  # Written in the work directory, then moved into place in one rename, so a
  # failed run leaves no documents behind.
  local out="${work}.out"
  mkdir "$work/out"
  write_documents "$measurement" "$cmdline" "$work/out"
  mv "$work/out" "$out"

  local document_sha256
  document_sha256="$(sha256 "$out/snp-measurement.json")"
  {
    printf 'measurement=%s\n' "$measurement"
    printf 'document=%s\n' "$out/snp-measurement.json"
    printf 'document-sha256=%s\n' "$document_sha256"
    printf 'allowlist-entry=%s\n' "$out/allowlist-entry.json"
  } >> "$GITHUB_OUTPUT"
  printf 'Measurement: %s\nDocument: %s (SHA-256 %s)\n' "$measurement" "$out/snp-measurement.json" "$document_sha256"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    # shellcheck disable=SC2016 # Backticks in the summary are Markdown.
    printf '### SEV-SNP measurement\n\n`%s`\n\n%s vCPUs, cvmimage %s, firmware %s\n' \
      "$measurement" "$cpus" "$image_version" "$firmware_tag" >> "$GITHUB_STEP_SUMMARY"
  fi
}

if [[ -n "${MEASURE_SNP_TOOLS:-}" ]]; then
  PATH="$MEASURE_SNP_TOOLS/bin:$PATH"
fi

case "${1:-}" in
  install-nix) install_nix ;;
  tools) tools ;;
  action) action ;;
  cmdline)
    (($# == 3)) || fail "usage: $0 cmdline ROOT CONFIG"
    [[ "$2" =~ $sha256_pattern ]] || fail "root hash must be 64 lowercase hex characters, got $2"
    build_cmdline "$2" "$(sha256 "$3")"
    printf '\n'
    ;;
  core)
    shift
    core "$@"
    ;;
  *)
    printf 'usage: %s install-nix|tools|action|cmdline|core\n' "$0" >&2
    exit 1
    ;;
esac

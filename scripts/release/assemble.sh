#!/usr/bin/env bash
# Assembles a release from build.yml's artifacts. Run from a checkout of the
# overlay commit that was built. Environment:
#   TRACK           stable or head
#   TAG             the release tag
#   EDK2_REF        refs/tags/edk2-stable... (stable) or master (head)
#   EDK2_REV        the edk2 commit build.yml reports it built
#   CC_SHA256, NONCC_SHA256   digests build.yml's builders agreed on
#   ARTIFACTS       directory holding the downloaded artifacts
#   DIST            output directory for the release assets
#   NOTES           output file for the release notes
#   GITHUB_*        set by the runner
# shellcheck disable=SC2016 # Backticks in the notes are Markdown.
set -euo pipefail

readonly builder=ubuntu-24.04
readonly second_builder=ubuntu-22.04

fail() {
  printf 'error: %s\n' "$1"
  exit 1
}

[[ "$TRACK" == stable || "$TRACK" == head ]] || fail "unknown TRACK: $TRACK"
mkdir -p "$DIST"

# The images: the first builder's copies, which must carry the digests both
# builders agreed on.
for variant in cc noncc; do
  dir="$ARTIFACTS/ovmf-${variant}-${builder}"
  image="$(jq -r .image "$dir/BUILD.json")"
  expected_var="${variant^^}_SHA256"
  expected="${!expected_var}"
  actual="$(sha256sum "$dir/$image" | cut -d ' ' -f 1)"
  [[ "$actual" == "$expected" ]] ||
    fail "$image is ${actual}, but the builders agreed on ${expected}"
  cp "$dir/$image" "$DIST/$image"
done

lock="$ARTIFACTS/ovmf-cc-${builder}/flake.lock"
[[ "$(jq -r .nodes.edk2.locked.rev "$lock")" == "$EDK2_REV" ]] ||
  fail "the built flake.lock doesn't pin edk2 $EDK2_REV"
cp "$lock" "$DIST/flake.lock"
cp "$ARTIFACTS"/licences/* "$DIST/"

repo_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}"
run_url="${repo_url}/actions/runs/${GITHUB_RUN_ID}"
signer_workflow="${GITHUB_WORKFLOW_REF%@*}"

field() {
  printf '%-22s %s\n' "$1:" "$2"
}

image_fields() {
  local variant="$1" build_json="$ARTIFACTS/ovmf-$1-${builder}/BUILD.json"
  field "${variant}.image" "$(jq -r .image "$build_json")"
  field "${variant}.sha256" "$(sha256sum "$DIST/$(jq -r .image "$build_json")" | cut -d ' ' -f 1)"
  field "${variant}.target" "$(jq -r .target "$build_json")"
  field "${variant}.drv" "$(jq -r .drvPath "$build_json")"
  field "${variant}.build" "build $(jq -r '.buildArgs | join(" ")' "$build_json")"
}

{
  printf '# Provenance of %s. To rebuild on x86_64-linux with Nix:\n' "$TAG"
  printf '#   git clone %s && cd %s\n' "$repo_url" "${GITHUB_REPOSITORY#*/}"
  printf '#   git checkout %s\n' "$GITHUB_SHA"
  printf '#   cp <this release>/flake.lock flake.lock   # identical for stable releases\n'
  printf '#   nix build .#ovmf-cc .#ovmf-noncc\n'
  printf '# then compare sha256sum result*/*.fd with the values below.\n\n'
  field release.tag "$TAG"
  field release.track "$TRACK"
  field release.run "$run_url"
  field overlay.repository "$repo_url"
  field overlay.commit "$GITHUB_SHA"
  field edk2.repository "https://github.com/tianocore/edk2"
  field edk2.ref "$EDK2_REF"
  field edk2.commit "$EDK2_REV"
  field edk2.narHash "$(jq -r .nodes.edk2.locked.narHash "$lock")"
  field nixpkgs.commit "$(jq -r .nodes.nixpkgs.locked.rev "$lock")"
  field nixpkgs.narHash "$(jq -r .nodes.nixpkgs.locked.narHash "$lock")"
  field flake.lock.sha256 "$(sha256sum "$lock" | cut -d ' ' -f 1)"
  for patch in firmware/edk2/patches/*.patch; do
    field patch "$(sha256sum "$patch" | cut -d ' ' -f 1)  ${patch}"
  done
  field nix "$(jq -r .nix "$ARTIFACTS/ovmf-cc-${builder}/BUILD.json")"
  field builders "${builder} (built twice), ${second_builder}; byte-identical"
  image_fields cc
  image_fields noncc
} > "$DIST/PROVENANCE.txt"

sums="$(cd "$DIST" && find . -maxdepth 1 -type f -printf '%P\0' | sort -z | xargs -0 sha256sum --)"
printf '%s\n' "$sums" > "$DIST/SHA256SUMS"

if [[ "$TRACK" == stable ]]; then
  intro="Stable release of the AMD SEV-SNP guest firmware, built from edk2 \`${EDK2_REF#refs/tags/}\`."
  source_ref="refs/tags/${TAG}"
else
  intro="HEAD build of edk2 \`master\`, for testing upstream changes ahead of the next stable release. Not for production."
  source_ref="$GITHUB_REF"
fi

{
  printf '%s\n\n' "$intro"
  printf '| Image | Variant | SHA-256 |\n|---|---|---|\n'
  printf '| `OVMF.fd` | cc: confidential guests | `%s` |\n' "$CC_SHA256"
  printf '| `OVMF-noncc.fd` | noncc: **never for confidential guests** | `%s` |\n\n' "$NONCC_SHA256"
  printf -- '- edk2: [`%s`](https://github.com/tianocore/edk2/commit/%s) (`%s`)\n' \
    "${EDK2_REV:0:12}" "$EDK2_REV" "$EDK2_REF"
  printf -- '- This repository: [`%s`](%s/commit/%s)\n' "${GITHUB_SHA:0:12}" "$repo_url" "$GITHUB_SHA"
  printf -- '- Built and verified in [run %s](%s); see `PROVENANCE.txt`\n\n' "$GITHUB_RUN_ID" "$run_url"
  printf '### Verify\n\n```sh\n'
  printf 'gh release download %s --repo %s\n' "$TAG" "$GITHUB_REPOSITORY"
  printf 'sha256sum --check SHA256SUMS\n'
  printf 'gh attestation verify OVMF.fd --repo %s \\\n' "$GITHUB_REPOSITORY"
  printf '  --signer-workflow %s \\\n' "$signer_workflow"
  printf '  --source-ref %s\n' "$source_ref"
  printf '```\n\n'
  printf 'Third-party code compiled into the images, and its licences: `THIRD-PARTY.txt`.\n'
  if [[ "$TRACK" == head ]]; then
    # Read by scripts/release/head-plan.sh to skip unchanged builds.
    printf '\n<!-- fabai-head edk2=%s overlay=%s -->\n' "$EDK2_REV" "$GITHUB_SHA"
  fi
} > "$NOTES"

cat "$DIST/PROVENANCE.txt"
cat "$DIST/SHA256SUMS"

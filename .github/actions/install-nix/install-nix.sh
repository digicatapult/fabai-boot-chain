#!/usr/bin/env bash
# Installs Nix as a multi-user daemon from the official installer, after
# checking the installer's SHA-256. Called by action.yml, which sets:
#   NIX_VERSION, NIX_INSTALLER_SHA256, GITHUB_TOKEN
# and the runner sets RUNNER_TEMP and GITHUB_PATH.
set -euo pipefail

installer="$RUNNER_TEMP/nix-install"
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  --output "$installer" \
  "https://releases.nixos.org/nix/nix-${NIX_VERSION}/install"
printf '%s  %s\n' "$NIX_INSTALLER_SHA256" "$installer" | sha256sum --check --strict -

# The sandbox is what makes builds independent of the runner image, and
# fixes the build directory (/build) that ends up in compiler output.
conf="$RUNNER_TEMP/nix.conf"
{
  printf 'experimental-features = nix-command flakes\n'
  printf 'sandbox = true\n'
  printf 'max-jobs = auto\n'
  printf 'access-tokens = github.com=%s\n' "$GITHUB_TOKEN"
} > "$conf"

sh "$installer" --daemon --yes --no-channel-add --nix-extra-conf-file "$conf"
rm -f "$installer" "$conf"

nix_bin=/nix/var/nix/profiles/default/bin
installed="$("$nix_bin/nix" --version)"
printf '%s\n' "$installed"
[[ "$installed" == "nix (Nix) ${NIX_VERSION}" ]]
[[ "$("$nix_bin/nix" config show sandbox)" == "true" ]]

printf '%s\n' "$nix_bin" >> "$GITHUB_PATH"

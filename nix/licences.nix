# The licence files shipped with every release, derived from what the build
# actually compiles rather than from a hand-kept list. Each firmware variant is
# rebuilt with an install phase that scans edk2's compiler dependency files
# (nix/licences/scan.sh); the scans are then checked against
# nix/third-party.nix (nix/licences/check.sh).
#
# The rebuilds only change the install phase, so they compile exactly what the
# released images compile, but they are separate derivations: the released
# images' derivations are untouched.
{
  lib,
  runCommand,
  jq,

  # edk2 source tree, as passed to ovmf-amdsev.nix.
  src,
  # ovmf-amdsev.nix derivations to scan.
  images,
}:

let
  manifest = import ./third-party.nix;

  scan =
    image:
    image.overrideAttrs (old: {
      pname = "${old.pname}-compiled-sources";
      installPhase = ''
        runHook preInstall
        bash ${./licences/scan.sh} "$out"
        runHook postInstall
      '';
    });

  scans = map scan images;
in
assert lib.assertMsg (lib.all (
  entry: manifest.licenceTexts ? ${entry.licence}
) (lib.attrValues manifest.submodules)) "every submodule's licence needs an entry in licenceTexts";
runCommand "ovmf-licences"
  {
    nativeBuildInputs = [ jq ];
    env.MANIFEST = builtins.toJSON manifest;
    passthru = { inherit scans; };
  }
  ''
    bash ${./licences/check.sh} "$out" ${src} ${lib.escapeShellArgs scans}
  ''

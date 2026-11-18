# Offline tests for the upstream watch (scripts/upstream-watch), for
# `nix flake check`. The scripts run against a fake gh, so no network is
# needed, and nothing here builds firmware.
{
  lib,
  runCommand,
  jq,
  yq-go,
}:

let
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../scripts/upstream-watch
      ../.github/workflows/upstream-watch.yml
      ./upstream-watch
    ];
  };
in
{
  upstream-watch =
    runCommand "upstream-watch-test"
      {
        nativeBuildInputs = [
          jq
          yq-go
        ];
        env = {
          SCRIPTS = "${src}/scripts/upstream-watch";
          WORKFLOW = "${src}/.github/workflows/upstream-watch.yml";
        };
      }
      ''
        bash ${src}/nix/upstream-watch/test.sh
        touch "$out"
      '';
}

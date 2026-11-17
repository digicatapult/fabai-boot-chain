# Lint checks for `nix flake check`. The tools come from the pinned nixpkgs, so
# results don't depend on what is installed on the runner. Nothing here builds
# firmware, so the checks also run on aarch64 machines.
{
  lib,
  runCommand,
  actionlint,
  shellcheck,
  renovate,
}:

let
  root = ../.;

  # Only the files the checks read, so unrelated edits don't re-run them.
  src = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.unions [
      ../.github
      ../renovate.json
      (lib.fileset.fileFilter (file: file.hasExt "sh") root)
    ];
  };

  check =
    name: nativeBuildInputs: script:
    runCommand "lint-${name}" { inherit nativeBuildInputs; } ''
      cd ${src}
      ${script}
      touch "$out"
    '';
in
{
  # actionlint runs ShellCheck over every `run:` block in the workflows.
  actionlint = check "actionlint" [ actionlint shellcheck ] ''
    actionlint -shellcheck=shellcheck -pyflakes= .github/workflows/*.yml
  '';

  shellcheck = check "shellcheck" [ shellcheck ] ''
    find . -name '*.sh' -print0 | sort -z | xargs -0 --verbose shellcheck
  '';

  workflow-policy = check "workflow-policy" [ ] ''
    bash nix/lint/workflow-policy.sh
    bash nix/lint/workflow-policy-test.sh
  '';

  # Validates syntax and option names only; presets are not fetched, so this
  # runs offline in the sandbox.
  renovate-config = check "renovate-config" [ renovate ] ''
    export HOME="$TMPDIR"
    renovate-config-validator --strict --no-global renovate.json
  '';
}

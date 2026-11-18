# The SEV-SNP measurement action (.github/actions/measure-snp): the tools it
# runs, and its offline tests for `nix flake check`. Nothing here builds
# firmware, so it works on aarch64 machines too.
{
  lib,
  callPackage,
  buildEnv,
  writeTextDir,
  runCommand,
  fetchurl,
  sev-snp-measure,
  gh,
  yq-go,
  jq,
}:

let
  tinfoil-config = callPackage ./tinfoil-config.nix { };

  # Recorded in every measurement document.
  versions = writeTextDir "share/measure-snp/versions.json" (
    builtins.toJSON {
      sev-snp-measure = sev-snp-measure.version;
      tinfoil-config = tinfoil-config.version;
      gh = gh.version;
      yq = yq-go.version;
    }
  );

  # Everything the action runs, besides curl and coreutils from the runner.
  tools = buildEnv {
    name = "measure-snp-tools";
    paths = [
      sev-snp-measure
      tinfoil-config
      gh
      yq-go
      jq
      versions
    ];
  };

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../.github/actions/measure-snp
      ../.github/actions/install-nix/action.yml
      ./measure-snp
    ];
  };

  # Tinfoil's published deployment of confidential-model-router v0.0.177 on
  # cvmimage v0.14.15, pinned by digest. The deployment embeds its config.
  tinfoilDeployment = fetchurl {
    url = "https://github.com/tinfoilsh/confidential-model-router/releases/download/v0.0.177/tinfoil-deployment.json";
    sha256 = "6c7e382625c6d6b0e74b408b9f5fa28b39f1157b6a4aafe0613d378aa1204452";
  };
  tinfoilManifest = fetchurl {
    url = "https://github.com/tinfoilsh/cvmimage/releases/download/v0.14.15/tinfoil-inference-v0.14.15-manifest.json";
    sha256 = "51166e30f9292cbddf28d493cac6f12d42a9b8aa75bb9a1b5cf759f02f8b7bf4";
  };
in
{
  packages = {
    inherit sev-snp-measure tinfoil-config;
    measure-snp-tools = tools;
  };

  checks.measure-snp =
    runCommand "measure-snp-test"
      {
        env = {
          ACTION_DIR = "${src}/.github/actions";
          TOOLS = tools;
          # The last 4 KiB of an AmdSevX64 OVMF.fd, from sev-snp-measure's own
          # tests: enough for it to parse the SEV metadata and measure.
          OVMF_FIXTURE = "${sev-snp-measure.src}/tests/fixtures/ovmf_AmdSev_suffix.bin";
          TINFOIL_DEPLOYMENT = tinfoilDeployment;
          TINFOIL_MANIFEST = tinfoilManifest;
        };
      }
      ''
        bash ${src}/nix/measure-snp/test.sh
        touch "$out"
      '';
}

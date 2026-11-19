# Tinfoil's config validator CLI, which the measurement action runs on every
# config before measuring it. Pinned to the tinfoil-config version that the
# supported cvmimage release compiles in (cvmimage v0.14.19 tinfoil/go.mod), so
# the config is checked by the same parser the guest uses.
#
# AGPL-3.0: built unmodified and only run in CI, never distributed.
{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:

buildGoModule (finalAttrs: {
  pname = "tinfoil-config";
  version = "0.1.23";

  src = fetchFromGitHub {
    owner = "tinfoilsh";
    repo = "tinfoil-config";
    tag = "v${finalAttrs.version}";
    hash = "sha256-vS+Yau7lxLbFJ9JLqIvYIBzSCvthRad4CyslkCf7VOs=";
  };

  vendorHash = "sha256-qT4/QJcg/q/+9INK8e9Q94QezYlrBouwviAXi5yS0vM=";

  subPackages = [ "cmd/tinfoil-config" ];

  meta = {
    description = "Validator for Tinfoil CVM configs";
    homepage = "https://github.com/tinfoilsh/tinfoil-config";
    license = lib.licenses.agpl3Only;
    mainProgram = "tinfoil-config";
  };
})

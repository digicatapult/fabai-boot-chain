{
  description = "AMD SEV-SNP guest firmware (OVMF AmdSevX64) built from upstream edk2";

  inputs = {
    # Any change to the toolchain changes the firmware bytes, and therefore the
    # launch measurement. Only move this pin together with the edk2 pin.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # edk2's metadata parser needs every submodule, including ones AmdSevX64
    # never compiles, so fetch them all.
    edk2 = {
      url = "git+https://github.com/tianocore/edk2?ref=refs/tags/edk2-stable202608&submodules=1&shallow=1";
      flake = false;
    };
  };

  outputs =
    { nixpkgs, edk2, ... }:
    let
      # Firmware digests are only comparable between builds on the same build
      # platform, so there is deliberately no cross-compilation.
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      ovmf =
        args:
        pkgs.callPackage ./nix/ovmf-amdsev.nix (
          {
            src = edk2;
            edk2Rev = edk2.rev or "dirty";
          }
          // args
        );
    in
    {
      packages.${system} = {
        ovmf-cc = ovmf { variant = "cc"; };
        ovmf-noncc = ovmf { variant = "noncc"; };
      };

      # Builds that exist only to verify the published ones; never released.
      legacyPackages.${system}.verify = {
        # Must be byte-identical to ovmf-cc: the patch is inert unless
        # NON_CC_BUILD=TRUE.
        cc-unpatched = ovmf {
          variant = "cc";
          applyNonCcPatch = false;
        };
      };
    };
}

# OvmfPkg/AmdSev/AmdSevX64.dsc from an unmodified edk2 tree, plus the overlay
# in this repository: the 1 GiB page-table PCD and the NON_CC_BUILD patch.
#
# The image is hashed into the SEV-SNP launch measurement, so everything here
# that can change its bytes (toolchain, flags, patches, compiler seed) is fixed
# by the flake lock or by this file.
{
  lib,
  stdenv,
  python3,
  nasm,
  acpica-tools,
  libuuid,

  # edk2 source tree, with all submodules.
  src,
  # Full edk2 commit, for the derivation name only.
  edk2Rev,
  # "cc": confidential, RELEASE, no debug output.
  # "noncc": DEBUG, null blob verifier; never for confidential guests.
  variant,
  # Only for verification builds: the patch must not change the cc image.
  applyNonCcPatch ? true,
}:

assert lib.assertOneOf "variant" variant [
  "cc"
  "noncc"
];
assert lib.assertMsg (
  variant == "noncc" -> applyNonCcPatch
) "the noncc variant needs the NON_CC_BUILD patch";

let
  isCc = variant == "cc";
  target = if isCc then "RELEASE" else "DEBUG";
  # GCC5 was removed upstream after edk2-stable202605; GCC is its replacement.
  toolchain = "GCC";
  image = if isCc then "OVMF.fd" else "OVMF-noncc.fd";

  buildArgs = [
    "-a"
    "X64"
    "-t"
    toolchain
    "-p"
    "OvmfPkg/AmdSev/AmdSevX64.dsc"
    "-b"
    target
    # Until upstream sets this in AmdSevX64.dsc.
    "--pcd"
    "gEfiMdeModulePkgTokenSpaceGuid.PcdUse1GPageTable=TRUE"
  ]
  ++ lib.optionals (!isCc) [ "-DNON_CC_BUILD=TRUE" ];
in
stdenv.mkDerivation {
  pname = "ovmf-amdsev-${variant}";
  version = builtins.substring 0 12 edk2Rev;

  inherit src;

  patches = lib.optionals applyNonCcPatch [
    ../firmware/edk2/patches/0001-OvmfPkg-AmdSev-add-NON_CC_BUILD.patch
  ];

  nativeBuildInputs = [
    python3
    nasm
    acpica-tools
  ];
  # BaseTools link against libuuid.
  buildInputs = [ libuuid ];

  # The cc-wrapper's hardening flags make no sense for freestanding firmware,
  # and -Wformat-security combined with OpenSSL's -Wno-format is an error under
  # edk2's -Werror.
  hardeningDisable = [ "all" ];

  env = {
    # nixpkgs seeds GCC's -frandom-seed from the output path, which differs
    # between derivations. edk2 builds with -flto, where the seed can reach the
    # image, so use a constant: builds that differ only in a patch or a flag
    # must differ only because of that patch or flag.
    NIX_OUTPATH_USED_AS_RANDOM_SEED = "fabai-ovmf";

    # tools_def resolves these through *_PREFIX variables, with a trailing slash.
    NASM_PREFIX = "${nasm}/bin/";
    IASL_PREFIX = "${acpica-tools}/bin/";
    PYTHON_COMMAND = lib.getExe python3;
  };

  configurePhase = ''
    runHook preConfigure

    export WORKSPACE="$PWD"
    export CONF_PATH="$WORKSPACE/Conf"
    patchShebangs --build BaseTools

    # Grub.inf lists grub.efi as a binary, and the DSC's PREBUILD script builds
    # GRUB unless grub.efi exists and is newer than its inputs. An empty file,
    # as in Ubuntu's ovmf-amdsev, keeps GRUB out of the image; it is only
    # needed for firmware-stage LUKS unlock with an SEV secret.
    : > OvmfPkg/AmdSev/Grub/grub.efi

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    # Host tools only; -Wno-error because newer GCC releases warn about code in
    # tools AmdSevX64 does not use (EfiRom). Warnings do not change codegen.
    make -C BaseTools/Source/C -j"$NIX_BUILD_CORES" EXTRA_OPTFLAGS=-Wno-error

    set +u
    source ./edksetup.sh BaseTools
    set -u

    build ${lib.escapeShellArgs buildArgs} -n "$NIX_BUILD_CORES"

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm444 "Build/AmdSev/${target}_${toolchain}/FV/OVMF.fd" "$out/${image}"

    runHook postInstall
  '';

  # Nothing to patch or strip in a firmware volume.
  dontFixup = true;

  passthru = {
    inherit
      variant
      target
      toolchain
      buildArgs
      image
      ;
  };

  meta = {
    description = "AMD SEV-SNP guest firmware (OVMF AmdSevX64), ${variant} variant";
    homepage = "https://github.com/digicatapult/fabai-boot-chain";
    license = lib.licenses.bsd2Patent;
    platforms = [ "x86_64-linux" ];
  };
}

# Boots a firmware image under QEMU, with a test kernel and initrd that print a
# marker from /init.
#   noncc: must boot the kernel, on a CPU with 1 GiB pages, and DxeIpl must
#          report 1 GiB page tables.
#   cc:    must refuse to boot. Without SEV-SNP there is no hashes table, so
#          the blob verifier denies the kernel and BDS gives up. It must also
#          stay silent on QEMU's debug console, as a RELEASE build.
# QEMU, the kernel and busybox all come from the pinned nixpkgs.
# Two derivations: `run` boots and records the logs and a verdict, and this one
# fails unless the verdict is PASS. `run` is exposed as `passthru.run`.
{
  stdenv,
  runCommand,
  makeInitrd,
  writeScript,
  qemu_test,
  linuxPackages,
  pkgsStatic,

  # An ovmf-amdsev.nix derivation.
  firmware,
}:

let
  marker = "FABAI-BOOT-TEST-INIT-REACHED";

  # writeScript, unlike replaceVars, leaves the shebang alone: /bin/sh must
  # resolve inside the initrd, not to the build machine's bash.
  init = writeScript "init" (
    builtins.replaceStrings [ "@marker@" ] [ marker ] (builtins.readFile ./boot-test/init.sh)
  );

  initrd = makeInitrd {
    contents = [
      {
        object = init;
        symlink = "/init";
      }
      {
        object = "${pkgsStatic.busybox}/bin";
        symlink = "/bin";
      }
    ];
  };

  kernel = linuxPackages.kernel;

  # Boots once and records the logs and a verdict. It succeeds whatever the
  # verdict, so CI can upload the logs when the test fails.
  run = runCommand "ovmf-boot-run-${firmware.variant}" {
    env = {
      QEMU = "${qemu_test}/bin/qemu-system-x86_64";
      FIRMWARE = "${firmware}/${firmware.image}";
      KERNEL = "${kernel}/${stdenv.hostPlatform.linux-kernel.target}";
      INITRD = "${initrd}/initrd";
      EXPECT = if firmware.variant == "cc" then "refuse" else "boot";
      MARKER = marker;
      # A cap, not a wait: the test ends as soon as the outcome is clear.
      TIMEOUT_SECONDS = "600";
    };

    meta.platforms = [ "x86_64-linux" ];
  } ''bash ${./boot-test/run.sh} "$out"'';
in
# The test itself: fails unless the verdict is PASS.
runCommand "ovmf-boot-test-${firmware.variant}"
  {
    passthru = { inherit run; };
    meta.platforms = [ "x86_64-linux" ];
  }
  ''
    bash ${./boot-test/check.sh} ${run} "$out"
  ''

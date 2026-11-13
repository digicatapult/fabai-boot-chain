# Notice

fabai-boot-chain, copyright 2026 Digital Catapult

This repository's own files are licensed under the Apache License, Version 2.0
(see [`LICENSE`](LICENSE)). The exceptions are:

- **Directories with their own `LICENSE` file.** These hold material derived
  from third-party projects and keep the third party's licence.
- **Firmware images published in this repository's releases.** They are built
  from [tianocore/edk2](https://github.com/tianocore/edk2) and are distributed
  under edk2's licences (BSD-2-Clause-Patent, plus the licences of the bundled
  libraries it compiles in), not under Apache-2.0.

## Acknowledgements

No code is copied from these projects, but this repository's design builds on
their work:

- [tinfoilsh/edk2](https://github.com/tinfoilsh/edk2): the non-confidential
  `NON_CC_BUILD` variant of `OvmfPkg/AmdSev/AmdSevX64.dsc`, and enabling
  `PcdUse1GPageTable` so that SEV-SNP guests whose RAM plus 64-bit PCI window
  exceeds 1 TiB can boot.
- [verda-cloud/edk2](https://github.com/verda-cloud/edk2) (`amdsev-large-bars`
  branch): reproducible `AmdSevX64` builds with a Nix-pinned toolchain,
  including the need to disable Nix's default compiler hardening flags, and
  hardware testing of the same `PcdUse1GPageTable` setting.

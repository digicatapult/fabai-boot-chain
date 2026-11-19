# Notice

fabai-boot-chain, copyright 2026 Digital Catapult

This repository's own files are licensed under the Apache License, Version 2.0
(see [`LICENSE`](LICENSE)). The exceptions are:

- **Directories with their own `LICENSE` file.** These hold material derived
  from third-party projects and keep the third party's licence.
- **Firmware images published in this repository's releases.** They are built
  from [tianocore/edk2](https://github.com/tianocore/edk2) and are distributed
  under edk2's licences (BSD-2-Clause-Patent, plus the licences of the bundled
  libraries it compiles in, such as OpenSSL's Apache-2.0), not under
  Apache-2.0. Each release lists the third-party code in its images in
  `THIRD-PARTY.txt` and ships the licence texts as `LICENSE-*.txt`.

## Third-party material

| Path | Source | Commit | Licence |
|------|--------|--------|---------|
| [`firmware/edk2/patches/0001-OvmfPkg-AmdSev-add-NON_CC_BUILD.patch`](firmware/edk2/patches/0001-OvmfPkg-AmdSev-add-NON_CC_BUILD.patch) | [tinfoilsh/edk2](https://github.com/tinfoilsh/edk2), rebased onto `edk2-stable202608` | [`97c3701c0f`](https://github.com/tinfoilsh/edk2/commit/97c3701c0f497c9677bf69ea19da66415412be60) | BSD-2-Clause-Patent ([`firmware/edk2/LICENSE`](firmware/edk2/LICENSE)) |

## Third-party tools

The SEV-SNP measurement action ([`.github/actions/measure-snp`](.github/actions/measure-snp))
runs these tools, built from [`flake.lock`](flake.lock)'s pins. None is copied
into this repository, modified or distributed with its releases:

| Tool | Source | Version | Licence |
|------|--------|---------|---------|
| `tinfoil-config` CLI | [tinfoilsh/tinfoil-config](https://github.com/tinfoilsh/tinfoil-config), built from source by [`nix/tinfoil-config.nix`](nix/tinfoil-config.nix) | v0.1.23 | AGPL-3.0 |
| `sev-snp-measure` | [virtee/sev-snp-measure](https://github.com/virtee/sev-snp-measure), from nixpkgs | 0.0.12 | Apache-2.0 |
| `yq` | [mikefarah/yq](https://github.com/mikefarah/yq), from nixpkgs | 4.53.2 | MIT |

`tinfoil-config` only validates configs in CI. It is run unmodified and never
distributed, so the action's own files stay Apache-2.0.

## Acknowledgements

Apart from the material listed above, no code is copied from these projects, but
this repository's design builds on their work:

- [tinfoilsh/edk2](https://github.com/tinfoilsh/edk2): the non-confidential
  `NON_CC_BUILD` variant of `OvmfPkg/AmdSev/AmdSevX64.dsc`, and enabling
  `PcdUse1GPageTable` so that SEV-SNP guests whose RAM plus 64-bit PCI window
  exceeds 1 TiB can boot.
- [verda-cloud/edk2](https://github.com/verda-cloud/edk2) (`amdsev-large-bars`
  branch): reproducible `AmdSevX64` builds with a Nix-pinned toolchain,
  including the need to disable Nix's default compiler hardening flags, and
  hardware testing of the same `PcdUse1GPageTable` setting.

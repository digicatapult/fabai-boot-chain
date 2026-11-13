# fabai-boot-chain

This repository provides release engineering for the FabAI confidential VM boot
chain, including the AMD SEV-SNP guest firmware (OVMF) built from unmodified
[tianocore/edk2](https://github.com/tianocore/edk2) source and published with
Sigstore build provenance.

## Forking edk2?

A confidential guest's launch measurement covers the firmware image, so anyone
verifying a measurement is trusting the firmware source. With a fork, a reviewer
has to audit the fork's history. Here they audit an upstream tag plus the two
changes below. Upstream security fixes then arrive by moving a pin, not by
rebasing a fork.

Both changes affect `OvmfPkg/AmdSev/AmdSevX64.dsc`:

1. **1 GiB page tables:** `PcdUse1GPageTable=TRUE`. Without this, SEV-SNP guests whose RAM plus 64-bit PCI window exceeds 1 TiB fail to boot. Multi-GPU guests reach that limit even with modest RAM. Forkless build option: `--pcd gEfiMdeModulePkgTokenSpaceGuid.PcdUse1GPageTable=TRUE`.
2. **Non-confidential variant:** `NON_CC_BUILD=TRUE`, which replaces the SEV hash verifier with the null verifier. This is one patch applied at build time. CI also checks it against upstream `master`, so conflicts surface before the next stable upstream release.

## Firmware variants

| Variant | File            | Build type                 | For                               |
|---------|-----------------|----------------------------|-----------------------------------|
| cc      | `OVMF.fd`       | `RELEASE`, no debug output | Confidential (SEV-SNP) guests     |
| noncc   | `OVMF-noncc.fd` | `DEBUG`                    | Non-confidential test guests only |

Confidential firmware is a release-only build because debugging logs to the
serial port or to QEMU's debug console port (`0x402`), and the host can read
both. That log reveals memory layout and boot timing to the party a confidential
guest is meant to be protected from.

> [!IMPORTANT]
> Never use `OVMF-noncc.fd` for a confidential guest. It boots whatever kernel,
> initrd and command line the host supplies, without checking them against the
> hashes covered by the launch measurement.

## Release tracks

| Track  | Built from                | Tag                           | When                                                                                                        |
|--------|---------------------------|-------------------------------|-------------------------------------------------------------------------------------------------------------|
| Stable | Latest `edk2-stable*` tag | `ovmf-edk2-stableYYYYMM-rN`   | Each upstream stable release (roughly quarterly). `rN` increments when only this repository's build changes |
| HEAD   | edk2 `master`             | `ovmf-head-YYYYMMDD-<commit>` | Daily, if upstream has changed. Published as a prerelease; the last 30 are kept                             |

Every release will contain both variants, `SHA256SUMS`, and a `PROVENANCE.txt`
recording the upstream commit, this repository's commit, the toolchain lock and
the build flags. Every image will carry SLSA build provenance, which
`gh attestation verify` can check.

Only stable `OVMF.fd` images are intended for production. HEAD builds pick up
upstream security fixes as they land, for testing ahead of the next stable
release.

## Reproducibility

The toolchain is pinned with a Nix flake: [`flake.lock`](flake.lock) fixes the
edk2 commit (with its submodules) and the nixpkgs revision that supplies the
compiler, NASM, iasl and Python. Publishing binaries is mere convenience;
rebuilding is what makes them verifiable.

To rebuild on an `x86_64-linux` machine with Nix (flakes enabled, sandbox on):

```sh
git clone https://github.com/digicatapult/fabai-boot-chain
cd fabai-boot-chain
git checkout <release tag>
nix build .#ovmf-cc        # or .#ovmf-noncc
sha256sum result/*.fd
```

Compare the digest with the release's `SHA256SUMS`. Digests change whenever the
edk2 or nixpkgs pin moves, so each release records its own rather than this
README.

CI builds each variant on two runner images, with a second built from scratch on
one of them, and fails unless all three images are identical. It also checks
that the non-confidential patch leaves `OVMF.fd` byte-for-byte unchanged.

## Related repositories

- [digicatapult/fabai-measure-image-action](https://github.com/digicatapult/fabai-measure-image-action):
  a fork of [tinfoilsh/measure-image-action](https://github.com/tinfoilsh/measure-image-action)
  that will compute launch measurements against these firmware releases.

## Licence

This repository's own files are Apache-2.0 ([`LICENSE`](LICENSE)). Material
derived from third-party projects keeps its own licence, and released firmware
images are distributed under edk2's licences. See [`NOTICE.md`](NOTICE.md).

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
| HEAD   | edk2 `master`             | `ovmf-head-YYYYMMDD-<commit>` | Daily, if upstream or this repository has changed. Published as a prerelease; the last 30 are kept          |

Every release contains:

| Asset                                             | Contents                                                                                                                                             |
|---------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------|
| `OVMF.fd`, `OVMF-noncc.fd`                        | The two variants                                                                                                                                     |
| `SHA256SUMS`                                      | Digests of every other asset                                                                                                                         |
| `PROVENANCE.txt`                                  | The edk2 ref and commit, this repository's commit, the nixpkgs commit, the `flake.lock` digest, the patches, the build flags and the Nix derivations |
| `flake.lock`                                      | The lock the images were built from. For HEAD releases it pins edk2 `master` instead of the stable tag                                               |
| `THIRD-PARTY.txt`, `SOURCES.txt`, `LICENSE-*.txt` | The third-party code compiled into the images, every compiled file with its SPDX licence, and the licence texts                                      |

Both images carry SLSA build provenance. Each track signs with its own
workflow, so a check for a stable image also rejects HEAD images:

```sh
gh attestation verify OVMF.fd --repo digicatapult/fabai-boot-chain \
  --signer-workflow digicatapult/fabai-boot-chain/.github/workflows/release.yml \
  --source-ref refs/tags/<release tag>
```

HEAD images are signed by `release-head.yml`, with source ref `refs/heads/main`.

### Making a stable release

1. Update `edk2` in `flake.nix` to the new `edk2-stable*` tag, and run
   `nix flake lock`. Move the nixpkgs pin at the same time, if at all. Merge
   the change to `main` once CI is green.
2. Push a tag `ovmf-<edk2 tag>-r1` on that `main` commit. For a rebuild of the
   same edk2 release with changes in this repository only, increment `rN`.
3. [`release.yml`](.github/workflows/release.yml) checks that the tag matches
   the edk2 commit in `flake.lock` and is on `main`, runs the verified build
   ([`build.yml`](.github/workflows/build.yml)), then waits for approval in the
   `release` environment before attesting and publishing.

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
README. For a HEAD release, first replace `flake.lock` with the release's own.

CI builds each variant on two runner images, with a second built from scratch on
one of them, and fails unless all three images are identical. It also checks
that the non-confidential patch leaves `OVMF.fd` byte-for-byte unchanged.

## Testing

CI boots both images in QEMU (`nix build .#verify.boot-cc` and
`.#verify.boot-noncc`), with a test kernel and initrd whose `/init` prints a
marker. QEMU emulates the CPU (TCG, `-cpu max`), so the test doesn't depend on
the runner's KVM support, and the guest CPU always offers 1 GiB pages.

- `OVMF-noncc.fd` must reach `/init`, and its debug log must show 1 GiB page
  tables.
- `OVMF.fd` must refuse the kernel. Without SEV-SNP there is no hashes table
  to check the kernel against, so it stops at "No bootable option was found".
  It must also write nothing to QEMU's debug console.

The serial and debug console logs are uploaded as `boot-logs-<variant>`
whether the test passes or fails: `.#verify.boot-run-<variant>` boots and
records the logs with a verdict, and `.#verify.boot-<variant>` fails unless
that verdict is PASS.

CI also rebuilds both variants to list every file the compiler read
(`nix build .#verify.licences`). It fails if an edk2 submodule is compiled in,
or a compiled file carries an SPDX licence, that
[`nix/third-party.nix`](nix/third-party.nix) doesn't cover. The release assets'
licence texts come from that list, so they can't silently fall behind an edk2
update. Today the only compiled submodule is OpenSSL.

`nix flake check` runs actionlint, ShellCheck, a check that every action is
pinned to a full commit SHA and every workflow starts from `permissions: {}`,
and the Renovate config validator. It doesn't build firmware, so it also runs
on `aarch64-linux`. The pinning check reads `uses:` line by line, so it accepts
only block style (`uses: <ref>`) and rejects any other form, such as
`{ uses: … }`, rather than skip it.

A separate CI job checks that the patches still apply to edk2 `master`. That
job is advisory: it can fail because of upstream changes alone, and it gives
early warning before the next stable release.

## Dependency updates

[Renovate](renovate.json) uses Digital Catapult's shared preset, with stricter
rules for this repository:

- Action updates wait 7 days and are never automerged.
- Renovate opens PRs for new Nix releases used by
  [`install-nix`](.github/actions/install-nix/action.yml), but can't update the
  installer's SHA-256. Update `NIX_INSTALLER_SHA256` in the same PR; CI fails
  until it matches.
- `flake.lock` is only updated by hand. A new nixpkgs changes the compiler, so
  it changes the firmware bytes and the launch measurement. It moves only
  together with an edk2 stable release.

## Related repositories

- [digicatapult/fabai-measure-image-action](https://github.com/digicatapult/fabai-measure-image-action):
  a fork of [tinfoilsh/measure-image-action](https://github.com/tinfoilsh/measure-image-action)
  that will compute launch measurements against these firmware releases.

## Licence

This repository's own files are Apache-2.0 ([`LICENSE`](LICENSE)). Material
derived from third-party projects keeps its own licence, and released firmware
images are distributed under edk2's licences. See [`NOTICE.md`](NOTICE.md).

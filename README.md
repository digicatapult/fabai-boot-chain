# fabai-boot-chain

This repository provides release engineering for the FabAI confidential VM boot
chain, including the AMD SEV-SNP guest firmware (OVMF) built from unmodified
[tianocore/edk2](https://github.com/tianocore/edk2) source and published with
Sigstore build provenance, and the action that computes a deployment's launch
measurement on that firmware ([Measuring a deployment](#measuring-a-deployment)).

## Forking edk2

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
| ------- | --------------- | -------------------------- | --------------------------------- |
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
| ------ | ------------------------- | ----------------------------- | ----------------------------------------------------------------------------------------------------------- |
| Stable | Latest `edk2-stable*` tag | `ovmf-edk2-stableYYYYMM-rN`   | Each upstream stable release (roughly quarterly). `rN` increments when only this repository's build changes |
| HEAD   | edk2 `master`             | `ovmf-head-YYYYMMDD-<commit>` | Daily, if upstream or this repository changed. A prerelease; the last 30 are kept                           |

Every release contains:

| Asset                                             | Contents                                                                                                                                             |
| ------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
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

To rebuild under ARM64 (MacOS/Linux), follow the processes as described [below](#building-on-non-amd64-hosts).

Compare the digest with the release's `SHA256SUMS`. Digests change whenever the
edk2 or nixpkgs pin moves, so each release records its own rather than this
README. For a HEAD release, first replace `flake.lock` with the release's own.

CI builds each variant on two runner images, with a second built from scratch on
one of them, and fails unless all three images are identical. It also checks
that the non-confidential patch leaves `OVMF.fd` byte-for-byte unchanged.

### Building on non-AMD64 hosts

The firmware is only defined for `x86_64-linux`, so on a Mac (including with
Nix installed natively) or ARM64 Linux, `nix build .#ovmf-cc` fails with
`does not provide attribute 'packages.<your system>.ovmf-cc'`. That is
deliberate: a cross-compiler is a different compiler binary, so its image
wouldn't match the release. Instead, run the same `x86_64-linux` build under
emulation.

On a Mac with Apple silicon, use Docker Desktop with **Use Rosetta for
x86_64/amd64 emulation on Apple Silicon** turned on (Settings, General), and
start Nix in an amd64 container:

```sh
docker run --rm -it --platform linux/amd64 --privileged \
  nixos/nix:2.35.6@sha256:b49cb33f3a7e5cf3933ad8774529de0e3807ec5cf54987aa7ccdfb49f2fc55ed
```

Inside it:

```sh
git clone https://github.com/digicatapult/fabai-boot-chain
cd fabai-boot-chain
git checkout <release tag>
# HEAD releases only:
# curl -fsSLo flake.lock https://github.com/digicatapult/fabai-boot-chain/releases/download/<release tag>/flake.lock
nix --extra-experimental-features 'nix-command flakes' \
  --option sandbox true --option filter-syscalls false \
  build .#ovmf-cc .#ovmf-noncc
sha256sum result*/*.fd
```

- The image turns off flakes and the build sandbox; the options turn them back
  on, and `--privileged` lets Nix create the sandbox. x86_64 syscall filters
  can't be loaded under Rosetta, so `filter-syscalls false` drops them. They
  only stop a build creating setuid files or extended attributes, and don't
  change the image.
- The Nix version doesn't change the image either, since the toolchain comes
  from `flake.lock`. The tag above is the one CI installed when this was
  written.
- Before the long build, `nix eval --raw .#packages.x86_64-linux.ovmf-cc.drvPath`
  (with the same options) should print the release's `cc.drv` from
  `PROVENANCE.txt`. If it matches, the sources, patches and toolchain are the
  ones CI used.
- On a 10-core Apple silicon Mac, both images took about 20 minutes, 5 of them
  fetching edk2. They matched `ovmf-head-20261118-556dcfb466e9`'s
  `SHA256SUMS`.

On ARM64 Linux, the same container works once Docker can run amd64 images
through QEMU user emulation (binfmt). QEMU can be slower than Rosetta.

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
update. Today the only compiled submodule is OpenSSL, and only in `OVMF.fd`:
it comes in with the SEV hash verifier, which `OVMF-noncc.fd` replaces.

`nix flake check` runs actionlint, ShellCheck, a check that every action is
pinned to a full commit SHA and every workflow starts from `permissions: {}`,
the Renovate config validator, and the [upstream watch](#upstream-watch)'s
tests against a fake `gh`. It doesn't build firmware, so it also runs
on `aarch64-linux`. The pinning check reads `uses:` line by line, so it accepts
only block style (`uses: <ref>`) and rejects any other form, such as
`{ uses: … }`, rather than skip it. CI builds the same checks without
evaluating the firmware packages, so the lint job never needs the edk2 source.

Fetching edk2 with its submodules takes 5-6 minutes, so CI fetches at most once
per run, in the `Flake inputs` job, and every other job imports the inputs from
there. `flake.lock`'s own inputs also go into the Actions cache, keyed by the
SHA-256 of `flake.lock`, so a later run with the same lock fetches nothing. A
run can only restore entries saved on its own branch or on `main`, so
[`cache.yml`](.github/workflows/cache.yml) keeps an entry for `main`'s
`flake.lock`: it runs when `flake.lock` changes on `main`, by hand, and twice a
week, because entries unused for 7 days are evicted. Branch and tag runs with
`main`'s lock then hit it, and a branch that changes `flake.lock` fetches once,
then hits its own entry. HEAD builds re-lock edk2 to `master`, so they always
fetch, and pass the inputs to their other jobs as a one-day artifact rather
than a cache entry. The sources are content-addressed by the `narHash` values
in `flake.lock`, so Nix refuses any copy whose contents don't match the lock.

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

## Measuring a deployment

A client accepts a confidential guest only if its SEV-SNP `MEASUREMENT` is on
FabAI's allowlist. The [`measure-snp`](.github/actions/measure-snp/action.yml)
composite action computes that value for a deployment of
[tinfoilsh/cvmimage](https://github.com/tinfoilsh/cvmimage) 0.14.x on this
repository's `cc` firmware. It verifies every input before it measures:

| Input                  | Where from                                                                                | Checks                                                                                                                                                                                 |
| ---------------------- | ----------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Config                 | `config-file` input                                                                       | `tinfoil-config` v0.1.23 (the version `cvmimage` 0.14.19 runs); `cvm-version` pinned as `X.Y.Z@sha256:<manifest SHA-256>` and listed in `supported.json`; `cpus` is a positive decimal |
| Runtime image manifest | `cvmimage` release `v<X.Y.Z>`                                                             | SHA-256 equals the config's pin; attested by `tinfoilsh/cvmimage`'s `release.yml` at `refs/tags/v<X.Y.Z>`                                                                              |
| Kernel, initrd         | `images.tinfoil.sh/cvm`                                                                   | SHA-256 equals the manifest's                                                                                                                                                          |
| Firmware               | This repository's release in [`firmware.json`](.github/actions/measure-snp/firmware.json) | `OVMF.fd` only; SHA-256 equals the pin; attested by `release.yml` at the release tag                                                                                                   |

Every attestation check also requires a GitHub-hosted runner and the SLSA
provenance predicate. If any check fails, the run stops before measuring and
writes nothing. The firmware is not an input: it is always the stable `cc`
release pinned in `firmware.json`, so a caller can't measure `OVMF-noncc.fd` or
a HEAD build. `sev-snp-measure`, `tinfoil-config`, `gh` and `yq` come from this
repository's flake at the action's commit.

The outputs are `measurement`, `document` (the path of `snp-measurement.json`),
`document-sha256` and `allowlist-entry` (the measured fields of an allowlist
entry). The action doesn't sign. The calling job attests the document, so each
deployment repository's release workflow is the signer, with the predicate
type
[`snp-launch-measurement-v1`](docs/predicates/snp-launch-measurement-v1.md),
which also defines the document's fields.

A deployment repository's release workflow, measuring one VM shape per config
file:

```yaml
jobs:
  measure:
    runs-on: ubuntu-24.04
    permissions:
      contents: write # upload the release assets
      id-token: write # attest
      attestations: write # attest
    steps:
      - name: Checkout
        uses: actions/checkout@<full SHA> # vX
        with:
          persist-credentials: false

      - name: Measure
        id: measure
        uses: digicatapult/fabai-boot-chain/.github/actions/measure-snp@<full SHA>
        with:
          config-file: tinfoil-config.yml

      - name: Attest measurement
        uses: actions/attest@1e69f48acb82d1966a394da916b4c1698aa569d6 # v4.2.2
        with:
          subject-path: ${{ steps.measure.outputs.document }}
          predicate-type: https://github.com/digicatapult/fabai-boot-chain/blob/main/docs/predicates/snp-launch-measurement-v1.md
          predicate-path: ${{ steps.measure.outputs.document }}

      - name: Publish
        run: gh release upload "$GITHUB_REF_NAME" "$DOCUMENT" "$ALLOWLIST_ENTRY"
        env:
          GH_TOKEN: ${{ github.token }}
          DOCUMENT: ${{ steps.measure.outputs.document }}
          ALLOWLIST_ENTRY: ${{ steps.measure.outputs.allowlist-entry }}
```

The measurement only matches a guest that the host launches the way it
assumes:

- `-cpu EPYC-v4`, or another family 23, model 1, stepping 2 CPU model. Never
  `-cpu host` or `EPYC-Genoa`: the vCPU signature is measured into every VMSA.
- `-smp` equal to the config's `cpus`. Each vCPU count is its own allowlist
  entry.
- `-object sev-snp-guest,…,kernel-hashes=on` without IGVM, so the guest
  features are `0x1`, and `-bios OVMF.fd -kernel … -initrd … -append …` with
  exactly the document's `cmdline`.

Updating the pins:

- **New firmware release:** after a stable release, a PR sets its tag and the
  `OVMF.fd` SHA-256 from its `SHA256SUMS` in `firmware.json`. Callers then
  move to that commit.
- **New `cvmimage` 0.14.x release:** a PR adds the version and its manifest
  SHA-256 to `supported.json`, after checking that its cmdline template is
  unchanged. It moves `nix/tinfoil-config.nix` to the `tinfoil-config`
  version the release compiles in (`tinfoil/go.mod`), and the regression
  test to a published Tinfoil deployment on that release. It removes any
  earlier version that should no longer be measured: only 0.14.19 is listed,
  because earlier kernels lack the fix for CVE-2026-98432. 0.15 and later
  boot IGVM, which this action doesn't measure.

The offline tests (`nix build .#checks.<system>.measure-snp`) run the action
against fixtures, with fake `gh` and `curl`. Each failed check must stop the
run before `sev-snp-measure` is called. They also check that the cmdline
template reproduces a published Tinfoil deployment's. CI's advisory
`Measurement regression` job reproduces Tinfoil's published measurement for
`confidential-model-router` v0.0.178 (`cvmimage` 0.14.19), and the FabAI vector for the `cc` image
it built ([`nix/measure-snp/regression.sh`](nix/measure-snp/regression.sh)).

## Upstream watch

Security fixes reach the firmware only when the edk2 pin moves, so
[`upstream-watch.yml`](.github/workflows/upstream-watch.yml) checks
[tianocore/edk2](https://github.com/tianocore/edk2) daily and raises an issue
for each event that may need a release
([`scripts/upstream-watch`](scripts/upstream-watch/watch.sh)). It needs only
`issues: write`, and never opens PRs, pushes or tags. Watch this repository
to be notified.

| Label | Raised when | One issue per |
|---|---|---|
| `edk2-release` | An `edk2-stable*` tag, including `.NN` point releases, is newer than `flake.lock`'s pin | Tag. The issue is a checklist: the `flake.nix` edit, the nixpkgs move if a matching NixOS release exists, the release tag to push, and the measurement action's pin and FabAI vector |
| `edk2-advisory` | A `tianocore/edk2` security advisory published since 2026-10-01 | Advisory. Later updates to it are commented on the issue, which is reopened if it was closed |
| `edk2-sev-commits` | Commits on edk2 `master` touch `OvmfPkg/AmdSev/`, `OvmfPkg/Library/BaseMemEncryptSevLib/` or `OvmfPkg/Library/CcExitLib/` and aren't in the pinned tag. SEV mitigations can land without an advisory | Pinned tag. New commits are commented on it, reopening it if it was closed, and the watcher closes it when the pin moves |

Every issue also carries `upstream-watch`. Advisory issues say whether any
file of the affected edk2 package is compiled into the newest stable
release's images, from its `SOURCES.txt`: none means the advisory is unlikely
to apply. To triage one, tick its checklist, close it with the verdict as a
comment, and add the `triaged` label. When the watcher reports an update on a
closed issue, it reopens the issue and removes `triaged`, so it's back on the
open list to triage again.

Each issue body ends with a hidden `<!-- upstream-watch … -->` marker,
which is how the watcher knows what it has already raised, so don't edit or
delete it. Editing that line can only cause a duplicate issue. The watcher
finds its issues by author (`github-actions[bot]`), not by label, so
relabelling one is safe. Issues here are public, so it ignores markers in
issues and comments anyone else wrote.

Run it by hand from the Actions tab with **dry run** set to print what it
would raise without writing anything. GitHub disables scheduled workflows in
public repositories after 60 days without activity; if that happens,
re-enable `Upstream watch`, `Release HEAD`, and `Cache` there.

## Related repositories

- [tinfoilsh/cvmimage](https://github.com/tinfoilsh/cvmimage): the runtime
  image that [`measure-snp`](#measuring-a-deployment) measures.

## Licence

This repository's own files are Apache-2.0 ([`LICENSE`](LICENSE)). Material
derived from third-party projects keeps its own licence, and released firmware
images are distributed under edk2's licences. See [`NOTICE.md`](NOTICE.md).

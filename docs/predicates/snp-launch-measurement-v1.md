# Predicate type: SEV-SNP launch measurement, v1

```text
https://github.com/digicatapult/fabai-boot-chain/blob/main/docs/predicates/snp-launch-measurement-v1.md
```

This URI is the predicate type of an [in-toto](https://github.com/in-toto/attestation)
statement saying that a deployment repository's release workflow computed
the SEV-SNP launch measurement of one confidential VM shape: a
`tinfoilsh/cvmimage` 0.14.x runtime image with one config, booted directly by
QEMU on a stable FabAI `cc` firmware release (`OVMF.fd`).

The predicate is the measurement document that the
[`measure-snp`](../../.github/actions/measure-snp/action.yml) action writes
(`snp-measurement.json`). The statement's subject is that same file, so a
verifier can check a copy of the document against the attestation, and the
Sigstore bundle alone carries everything an allowlist entry needs.

## Producing it

The action doesn't sign. The calling job attests its `document` output, so the
signer identity is the deployment repository's release workflow:

```yaml
- name: Attest measurement
  uses: actions/attest@1e69f48acb82d1966a394da916b4c1698aa569d6 # v4.2.2
  with:
    subject-path: ${{ steps.measure.outputs.document }}
    predicate-type: https://github.com/digicatapult/fabai-boot-chain/blob/main/docs/predicates/snp-launch-measurement-v1.md
    predicate-path: ${{ steps.measure.outputs.document }}
```

## Verifying it

```sh
gh attestation verify snp-measurement.json \
  --repo <deployment repository> \
  --signer-workflow <deployment repository>/.github/workflows/<release workflow> \
  --source-ref refs/tags/<release tag> \
  --predicate-type https://github.com/digicatapult/fabai-boot-chain/blob/main/docs/predicates/snp-launch-measurement-v1.md \
  --deny-self-hosted-runners
```

A verifier then uses the statement's predicate, or the file it has just
checked, which is the same JSON.

## Fields

All digests are SHA-256, as 64 lowercase hex characters.

| Field | Type | Meaning |
|---|---|---|
| `measurement` | string | The expected SNP `MEASUREMENT`, 96 lowercase hex characters (48 bytes) |
| `firmware.repository` | string | `digicatapult/fabai-boot-chain` |
| `firmware.tag` | string | The stable release, `ovmf-edk2-stableYYYYMM[.NN]-rN`. Never a HEAD prerelease |
| `firmware.asset` | string | Always `OVMF.fd`, the `cc` image. Never `OVMF-noncc.fd` |
| `firmware.sha256` | string | Digest of `OVMF.fd` |
| `runtimeImage.repository` | string | `tinfoilsh/cvmimage` |
| `runtimeImage.version` | string | The `cvmimage` release, `0.14.x`, without the `v` |
| `runtimeImage.manifestSha256` | string | Digest of the release's `tinfoil-inference-v<version>-manifest.json`, as pinned in the config's `cvm-version` |
| `runtimeImage.kernelSha256` | string | Digest of the kernel, from the manifest |
| `runtimeImage.initrdSha256` | string | Digest of the initrd, from the manifest |
| `runtimeImage.root` | string | The dm-verity root hash, from the manifest |
| `cmdline` | string | The exact kernel command line measured, including `roothash=` and `tinfoil-config-hash=` |
| `config.sha256` | string | Digest of the config file's raw bytes, as in `cmdline` |
| `config.base64` | string | The config file's raw bytes, base64-encoded |
| `vmShape.cpus` | number | vCPU count. The measurement depends on it |
| `vmShape.vcpuType` | string | `EPYC-v4`: the QEMU CPU model the host must use |
| `vmShape.vcpuSignature` | string | `0x800f12` (family 23, model 1, stepping 2), measured into each VMSA |
| `vmShape.memory` | number or null | The config's `memory`, for information. Not measured |
| `vmShape.gpus` | number or null | The config's `gpus`, for information. Not measured |
| `launch.mode` | string | `snp` |
| `launch.vmmType` | string | `QEMU` |
| `launch.guestFeatures` | string | `0x1`: the SEV features of QEMU's `sev-snp-guest` without IGVM |
| `launch.boot` | string | `ovmf-direct`: QEMU `-bios OVMF.fd -kernel -initrd -append` with `kernel-hashes=on` |
| `tools` | object | Tool name to version, for example `sev-snp-measure` and `tinfoil-config` |

The measurement covers the firmware, kernel, initrd and `cmdline` (and with it
the config), the vCPU count and signature, and the guest features. A guest
launched any other way reports a different `MEASUREMENT`.

## Versioning

Fields may be added to v1, so consumers must ignore fields they don't know.
Removing or renaming a field, or changing what one means, needs a new
predicate type: a `-v2` file beside this one. This file is never changed
incompatibly.

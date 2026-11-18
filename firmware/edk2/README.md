# edk2 patches

Patches applied to upstream [tianocore/edk2](https://github.com/tianocore/edk2)
at build time, in file name order. They are derived from edk2 and from
third-party edk2 forks, so this directory is licensed under edk2's
BSD-2-Clause-Patent licence ([`LICENSE`](LICENSE)), not Apache-2.0.

## `0001-OvmfPkg-AmdSev-add-NON_CC_BUILD.patch`

Adds a `NON_CC_BUILD` define to `OvmfPkg/AmdSev/AmdSevX64.dsc`, defaulting to
`FALSE`. When it is `TRUE`, the firmware swaps `BlobVerifierLibSevHashes` for
`BlobVerifierLibNull`, both as the platform `BlobVerifierLib` and as the library
linked into `QemuKernelLoaderFsDxe`.

The confidential build refuses to direct-boot a kernel unless SEV-SNP has
placed a hashes table in guest memory that matches the kernel, initrd and
command line. A guest launched without SEV-SNP has no such table, so the
confidential firmware stops at "No bootable option was found". The non-CC
variant skips the check so the same boot flow can be tested on hosts, or in
CI, without SEV-SNP.

Skipping the check is exactly what makes this variant unsafe for confidential
guests: the launch measurement would still cover the hashes table, but nothing
would compare it with what actually boots.

The patch is applied to both variants. With `NON_CC_BUILD` left at `FALSE` it
selects the same libraries as unpatched upstream, and CI checks that the `cc`
image is byte-for-byte identical with and without it.

Origin: [tinfoilsh/edk2@97c3701c0f](https://github.com/tinfoilsh/edk2/commit/97c3701c0f497c9677bf69ea19da66415412be60)
by Jules Drean, rebased onto `edk2-stable202608`, keeping only the
`AmdSevX64.dsc` changes.

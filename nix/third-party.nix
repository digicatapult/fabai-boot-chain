# Third-party code that may be compiled into the firmware, and where its
# licence text is in the edk2 source tree. nix/licences.nix scans what the
# compiler actually read, and fails unless:
#   - the edk2 submodules compiled in are exactly those listed here
#   - every SPDX licence identifier in a compiled file is listed here
# So an edk2 bump that pulls in new third-party code fails CI until this file,
# and with it the licence texts shipped in releases, is updated.
{
  # edk2 submodule path -> what it is and its SPDX licence.
  submodules = {
    "CryptoPkg/Library/OpensslLib/openssl" = {
      name = "OpenSSL";
      licence = "Apache-2.0";
    };
  };

  # SPDX licence identifier -> its text in the edk2 source tree. Each text in
  # use is shipped in releases as LICENSE-<identifier>.txt.
  licenceTexts = {
    "BSD-2-Clause-Patent" = "License.txt";
    "Apache-2.0" = "CryptoPkg/Library/OpensslLib/openssl/LICENSE.txt";
    # OvmfPkg's licence file carries the MIT text for its Xen headers, after
    # the BSD-2-Clause-Patent text.
    "MIT" = "OvmfPkg/License.txt";
  };
}

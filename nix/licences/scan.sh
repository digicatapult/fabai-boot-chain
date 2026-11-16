#!/usr/bin/env bash
# Run in the edk2 tree right after `build`, instead of installing the image.
# Lists every file under the tree that the compiler, assembler or ASL
# preprocessor read, from the dependency files edk2's build leaves behind
# (<object>.deps and each module's deps.txt), then derives:
#   compiled-files.txt        paths relative to the edk2 root
#   compiled-submodules.txt   edk2 submodules with at least one compiled file
#   spdx.txt                  "<SPDX expression or NOASSERTION><TAB><path>"
set -euo pipefail

out="$1"
root="$PWD"
mkdir -p "$out"

deps_list="$(mktemp)"
find Build -type f \( -name '*.deps' -o -name deps.txt \) -print0 | sort -z > "$deps_list"
if [[ ! -s "$deps_list" ]]; then
  printf 'No dependency files under Build/; the scan needs updating. File types seen:\n'
  find Build -type f -name '*.*' | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -n 40
  exit 1
fi

# Dependency files are make rules: split into whitespace-separated words, drop
# the line continuations and the "target:" words, keep paths in the edk2 tree.
xargs -0 cat < "$deps_list" |
  tr -s ' \t\\"' '\n' |
  sed -n "s|^${root}/||p" |
  grep -v -e '^Build/' -e '^Conf/' -e ':$' |
  sort -u |
  while IFS= read -r path; do
    if [[ -f "$path" ]]; then
      printf '%s\n' "$path"
    fi
  done > "$out/compiled-files.txt"

# A positive control: if this is missing, the parsing above is broken, and an
# empty or short list would wrongly pass as "no third-party code".
if ! grep -q '^MdePkg/Library/BaseLib/' "$out/compiled-files.txt"; then
  printf 'The scan found no MdePkg/Library/BaseLib sources, so it is broken.\n'
  printf 'Found %s files. First dependency file:\n' "$(wc -l < "$out/compiled-files.txt")"
  head -c 2000 "$(head -z -n 1 "$deps_list" | tr -d '\0')"
  exit 1
fi

sed -n 's/^[[:space:]]*path[[:space:]]*=[[:space:]]*//p' .gitmodules | sort |
  while IFS= read -r submodule; do
    if awk -v prefix="${submodule}/" 'index($0, prefix) == 1 { found = 1; exit } END { exit !found }' \
      "$out/compiled-files.txt"; then
      printf '%s\n' "$submodule"
    fi
  done > "$out/compiled-submodules.txt"

# The first SPDX-License-Identifier in each file, or NOASSERTION.
# shellcheck disable=SC2016 # $0 is awk's, not the shell's.
tr '\n' '\0' < "$out/compiled-files.txt" |
  xargs -0 gawk '
    BEGINFILE { id = "" }
    id == "" && /SPDX-License-Identifier:/ {
      id = $0
      sub(/.*SPDX-License-Identifier:[[:space:]]*/, "", id)
      sub(/[[:space:]]*(\*\/|-->)?[[:space:]]*\r?$/, "", id)
      nextfile
    }
    ENDFILE { printf "%s\t%s\n", (id == "" ? "NOASSERTION" : id), FILENAME }
  ' | sort -t "$(printf '\t')" -k2 > "$out/spdx.txt"

printf 'Scanned %s dependency files: %s compiled files, submodules: %s\n' \
  "$(tr -cd '\0' < "$deps_list" | wc -c)" \
  "$(wc -l < "$out/compiled-files.txt")" \
  "$(paste -sd ' ' "$out/compiled-submodules.txt")"

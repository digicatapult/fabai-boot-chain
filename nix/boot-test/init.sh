#!/bin/sh
# /init for the firmware boot test. Reaching it proves the firmware handed over
# to the Linux kernel. Prints the marker, then powers the VM off.
set -eu

# The initrd has no /dev/console, so the kernel starts /init without stdio.
mount -t devtmpfs devtmpfs /dev
exec </dev/console >/dev/console 2>&1
mount -t proc proc /proc

if grep -qw pdpe1gb /proc/cpuinfo; then
  pdpe1gb=yes
else
  pdpe1gb=no
fi

echo "@marker@ pdpe1gb=${pdpe1gb}"
poweroff -f

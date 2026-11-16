#!/usr/bin/env bash
# Boots a firmware image in QEMU with a test kernel and initrd, then checks the
# serial and debug console logs, which it writes to the directory in $1.
# Environment, set by boot-test.nix:
#   QEMU, FIRMWARE, KERNEL, INITRD, MARKER, TIMEOUT_SECONDS
#   EXPECT=boot    the firmware must hand over to the kernel and reach /init
#   EXPECT=refuse  the firmware must refuse to boot the kernel, and write
#                  nothing to the debug console
set -euo pipefail

# Printed by OvmfPkg's PlatformBootManagerUnableToBoot to the console.
readonly refusal='No bootable option'
# The first line Linux prints; its absence means the kernel never ran.
readonly kernel_banner='Linux version'
# DxeIpl's page-table summary in the debug log (DEBUG builds only).
readonly one_gig_pages='1GPage=1'

log_dir="$1"
mkdir -p "$log_dir"
serial="$log_dir/serial.log"
debugcon="$log_dir/debugcon.log"
: > "$serial"

# TCG rather than KVM: no dependence on the runner's /dev/kvm or host CPU, and
# `-cpu max` always offers 1 GiB pages (pdpe1gb), so the PCD is exercised.
"$QEMU" \
  -machine q35 -accel tcg -cpu max -smp 1 -m 1024 \
  -nodefaults -display none -no-reboot \
  -bios "$FIRMWARE" \
  -kernel "$KERNEL" -initrd "$INITRD" -append 'console=ttyS0 panic=-1' \
  -serial "file:$serial" \
  -debugcon "file:$debugcon" -global isa-debugcon.iobase=0x402 &
qemu_pid=$!
trap 'kill "$qemu_pid" 2>/dev/null || true' EXIT

# Wait for a decisive line, QEMU exiting, or the timeout.
outcome=timeout
deadline=$((SECONDS + TIMEOUT_SECONDS))
while ((SECONDS < deadline)); do
  if grep -qF -- "$MARKER" "$serial" || grep -qF -- "$refusal" "$serial"; then
    outcome=logged
    break
  fi
  if ! kill -0 "$qemu_pid" 2>/dev/null; then
    outcome=exited
    break
  fi
  sleep 1
done
elapsed=$SECONDS

# After the marker, /init powers off; give QEMU a moment to flush and exit.
for _ in 1 2 3 4 5; do
  kill -0 "$qemu_pid" 2>/dev/null || break
  sleep 1
done
qemu_status=0
if kill -0 "$qemu_pid" 2>/dev/null; then
  kill "$qemu_pid"
  wait "$qemu_pid" || true
  qemu_status=killed
else
  wait "$qemu_pid" || qemu_status=$?
fi
trap - EXIT

printf 'outcome=%s after %ss, QEMU status %s\n' "$outcome" "$elapsed" "$qemu_status"

failures=()
fail() { failures+=("$1"); }

if [[ "$qemu_status" != 0 && "$qemu_status" != killed ]]; then
  fail "QEMU exited with status $qemu_status"
fi
if [[ "$outcome" == timeout ]]; then
  fail "nothing decisive on the serial console within ${TIMEOUT_SECONDS}s"
fi

case "$EXPECT" in
  boot)
    grep -qF -- "$MARKER pdpe1gb=" "$serial" || fail "the test /init never ran"
    grep -qF -- "$MARKER pdpe1gb=no" "$serial" && fail "the guest CPU has no 1 GiB pages"
    grep -qF -- "$one_gig_pages" "$debugcon" ||
      fail "DxeIpl did not build 1 GiB page tables (no '$one_gig_pages' in the debug log)"
    ;;
  refuse)
    grep -qF -- "$refusal" "$serial" || fail "the firmware never reported '$refusal'"
    grep -qF -- "$kernel_banner" "$serial" && fail "the kernel started"
    grep -qF -- "$MARKER" "$serial" && fail "the test /init ran"
    # The cc image is a RELEASE build: the host must not get a debug log.
    [[ -s "$debugcon" ]] && fail "the firmware wrote to the debug console (port 0x402)"
    ;;
  *)
    fail "unknown EXPECT=$EXPECT"
    ;;
esac

if ((${#failures[@]} == 0)); then
  printf 'PASS (%s)\n' "$EXPECT"
  exit 0
fi

printf 'FAIL (%s):\n' "$EXPECT"
printf '  - %s\n' "${failures[@]}"
printf '\n--- serial console (last 200 lines) ---\n'
tail -n 200 "$serial"
if [[ -s "$debugcon" ]]; then
  printf '\n--- debug console (last 200 lines) ---\n'
  tail -n 200 "$debugcon"
fi
exit 1

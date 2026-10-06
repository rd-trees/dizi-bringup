#!/bin/bash
# Update a signed release in place: `flash-dizi.sh --keep` without boot, so data and a
# KernelSU/Magisk-patched boot stay. Only for builds whose boot.img is unchanged (check first).
# BOOT=<image on the USB host, relative to the staged dir> also flashes that boot to both slots,
# e.g. a KernelSU-patched copy of the new boot.img when the build changed boot.
# The images must be staged on the USB host in $DIZI_REMOTE_DIR/<dir> (super, vendor_boot, dtbo,
# vbmeta, vbmeta_system, recovery, misc). Firmware is never touched; nothing is erased.
# Usage: tools/flash-keep.sh <staged-dir>
set -euo pipefail
. "$(dirname "$0")/env"
R="$(dirname "$0")/remote.sh"
dir=${1:?staged dir on the USB host}

die() { echo "FAILED: $*" >&2; exit 1; }

"$R" adb reboot bootloader || true
for _ in $(seq 60); do
	"$R" fastboot devices 2>/dev/null | grep -q . && break
	sleep 2
done
"$R" fastboot getvar product 2>&1 | grep -q 'product: dizi' || die "no dizi in the bootloader"
"$R" fastboot getvar is-userspace 2>&1 | grep -q 'is-userspace: no' || die "not the bootloader"
"$R" fastboot getvar unlocked 2>&1 | grep -q 'unlocked: yes' || die "bootloader locked"

ssh -i "$DIZI_SSH_KEY" "$DIZI_HOST" "export PATH=/opt/homebrew/bin:\$PATH ANDROID_SERIAL=$DIZI_SERIAL
	cd $DIZI_REMOTE_DIR/$dir &&
	fastboot flash super super.img &&
	if [ -n \"${BOOT:-}\" ]; then fastboot flash boot_a \"${BOOT:-}\" && fastboot flash boot_b \"${BOOT:-}\" || exit 1; fi &&
	for p in vendor_boot dtbo vbmeta vbmeta_system recovery; do
		fastboot flash \${p}_a \$p.img && fastboot flash \${p}_b \$p.img || exit 1
	done &&
	fastboot flash misc misc.img && fastboot set_active a && fastboot reboot" 2>&1 |
	grep -E "FAILED|error|Finished. Total time: [0-9.]+s$" | tail -3

for i in $(seq 120); do
	[[ $("$R" adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r') == 1 ]] && break
	sleep 3
done
[[ $("$R" adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r') == 1 ]] || die "no boot after 6 min"
echo "booted: $("$R" adb shell getprop ro.build.date | tr -d '\r')"

#!/bin/bash
# Build the dizi OrangeFox recovery (fox_16.0) in $DIZI_ROOT/ofox.
# Usage: tools/build-recovery.sh <id>
# Output: builds/recovery-<id>/recovery.img (+ the OrangeFox zip), log in logs/recovery-<id>.log.
set -euo pipefail
. "$(dirname "$0")/env"
id=${1:?usage: build-recovery.sh <id>}
src=$DIZI_ROOT/ofox
log=$DIZI_ROOT/logs/recovery-$id.log
dst=$DIZI_ROOT/builds/recovery-$id

cd "$src"
if ! (
	set +eu
	export FOX_BUILD_DEVICE=dizi ALLOW_MISSING_DEPENDENCIES=true LC_ALL=C
	. build/envsetup.sh
	. device/xiaomi/dizi/vendorsetup.sh
	lunch twrp_dizi-bp2a-eng || exit 1
	m -j"${DIZI_JOBS:-24}" recoveryimage
) >"$log" 2>&1; then
	tail -30 "$log" >&2
	exit 1
fi

mkdir -p "$dst"
out=$src/out/target/product/dizi
cp "$out/recovery.img" "$dst/"
for zip in "$out"/OrangeFox*.zip; do
	[[ -e "$zip" ]] && cp "$zip" "$dst/"
done
sha256sum "$dst/recovery.img"

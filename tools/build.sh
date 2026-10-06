#!/bin/bash
# Build Evolution X for dizi (or ruan). Usage: build.sh <log-name> [make targets...]
#   DEVICE=dizi|ruan (default dizi)
#   TREE=evox|lineage (default evox): lineage is the plain LineageOS 23.2 tree next to evox,
#              whose out dirs started as copies of evox's (tools/match-mtimes.py keeps it incremental)
#   VARIANT=user|userdebug (default userdebug, the bench build)
#   RELEASE=1: a shareable build: VARIANT=user, no insecure adb or bench keys, and its own
#              out dir (out-release) so the bench's incremental out/ is left alone.
# Out dirs are per device (tools/env). Bench builds run in out/, a symlink this script points
# at out-<device>/; a lock keeps two builds from switching it under each other.
set -o pipefail
. "$(dirname "$0")/env"
name=${1:?log-name}; shift
tree=$DIZI_TREE
if [[ $tree == lineage ]]; then
	targets=${*:-bacon}
else
	targets=${*:-evolution}
fi
cd "$DIZI_ROOT/$tree"
if [[ -n ${RELEASE:-} ]]; then
	VARIANT=user
	unset WITH_ADB_INSECURE
	# Relative: an absolute OUT_DIR trips soong path checks (platform_testing). Lineage's kernel
	# header generation needs vendor/lineage's relative-OUT_DIR fix for this.
	export OUT_DIR=$DIZI_OUT_RELEASE_NAME
else
	exec {lock}> "$DIZI_ROOT/$tree/.out.lock"
	flock -n "$lock" || { echo "another bench build holds $tree/out" >&2; exit 1; }
	if [[ -e out && ! -L out ]]; then
		echo "$tree/out is a directory; move it to $DIZI_OUT_NAME first" >&2
		exit 1
	fi
	mkdir -p "$DIZI_OUT_NAME"
	ln -sfn "$DIZI_OUT_NAME" out
	# Bench: Lineage sets ro.debuggable=0 and adb auth on userdebug unless
	# WITH_ADB_INSECURE is set; we need adb (root) on first boot without a screen tap.
	export WITH_ADB_INSECURE=${WITH_ADB_INSECURE-true}
	# The bench adb key, copied into the tree (soong wants source-relative paths); not in any repo.
	if [[ -z ${DIZI_ADB_KEYS+x} && -f $DIZI_ROOT/keys/bench_adb_keys ]]; then
		mkdir -p vendor/dizi-bench
		cp "$DIZI_ROOT/keys/bench_adb_keys" vendor/dizi-bench/adb_keys
		export DIZI_ADB_KEYS=vendor/dizi-bench/adb_keys
	fi
fi
variant=${VARIANT:-userdebug}
export USE_CCACHE=1 CCACHE_EXEC=/usr/bin/ccache CCACHE_DIR=$DIZI_ROOT/.ccache
source build/envsetup.sh >/dev/null 2>&1
# The tree's release config (bp4a on 16/bka, cp2a on 17/cnb).
release=$(sed -n "s/^aosp_target_release=//p" vendor/lineage/vars/aosp_target_release 2>/dev/null)
lunch "lineage_$DIZI_DEVICE-${release:-bp4a}-$variant" >/dev/null 2>&1 || { echo "lunch failed"; exit 1; }
m $targets -j${DIZI_JOBS:-48} > "$DIZI_ROOT/logs/$name.log" 2>&1
rc=$?
echo "exit=$rc" >> "$DIZI_ROOT/logs/$name.log"
grep -E '^FAILED:|error:' "$DIZI_ROOT/logs/$name.log" | head -20
exit $rc

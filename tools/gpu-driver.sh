#!/bin/bash
# Try a different Adreno user-mode driver without flashing: bind-mount its libraries over /vendor in
# init's mount namespace, then restart the framework so SurfaceFlinger, zygote and every app load
# them. The kernel driver and the GPU firmware stay stock. A reboot undoes everything.
#
# A bundle is a directory with vendor/... files (only files that already exist on our /vendor; a
# bind mount needs a target) and a FILES list, e.g. tmp/gpu-drivers/V0863.1.
#
# Usage: tools/gpu-driver.sh on <bundle-dir>
#        tools/gpu-driver.sh off <bundle-dir>
#        tools/gpu-driver.sh show
set -euo pipefail
. "$(dirname "$0")/env"
R="$(dirname "$0")/remote.sh"

mode=${1:?on|off|show}
bundle=${2:-}
dev=/data/local/tmp/gpu

# What surfaceflinger sees: the version string of the GLES library in its mount namespace, and
# whether that library is the mapped one (a bind mount shows in its maps as the original path, so
# compare inodes).
version='sf=$(pidof surfaceflinger); lib=/vendor/lib64/egl/libGLESv2_adreno.so
         nsenter -t $sf -m -- strings $lib | grep -m1 -oE "V@0[0-9.]+ \(GIT@[0-9a-f]+"
         echo "bind mounts under /vendor/lib64 in sf namespace: $(awk "\$5 ~ \"^/vendor/lib64/\"" /proc/$sf/mountinfo | wc -l)"
         echo "sf maps the file now at $lib: $( [ "$(nsenter -t $sf -m -- stat -c %i $lib)" = "$(awk -v l=$lib "\$6 == l {print \$5; exit}" /proc/$sf/maps)" ] && echo yes || echo no)"'

nsbind=$(cat "$(dirname "$0")/nsbind.sh")

# Root: adbd as root on userdebug builds, su (KernelSU/Magisk) on user builds.
sh=sh
run() {
	"$R" adb shell "cat > /data/local/tmp/gpu-driver.sh" <<<"$1"
	"$R" adb shell "$sh /data/local/tmp/gpu-driver.sh" </dev/null | tr -d '\r'
}
a() { "$R" adb "$@" </dev/null 2>/dev/null | tr -d '\r'; }
. "$(dirname "$0")/check.sh"

"$R" adb root >/dev/null 2>&1 || true
"$R" adb wait-for-device
if [[ $(a shell id -u) != 0 ]]; then
	[[ $(a shell su -c id -u) == 0 ]] || die "no root (adb root and su both failed)"
	sh="su -c sh"
fi

case $mode in
show)
	run "$version"
	exit 0
	;;
on | off) ;;
*)
	echo "mode: on|off|show" >&2
	exit 1
	;;
esac

[[ -n $bundle && -f $bundle/FILES ]] || { echo "bundle dir with a FILES list needed" >&2; exit 1; }
name=$(basename "$bundle")

if [[ $mode == on ]]; then
	ssh -i "$DIZI_SSH_KEY" "$DIZI_HOST" "mkdir -p $DIZI_REMOTE_DIR/gpu"
	rsync -e "ssh -C -i $DIZI_SSH_KEY" -rt --delete "$bundle/" "$DIZI_HOST:$DIZI_REMOTE_DIR/gpu/$name/"
	"$R" adb shell "rm -rf $dev/$name; mkdir -p $dev"
	"$R" adb push "$DIZI_REMOTE_DIR/gpu/$name" "$dev/$name" >/dev/null
	# Give each file its target's SELinux label (same_process_hal_file etc.), then mount it.
	# Bind in every mount namespace init uses (tools/nsbind.sh).
	out=$(run "$nsbind
	     cd $dev/$name
	     while read -r f; do
	         [ -e /\$f ] || { echo \"skip (no target): \$f\"; continue; }
	         chcon \$(ls -Z /\$f | cut -d' ' -f1) \$f
	         nsbind $dev/$name/\$f /\$f || echo \"mount failed: \$f\"
	     done < FILES")
	echo "$out"
	[[ $out != *"mount failed:"* ]] || die "not every file was mounted (see above)"
	ss=$(a shell pidof system_server)
	run "stop; start"
	wait_boot "$ss"
	loaded=$(run "$version")
	echo "$loaded"
	# Bundles are named after their version (V0863.1 -> V@0863.1).
	[[ $loaded == *"V@${name#V}"* && $loaded == *"now at "*": yes"* ]] || die "the framework didn't pick up $name (see the version above)"
else
	ss=$(a shell pidof system_server)
	out=$(run "$nsbind
	     while read -r f; do
	         nsunbind /\$f
	         nsmounted /\$f && echo \"still mounted: \$f\"
	     done < $dev/$name/FILES
	     stop; start")
	echo "$out"
	[[ $out != *"still mounted:"* ]] || die "not every file was unmounted (see above); a reboot clears them"
	wait_boot "$ss"
	loaded=$(run "$version")
	echo "$loaded"
	[[ $loaded != *"V@${name#V}"* ]] || die "surfaceflinger still runs $name"
fi

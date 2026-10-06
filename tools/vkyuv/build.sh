#!/bin/bash
# Build vkyuv for the tablet with the cnb tree's clang and NDK sysroot, and push it with the
# V@0863.1 libraries, the run scripts and the clips (made on the Mac by clips.sh).
# Usage: tools/vkyuv/build.sh [--push]
# Then: tools/remote.sh adb shell "su -c '/data/local/tmp/vkyuv/run.sh stock|new /data/local/tmp/vkyuv/vkyuv synth|anw'"
#       tools/remote.sh adb shell "su -c '/data/local/tmp/vkyuv/run.sh stock|new /data/local/tmp/vkyuv/codecs.sh'"
set -euo pipefail
. "$(dirname "$0")/../env"
here=$(cd "$(dirname "$0")" && pwd)
src=$DIZI_ROOT/evox-cnb
out=$DIZI_ROOT/tmp/vkyuv-build
mkdir -p "$out/crt"
ln -sf "$src/out/soong/.intermediates/bionic/libc/crtbegin_dynamic/android_arm64_armv8-a-branchprot/crtbegin_dynamic.o" "$out/crt/"
ln -sf "$(find "$src/out/soong/.intermediates/bionic/libc/crtend_android" -name crtend_android.o | grep -v addrsig | head -1)" "$out/crt/"
# The prebuilt glslangValidator isn't executable in the tree.
install -m755 "$src/prebuilts/android-emulator/linux-x86_64/lib64/vulkan/glslangValidator" "$out/glslang"
"$out/glslang" -V --vn quad_vert -o "$here/quad_vert.h" "$here/quad.vert" >/dev/null
"$out/glslang" -V --vn sample_frag -o "$here/sample_frag.h" "$here/sample.frag" >/dev/null
sysroot=$src/out/soong/ndk/sysroot
"$src/prebuilts/clang/host/linux-x86/clang-r596125/bin/clang" --target=aarch64-linux-android31 --sysroot="$sysroot" \
	-B "$out/crt" -O2 -Wall -o "$out/vkyuv" "$here/vkyuv.c" -L"$sysroot/usr/lib/aarch64-linux-android/31" \
	-lvulkan -lmediandk -lnativewindow -landroid -lm -fuse-ld=lld
echo "built $out/vkyuv"
[[ ${1:-} == --push ]] || exit 0

R=$DIZI_ROOT/tools/remote.sh
ssh -i "$DIZI_SSH_KEY" "$DIZI_HOST" "mkdir -p $DIZI_REMOTE_DIR/vkyuv"
rsync -e "ssh -i $DIZI_SSH_KEY" -rt "$out/vkyuv" "$here/run.sh" "$here/codecs.sh" "$DIZI_HOST:$DIZI_REMOTE_DIR/vkyuv/"
rsync -e "ssh -i $DIZI_SSH_KEY" -rt "$DIZI_ROOT/tmp/gpu-drivers/V0863.1/vendor/lib64/" "$DIZI_HOST:$DIZI_REMOTE_DIR/vkyuv/lib64/"
"$R" adb shell "mkdir -p /data/local/tmp/vkyuv/drv /data/local/tmp/vkyuv/clips"
for f in vkyuv run.sh codecs.sh; do "$R" adb push "$DIZI_REMOTE_DIR/vkyuv/$f" /data/local/tmp/vkyuv/ >/dev/null; done
"$R" adb push "$DIZI_REMOTE_DIR/vkyuv/lib64" /data/local/tmp/vkyuv/drv/ >/dev/null
"$R" adb push "$DIZI_REMOTE_DIR/vkyuv-clips/." /data/local/tmp/vkyuv/clips/ >/dev/null
"$R" adb shell "chmod 755 /data/local/tmp/vkyuv/vkyuv /data/local/tmp/vkyuv/run.sh /data/local/tmp/vkyuv/codecs.sh"
echo pushed

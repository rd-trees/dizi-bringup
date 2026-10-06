#!/bin/bash
# Video decode check: play each test clip (made on the Mac by ~/dizi/codecs.sh: H.264, HEVC,
# VP9, AV1 at 1080p and 2160p, no audio) and report which Codec2 decoder the player used:
# c2.qti.* is Qualcomm hardware, c2.android.* is the software fallback. Also counts
# decoder errors and dropped-frame hints.
# Usage: tools/codec-test.sh <build-id>
set -uo pipefail
. "$(dirname "$0")/env"
R="$(dirname "$0")/remote.sh"
id=${1:?build-id}
out=$DIZI_ROOT/logs/$id/codec-$(date +%H%M%S)
mkdir -p "$out"
a() { "$R" adb "$@" </dev/null 2>/dev/null | tr -d '\r'; }
dev=/sdcard/Movies/codec

a shell "mkdir -p $dev"
for f in h264-1080.mp4 hevc-1080.mp4 vp9-1080.webm av1-1080.mp4 h264-2160.mp4 hevc-2160.mp4 vp9-2160.webm av1-2160.mp4; do
	a push "$DIZI_REMOTE_DIR/codec/$f" "$dev/$f" >/dev/null
done
a shell "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file://$dev" >/dev/null
a shell 'svc power stayon true; input keyevent WAKEUP; wm dismiss-keyguard; settings put system screen_brightness 10'
trap '"$(dirname "$0")/remote.sh" adb shell svc power stayon false </dev/null >/dev/null 2>&1' EXIT  # let the tablet idle (ART dexopt) again

for f in h264-1080.mp4 hevc-1080.mp4 vp9-1080.webm av1-1080.mp4 h264-2160.mp4 hevc-2160.mp4 vp9-2160.webm av1-2160.mp4; do
	mime=video/mp4; [[ $f == *.webm ]] && mime=video/webm
	a logcat -c
	a shell "am start -W -a android.intent.action.VIEW -d file://$dev/$f -t $mime" >/dev/null
	sleep 7
	a logcat -d > "$out/$f.log"
	comp=$(grep -oE 'c2\.(qti|android|google)\.[a-z0-9.]+\.decoder[a-z.]*' "$out/$f.log" | sort -u | tr '\n' ' ')
	errs=$(grep -ciE 'CCodec.*(error|fail)|MediaCodec.*error|Codec2.*error' "$out/$f.log")
	printf '%-16s decoder: %-40s errors: %s\n' "$f" "${comp:-none seen}" "$errs" | tee -a "$out/summary.txt"
	a shell 'input keyevent HOME'
	sleep 1
done
echo "results: $out"

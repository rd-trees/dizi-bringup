#!/bin/bash
# Drive the hardware paths over adb (camera photo/video/front, video playback,
# speaker tone, Wi-Fi scan, Bluetooth toggle, rotation, brightness, screen
# off/on), then collect SELinux denials, crashes and per-step results.
# Run before going enforcing so the policy covers more than boot.
# Usage: tools/exercise.sh <build-id>
set -uo pipefail
. "$(dirname "$0")/env"
T=$(dirname "$0")
R="$T/remote.sh"
id=${1:?build-id}
out=$DIZI_ROOT/logs/$id/exercise-$(date +%H%M%S)
mkdir -p "$out"
a() { "$R" adb "$@" </dev/null 2>/dev/null | tr -d '\r'; }
# Binary output (screenshots): no \r stripping.
raw() { "$R" adb "$@" </dev/null 2>/dev/null; }
step() { echo "== $*" | tee -a "$out/steps.txt"; }
dcim() { a shell 'ls /sdcard/DCIM/Camera 2>/dev/null | wc -l'; }

a shell 'svc power stayon true; input keyevent WAKEUP; wm dismiss-keyguard'
trap '"$(dirname "$0")/remote.sh" adb shell svc power stayon false </dev/null >/dev/null 2>&1' EXIT  # let the tablet idle (ART dexopt) again
a logcat -c -b all
a shell 'dmesg -C' >/dev/null

step "camera: rear photo"
n0=$(dcim)
# Aperture reopens the last lens unless told otherwise.
a shell 'am start -W -a android.media.action.STILL_IMAGE_CAMERA --ei android.intent.extras.CAMERA_FACING 0 --ei android.intent.extras.LENS_FACING_BACK 1 --ez android.intent.extra.USE_FRONT_CAMERA false' >/dev/null
sleep 5; a shell 'input keyevent CAMERA'; sleep 4
step "camera: rear video 6 s"
a shell 'am start -W -a android.media.action.VIDEO_CAMERA --ei android.intent.extras.CAMERA_FACING 0 --ei android.intent.extras.LENS_FACING_BACK 1 --ez android.intent.extra.USE_FRONT_CAMERA false' >/dev/null
sleep 5; a shell 'input keyevent CAMERA'; sleep 6; a shell 'input keyevent CAMERA'; sleep 3
step "camera: front photo"
a shell 'am start -W -a android.media.action.STILL_IMAGE_CAMERA --ei android.intent.extras.CAMERA_FACING 1 --ei android.intent.extras.LENS_FACING_FRONT 1 --ez android.intent.extra.USE_FRONT_CAMERA true' >/dev/null
sleep 5; a shell 'input keyevent CAMERA'; sleep 4
a shell 'screencap -p /data/local/tmp/ex-cam.png'; raw exec-out cat /data/local/tmp/ex-cam.png > "$out/camera-front.png"
n1=$(dcim)
echo "camera: DCIM files $n0 -> $n1 (expect +3)" | tee -a "$out/steps.txt"
a shell 'input keyevent HOME'

step "video playback (newest recording)"
vid=$(a shell 'ls -t /sdcard/DCIM/Camera/*.mp4 2>/dev/null | head -1')
if [[ -n $vid ]]; then
	a shell "am start -W -a android.intent.action.VIEW -d file://$vid -t video/mp4" >/dev/null
	sleep 8
	a shell 'screencap -p /data/local/tmp/ex-vid.png'; raw exec-out cat /data/local/tmp/ex-vid.png > "$out/video.png"
	a shell 'input keyevent HOME'
else
	echo "no video recorded" | tee -a "$out/steps.txt"
fi

# QUIET=1 skips the audible tone (e.g. at night).
if [[ -z ${QUIET:-} ]]; then
	step "speaker tone 3 s"
	a shell 'CLASSPATH=/data/local/tmp/tone.dex timeout 6 app_process / Tone 1000 3 >/dev/null 2>&1'
fi

step "wifi scan"
a shell 'cmd wifi start-scan'; sleep 6
echo "wifi: $(a shell 'cmd wifi list-scan-results | tail -n +2 | wc -l') networks" | tee -a "$out/steps.txt"

step "bluetooth off/on"
a shell 'cmd bluetooth_manager disable'; sleep 5
a shell 'cmd bluetooth_manager enable'; sleep 6
echo "bluetooth: $(a shell 'settings get global bluetooth_on')" | tee -a "$out/steps.txt"

step "rotation 0..3"
a shell 'settings put system accelerometer_rotation 0'
for r in 0 1 2 3 1; do a shell "settings put system user_rotation $r"; sleep 2; done
a shell 'settings put system accelerometer_rotation 1'

step "brightness"
if [[ -n ${QUIET:-} ]]; then levels="10 30 10"; else levels="10 255 120"; fi
for b in $levels; do a shell "settings put system screen_brightness $b"; sleep 1; done

step "screen off 10 s / on"
a shell 'input keyevent SLEEP'; sleep 10
a shell 'input keyevent WAKEUP; wm dismiss-keyguard'; sleep 2

step "collect"
{ a shell dmesg; a logcat -d -b all; } | grep -a 'avc: *denied' > "$out/avc-raw.txt"
"$T/avc-triples.py" "$out/avc-raw.txt" > "$out/triples.txt"
a logcat -d -b crash > "$out/crash.txt"
a logcat -d -b main > "$out/logcat.txt"
{
	echo "denial triples: $(wc -l < "$out/triples.txt")"
	echo "crashing processes:"; grep -a 'Process:' "$out/crash.txt" | sed 's/.*Process: //; s/, PID.*//' | sort | uniq -c
	echo "native crashes: $(grep -ac 'Build fingerprint' "$out/crash.txt")"
	echo "codecs used:"; grep -aoE 'c2\.[a-z0-9.]+\.(decoder|encoder)' "$out/logcat.txt" | sort | uniq -c
} | tee -a "$out/steps.txt"
echo "results: $out"

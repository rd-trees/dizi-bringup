#!/bin/bash
# Play Store smoothness: fling the home feed and an app's details page, and report the Play
# Store's hwui frame stats for each.
# Usage: tools/play-jank.sh <build-id> <label> [portrait|landscape] [flings]
set -uo pipefail
. "$(dirname "$0")/env"
R="$(dirname "$0")/remote.sh"
id=${1:?build-id}; label=${2:?label}; orient=${3:-landscape}; flings=${4:-20}
out=$DIZI_ROOT/logs/$id/play-jank-$label-$orient-$(date +%H%M%S)
mkdir -p "$out"
a() { "$R" adb "$@" </dev/null 2>/dev/null | tr -d '\r'; }
. "$(dirname "$0")/check.sh"
require_device
pkg=com.android.vending

a shell 'svc power stayon true; input keyevent WAKEUP; wm dismiss-keyguard; settings put system accelerometer_rotation 0'
if [[ $orient == portrait ]]; then a shell settings put system user_rotation 0; w=1600; h=2560
else a shell settings put system user_rotation 1; w=2560; h=1600; fi
x=$((w / 2)); y1=$((h * 3 / 10)); y2=$((h * 8 / 10))
sleep 2

fling() {
	local n=$1 i
	for ((i = 0; i < n; i++)); do
		if ((i % 2)); then a shell input swipe $x $y1 $x $y2 120; else a shell input swipe $x $y2 $x $y1 120; fi
		sleep 0.5
	done
}
measure() {
	local name=$1
	a shell dumpsys gfxinfo $pkg reset >/dev/null
	fling "$flings"
	a shell dumpsys gfxinfo $pkg >"$out/gfxinfo-$name.txt"
	require_frames "$out/gfxinfo-$name.txt" $((flings * 20)) "play store $name"
	printf '%-14s %-10s %-8s %s\n' "$label" "$orient" "$name" "$(grep -E 'Janky frames:|50th percentile|90th percentile|99th percentile' \
		"$out/gfxinfo-$name.txt" | head -4 | sed 's/^ *//; s/ percentile//' | tr '\n' ' ')" | tee -a "$out/summary.txt"
}

a shell "am start -W -n $pkg/.AssetBrowserActivity" >/dev/null
sleep 6
fling 6   # warm-up: load the feed's images and code
measure home
a shell "am start -W -a android.intent.action.VIEW -d market://details?id=com.google.android.youtube -p $pkg" >/dev/null
sleep 6
fling 4
measure details
a shell 'input keyevent HOME'
echo "results: $out"

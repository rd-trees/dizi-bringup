#!/bin/bash
# Recents (overview) smoothness: open a few apps, then repeatedly enter overview
# (APP_SWITCH, same animation as the gesture), fling through the task cards and
# go home. Overview is drawn by the launcher (quickstep), so its hwui frame stats
# are the ones that matter; SurfaceFlinger timestats cover the composition side.
# Usage: tools/recents-jank.sh <build-id> [cycles] [portrait|landscape]
set -uo pipefail
. "$(dirname "$0")/env"
R="$(dirname "$0")/remote.sh"
id=${1:?build-id}; cycles=${2:-10}; orient=${3:-landscape}
out=$DIZI_ROOT/logs/$id/recents-jank-$orient-$(date +%H%M%S)
mkdir -p "$out"
a() { "$R" adb "$@" </dev/null 2>/dev/null | tr -d '\r'; }
. "$(dirname "$0")/apps.sh"

a shell 'svc power stayon true; input keyevent WAKEUP; wm dismiss-keyguard; settings put system accelerometer_rotation 0'
trap '"$(dirname "$0")/remote.sh" adb shell svc power stayon false </dev/null >/dev/null 2>&1' EXIT  # let the tablet idle (ART dexopt) again
if [[ $orient == portrait ]]; then a shell settings put system user_rotation 0; w=1600; h=2560
else a shell settings put system user_rotation 1; w=2560; h=1600; fi
y=$((h / 2)); x1=$((w * 3 / 4)); x2=$((w / 4))

# Populate recents.
for intent in "-a android.settings.SETTINGS" \
	"-a android.intent.action.VIEW -d https://en.wikipedia.org/wiki/Android_version_history" \
	"$clock_intent" \
	"-a android.intent.action.MAIN -c android.intent.category.APP_CALCULATOR" \
	"$gallery_intent"; do
	a shell "am start -W $intent" >/dev/null
	sleep 2
done
a shell 'input keyevent HOME'
sleep 2

a shell dumpsys SurfaceFlinger --timestats -disable -clear >/dev/null
a shell dumpsys SurfaceFlinger --timestats -enable >/dev/null
a shell dumpsys gfxinfo "$launcher" reset >/dev/null
for ((i = 0; i < cycles; i++)); do
	a shell 'input keyevent APP_SWITCH'      # home -> overview
	sleep 1.2
	a shell "input swipe $x2 $y $x1 $y 150"   # fling through the cards
	sleep 0.8
	a shell "input swipe $x1 $y $x2 $y 150"
	sleep 0.8
	a shell 'input keyevent HOME'            # overview -> home
	sleep 1.2
done
a shell dumpsys gfxinfo "$launcher" > "$out/gfxinfo-launcher.txt"
a shell dumpsys SurfaceFlinger --timestats -dump > "$out/sf-timestats.txt"
a shell dumpsys SurfaceFlinger --timestats -disable >/dev/null
{
	printf '%-40s ' "launcher (recents)"
	grep -E 'Total frames rendered|Janky frames:|50th percentile|90th percentile|95th percentile|99th percentile|Number Missed Vsync|Number Slow UI thread|Number Slow issue draw|Number Frame deadline missed' \
		"$out/gfxinfo-launcher.txt" | head -10 | sed 's/^ *//' | tr '\n' ';'
	echo
	grep -E '^(totalFrames|clientCompositionFrames|missedFrames) =' "$out/sf-timestats.txt" | head -3
} | tee "$out/summary.txt"
echo "results: $out"

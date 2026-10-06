#!/bin/bash
# Scripted UI smoothness run: fling-scroll a few apps over adb and collect
# hwui frame stats (dumpsys gfxinfo) plus SurfaceFlinger timestats.
# Usage: tools/ui-jank.sh <build-id> [flings-per-app] [portrait|landscape]
set -uo pipefail
. "$(dirname "$0")/env"
R="$(dirname "$0")/remote.sh"
id=${1:?build-id}; flings=${2:-20}; orient=${3:-landscape}
out=$DIZI_ROOT/logs/$id/ui-jank-$orient-$(date +%H%M%S)
mkdir -p "$out"
a() { "$R" adb "$@" </dev/null 2>/dev/null | tr -d '\r'; }
. "$(dirname "$0")/check.sh"
require_device
. "$(dirname "$0")/apps.sh"

# package|launch intent (am start args)
apps=(
	"com.android.settings|-a android.settings.SETTINGS"
	"$launcher|-a android.intent.action.MAIN -c android.intent.category.HOME"
	"$browser|-a android.intent.action.VIEW -d https://en.wikipedia.org/wiki/Android_version_history"
)

# Fixed orientation, swipes scaled to the rotated screen (physical 1600x2560).
a shell 'svc power stayon true; input keyevent WAKEUP; wm dismiss-keyguard; settings put system accelerometer_rotation 0'
if [[ $orient == portrait ]]; then a shell settings put system user_rotation 0; w=1600; h=2560
else a shell settings put system user_rotation 1; w=2560; h=1600; fi
x=$((w / 2)); y1=$((h * 3 / 10)); y2=$((h * 8 / 10))
sleep 2
a shell dumpsys SurfaceFlinger --timestats -disable -clear >/dev/null
a shell dumpsys SurfaceFlinger --timestats -enable >/dev/null
# QS_ONLY=1 skips the app flings (fast A/B runs).
[[ -n ${QS_ONLY:-} ]] && apps=()
# ONLY=<regex> keeps only the apps whose package matches and skips the QS pulldown.
if [[ -n ${ONLY:-} ]]; then
	for i in "${!apps[@]}"; do [[ ${apps[i]%%|*} =~ $ONLY ]] || unset 'apps[i]'; done
fi
for entry in "${apps[@]}"; do
	pkg=${entry%%|*}; intent=${entry#*|}
	a shell "am start -W $intent" >/dev/null
	sleep 4
	a shell dumpsys gfxinfo "$pkg" reset >/dev/null
	for ((i = 0; i < flings; i++)); do
		# Alternate up/down flings through the middle of the portrait screen.
		if ((i % 2)); then a shell input swipe $x $y1 $x $y2 120; else a shell input swipe $x $y2 $x $y1 120; fi
		sleep 0.4
	done
	a shell dumpsys gfxinfo "$pkg" > "$out/gfxinfo-$pkg.txt"
	# Chrome draws in its GPU process, so its hwui count is small; the layer timeline below covers it.
	[[ $pkg == com.android.chrome ]] || require_frames "$out/gfxinfo-$pkg.txt" $((flings * 30)) "$pkg"
	{
		printf '%-40s ' "$pkg"
		grep -E 'Total frames rendered|Janky frames:|50th percentile|90th percentile|95th percentile|99th percentile|Number Missed Vsync|Number Frame deadline missed|Number Slow UI thread|Number Slow issue draw' \
			"$out/gfxinfo-$pkg.txt" | head -10 | sed 's/^ *//' | tr '\n' ';'
		echo
	} | tee -a "$out/summary.txt"
done
# Quick settings pulldown: shade, then full QS, then close, measured in SystemUI.
if [[ -z ${ONLY:-} ]]; then
a shell 'input keyevent HOME'
sleep 2
a shell dumpsys gfxinfo com.android.systemui reset >/dev/null
for ((i = 0; i < flings / 2; i++)); do
	a shell input swipe $x 2 $x $((h / 2)) 150      # notification shade
	sleep 0.6
	a shell input swipe $x $((h / 3)) $x $((h - 50)) 150  # expand quick settings
	sleep 0.6
	a shell input keyevent BACK
	sleep 0.6
done
a shell dumpsys gfxinfo com.android.systemui > "$out/gfxinfo-systemui-qs.txt"
require_frames "$out/gfxinfo-systemui-qs.txt" $((flings / 2 * 50)) "systemui (QS pulldown)"
{
	printf '%-40s ' "systemui (QS pulldown)"
	grep -E 'Total frames rendered|Janky frames:|50th percentile|90th percentile|95th percentile|99th percentile|Number Missed Vsync|Number Frame deadline missed|Number Slow UI thread|Number Slow issue draw' \
		"$out/gfxinfo-systemui-qs.txt" | head -10 | sed 's/^ *//' | tr '\n' ';'
	echo
} | tee -a "$out/summary.txt"
fi
a shell dumpsys SurfaceFlinger --timestats -dump > "$out/sf-timestats.txt"
a shell dumpsys SurfaceFlinger --timestats -disable >/dev/null
require_timestats "$out/sf-timestats.txt"
grep -E 'totalFrames|missedFrames|clientCompositionFrames|displayOnTime|jankPayload|totalTimelineFrames|jankyFrames|sfDeadlineMisses|appDeadlineMisses' \
	"$out/sf-timestats.txt" | head -20 | tee -a "$out/summary.txt"
# Chrome draws web content in its own GPU process, so hwui gfxinfo misses it: report
# SurfaceFlinger's per-layer frame timeline for Chrome's surfaces instead.
awk '/^layerName = /{n=$3} /^totalTimelineFrames = /{t[n]=$3} /^jankyFrames = /{j[n]=$3}
	END {for (k in t) if (k ~ /com.android.chrome\/(ChromeChildSurface|com.google.android.apps.chrome.Main)/)
		printf "%-40s timeline frames: %d; janky: %d (%.2f%%)\n", "chrome layer " substr(k, 1, 30), t[k], j[k], t[k] ? 100 * j[k] / t[k] : 0}' \
	"$out/sf-timestats.txt" | tee -a "$out/summary.txt"
echo "results: $out"

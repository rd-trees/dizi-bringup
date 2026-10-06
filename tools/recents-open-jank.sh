#!/bin/bash
# Opening an app from Recents: from home, enter overview, tap an app's task card (alternating
# between two apps, found by name in a UI dump), let the open animation finish, go home.
# The recents->app animation is driven by the launcher (quickstep), so its hwui stats count;
# SurfaceFlinger's frame timeline covers the display as a whole and the opened apps' layers.
# Works on user builds (no root). Usage: tools/recents-open-jank.sh <build-id> [cycles] [portrait|landscape]
set -uo pipefail
. "$(dirname "$0")/env"
R="$(dirname "$0")/remote.sh"
id=${1:?build-id}; cycles=${2:-10}; orient=${3:-landscape}
out=$DIZI_ROOT/logs/$id/recents-open-jank-$orient-$(date +%H%M%S)
mkdir -p "$out"
a() { "$R" adb "$@" </dev/null 2>/dev/null | tr -d '\r'; }
. "$(dirname "$0")/check.sh"
require_device
. "$(dirname "$0")/apps.sh"

a shell 'svc power stayon true; input keyevent WAKEUP; wm dismiss-keyguard; settings put system accelerometer_rotation 0'
if [[ $orient == portrait ]]; then a shell settings put system user_rotation 0
else a shell settings put system user_rotation 1; fi

# Populate recents; the last two are the ones reopened.
for intent in "$clock_intent" \
	"-a android.intent.action.MAIN -c android.intent.category.APP_CALCULATOR" \
	"-a android.intent.action.VIEW -d https://en.wikipedia.org/wiki/Android_version_history" \
	"-a android.settings.SETTINGS"; do
	a shell "am start -W $intent" >/dev/null
	sleep 2
done
a shell 'input keyevent HOME'
sleep 2
# RECENTS_TARGETS="Settings Calculator" compares ROMs with the same apps (the browser differs).
if [[ -n ${RECENTS_TARGETS:-} ]]; then read -ra targets <<<"$RECENTS_TARGETS"; else targets=(Settings "$browser_label"); fi

# Centre of the task card whose snapshot is labelled $1, from a UI dump of overview.
card() {
	a shell 'uiautomator dump /data/local/tmp/recents-open.xml >/dev/null; cat /data/local/tmp/recents-open.xml' |
		grep -o '<node [^>]*>' | grep 'id/snapshot' | grep -E "content-desc=\"$1( [^\"]*)?\"" | head -1 |
		sed -E 's/.*bounds="\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]".*/\1 \2 \3 \4/' |
		awk '{print int(($1 + $3) / 2), int(($2 + $4) / 2)}'
}

a shell dumpsys SurfaceFlinger --timestats -disable -clear >/dev/null
a shell dumpsys SurfaceFlinger --timestats -enable >/dev/null
a shell dumpsys gfxinfo "$launcher" reset >/dev/null
opened=0
for ((i = 0; i < cycles; i++)); do
	t=${targets[i % 2]}
	a shell 'input keyevent APP_SWITCH'      # home -> overview
	sleep 1.5
	xy=$(card "$t")                           # the dump is taken while overview is idle
	if [[ -z $xy ]]; then
		a shell 'input keyevent HOME'
		((opened == 0)) && die "cycle $i: no '$t' card in overview (RECENTS_TARGETS, or the warm-up apps didn't open)"
		echo "cycle $i: no $t card" >&2; sleep 1.5; continue
	fi
	a shell "input tap $xy"                   # overview -> app
	sleep 2
	top=$(top_package)
	echo "$t -> $top" >> "$out/resumed.txt"
	if [[ $top == "$launcher" || -z $top ]]; then
		a shell 'input keyevent HOME'
		((opened == 0)) && die "cycle $i: tapping the '$t' card didn't open it (top: ${top:-none})"
		echo "cycle $i: $t didn't open" >&2; sleep 1.5; continue
	fi
	opened=$((opened + 1))
	a shell 'input keyevent HOME'            # app -> home
	sleep 1.5
done
a shell dumpsys gfxinfo "$launcher" > "$out/gfxinfo-launcher.txt"
a shell dumpsys SurfaceFlinger --timestats -dump > "$out/sf-timestats.txt"
a shell dumpsys SurfaceFlinger --timestats -disable >/dev/null
{
	echo "opened from recents: $opened/$cycles"
	printf '%-40s ' "launcher (recents -> app, home)"
	grep -E 'Total frames rendered|Janky frames:|50th percentile|90th percentile|99th percentile|Number Missed Vsync|Number Slow UI thread|Number Frame deadline missed' \
		"$out/gfxinfo-launcher.txt" | head -8 | sed 's/^ *//' | tr '\n' ';'
	echo
	grep -E '^(totalFrames|missedFrames|clientCompositionFrames|totalTimelineFrames|jankyFrames|sfDeadlineMisses|appDeadlineMisses) =' \
		"$out/sf-timestats.txt" | head -7 | tr '\n' ';'
	echo
	# Per-layer frame timeline, summed over layer instances (name#N), busiest first.
	echo "frames janky  jank%  layer"
	awk '/^layerName = /{n=$3; sub(/#[0-9]+$/, "", n)} /^totalTimelineFrames = /{t[n]+=$3} /^jankyFrames = /{j[n]+=$3}
		END {for (k in t) if (t[k] >= 20) printf "%6d %6d %6.2f%%  %s\n", t[k], j[k], 100 * j[k] / t[k], (k == "" ? "(display)" : k)}' \
		"$out/sf-timestats.txt" | sort -rn | head -10
} | tee "$out/summary.txt"
echo "results: $out"
require_frames "$out/gfxinfo-launcher.txt" $((opened * 50)) "launcher ($launcher)"
require_timestats "$out/sf-timestats.txt"
((opened == cycles)) || die "only $opened/$cycles cycles opened an app; numbers in $out are partial"

#!/bin/bash
# Opening an app from a home screen icon and going back home: tap the icon labelled $label (found in a
# UI dump of home), wait for the launch animation, press HOME, repeat. The icon launch and the return
# are launcher-driven remote animations, so launcher gfxinfo and the SF frame timeline both count.
# Usage: tools/app-open-jank.sh <build-id> [cycles] [label]
# Without a label, the first of "Play Store", Photos, Gallery, Settings found on home is used.
set -uo pipefail
. "$(dirname "$0")/env"
R="$(dirname "$0")/remote.sh"
id=${1:?build-id}; cycles=${2:-10}; label=${3:-}
out=$DIZI_ROOT/logs/$id/app-open-jank-$(date +%H%M%S)
mkdir -p "$out"
a() { "$R" adb "$@" </dev/null 2>/dev/null | tr -d '\r'; }
. "$(dirname "$0")/check.sh"
require_device
. "$(dirname "$0")/apps.sh"

a shell 'svc power stayon true; input keyevent WAKEUP; wm dismiss-keyguard; settings put system accelerometer_rotation 0; settings put system user_rotation 1; input keyevent HOME'
sleep 2
home=$(a shell 'uiautomator dump /data/local/tmp/app-open.xml >/dev/null; cat /data/local/tmp/app-open.xml' | grep -o '<node [^>]*>')
icon() {
	grep -E "(text|content-desc)=\"$1\"" <<<"$home" | head -1 |
		sed -E 's/.*bounds="\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]".*/\1 \2 \3 \4/' |
		awk '{print int(($1 + $3) / 2), int(($2 + $4) / 2)}'
}
if [[ -z $label ]]; then
	for l in "Play Store" Photos Gallery Settings; do
		[[ -n $(icon "$l") ]] && { label=$l; break; }
	done
	[[ -n $label ]] || die "none of Play Store, Photos, Gallery, Settings is on the home screen; pass a label"
fi
xy=$(icon "$label")
[[ -n $xy ]] || die "no '$label' icon on the home screen"
echo "icon: $label at $xy" >&2
a shell dumpsys SurfaceFlinger --timestats -disable -clear >/dev/null
a shell dumpsys SurfaceFlinger --timestats -enable >/dev/null
a shell dumpsys gfxinfo "$launcher" reset >/dev/null
# Only the first cycle checks what opened: a dumpsys in every cycle would load system_server during
# the measurement. A later failure shows up as a low launcher frame count.
for ((i = 0; i < cycles; i++)); do
	a shell "input tap $xy"
	sleep 1.8
	if ((i == 0)); then
		top=$(top_package)
		[[ -n $top && $top != "$launcher" ]] || { a shell 'input keyevent HOME'; die "tapping '$label' didn't open an app (top: ${top:-none})"; }
	fi
	a shell 'input keyevent HOME'
	sleep 1.5
done
a shell dumpsys gfxinfo "$launcher" > "$out/gfxinfo-launcher.txt"
a shell dumpsys SurfaceFlinger --timestats -dump > "$out/sf-timestats.txt"
a shell dumpsys SurfaceFlinger --timestats -disable >/dev/null
{
	printf '%-40s ' "launcher (icon -> $label, home)"
	grep -E 'Total frames rendered|Janky frames:|50th percentile|90th percentile|99th percentile|Number Slow UI thread|Number Frame deadline missed' \
		"$out/gfxinfo-launcher.txt" | head -7 | sed 's/^ *//' | tr '\n' ';'
	echo
	grep -E '^(totalFrames|missedFrames|clientCompositionFrames|totalTimelineFrames|jankyFrames) =' \
		"$out/sf-timestats.txt" | head -5 | tr '\n' ';'
	echo
	echo "frames janky  jank%  layer"
	awk '/^layerName = /{n=$3; sub(/#[0-9]+$/, "", n)} /^totalTimelineFrames = /{t[n]+=$3} /^jankyFrames = /{j[n]+=$3}
		END {for (k in t) if (t[k] >= 20) printf "%6d %6d %6.2f%%  %s\n", t[k], j[k], 100 * j[k] / t[k], (k == "" ? "(display)" : k)}' \
		"$out/sf-timestats.txt" | sort -rn | head -6
} | tee "$out/summary.txt"
echo "results: $out"
require_frames "$out/gfxinfo-launcher.txt" $((cycles * 100)) "launcher ($launcher)"
require_timestats "$out/sf-timestats.txt"

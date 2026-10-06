#!/bin/bash
# App start benchmark over adb (quiet: no audio, dim screen).
#  cold: force-stop, then `am start -W`; median TotalTime of N runs per app.
#  swap (only with SWAP=1): open all apps once (memory pressure), then return to each,
#        reporting the launch state (HOT/WARM/COLD) and TotalTime. Returning apps whose
#        pages went to zram exercises the zram decompressor.
# Usage: [SWAP=1] tools/app-start.sh <build-id> [runs]
set -uo pipefail
. "$(dirname "$0")/env"
R="$(dirname "$0")/remote.sh"
id=${1:?build-id}; runs=${2:-5}
out=$DIZI_ROOT/logs/$id/app-start-$(date +%H%M%S)
mkdir -p "$out"
a() { "$R" adb "$@" </dev/null 2>/dev/null | tr -d '\r'; }

apps=(
	com.android.settings/.Settings
	com.google.android.deskclock/com.android.deskclock.DeskClock
	com.google.android.calculator/com.android.calculator2.Calculator
	com.google.android.apps.photos/.home.HomeActivity
	com.android.chrome/com.google.android.apps.chrome.Main
	com.google.android.apps.messaging/.ui.ConversationListActivity
	com.google.android.contacts/com.android.contacts.activities.PeopleActivity
	com.google.android.calendar/com.android.calendar.AllInOneActivity
	com.google.android.apps.maps/com.google.android.maps.MapsActivity
	com.android.vending/.AssetBrowserActivity
)
. "$(dirname "$0")/check.sh"
require_device
a shell 'settings put system screen_brightness 10'
ok=()
for c in "${apps[@]}"; do
	[[ $(a shell "cmd package resolve-activity --brief -c android.intent.category.LAUNCHER ${c%%/*}") == */* ]] && ok+=("$c")
done
((${#ok[@]} >= 5)) || die "only ${#ok[@]} of the ${#apps[@]} benchmark apps are installed"
echo "apps: ${#ok[@]} (${ok[*]%%/*})" >&2

median() { sort -n | awk '{v[NR]=$1} END {if (NR) print v[int((NR+1)/2)]; else print "-"}'; }
echo "== cold start, median of $runs (ms)" | tee "$out/summary.txt"
measured=0
for c in "${ok[@]}"; do
	pkg=${c%%/*}
	for ((i = 0; i < runs; i++)); do
		# Keep the whole am output: a launch only counts if it was COLD and ended in the app itself,
		# not in a permission dialog or other activity brought to the front.
		a shell "am force-stop $pkg; sleep 0.5; am start -W -n $c" |
			awk '/^LaunchState:/ {s=$2} /^Activity:/ {act=$2} /^TotalTime:/ {t=$2} END {print s, act, t}'
		a shell 'input keyevent HOME'; sleep 1
	done > "$out/cold-$pkg.raw"
	bad=$(awk -v p="$pkg" '$1 != "COLD" || index($2, p "/") != 1 || $3 == "" {print; exit}' "$out/cold-$pkg.raw")
	if [[ -n $bad ]]; then
		# Not a measurement of this app; leave it out and say why rather than report a wrong time.
		echo "skipped $pkg: launch was '${bad:-empty}' (state activity ms)" | tee -a "$out/summary.txt" >&2
		continue
	fi
	awk '{print $3}' "$out/cold-$pkg.raw" > "$out/cold-$pkg.txt"
	printf '%-45s %s\n' "$pkg" "$(median < "$out/cold-$pkg.txt")" | tee -a "$out/summary.txt"
	measured=$((measured + 1))
done
((measured >= 5)) || die "only $measured apps gave clean cold launches"
[[ -n ${SWAP:-} ]] || { echo "results: $out"; exit 0; }

echo "== return after opening all apps (state, ms)" | tee -a "$out/summary.txt"
for c in "${ok[@]}"; do a shell "am start -W -n $c" >/dev/null; sleep 2; done
a shell 'input keyevent HOME'; sleep 2
for c in "${ok[@]}"; do
	r=$(a shell "am start -W -n $c" | awk '/LaunchState|TotalTime/ {printf "%s ", $2}')
	printf '%-45s %s\n' "${c%%/*}" "$r" | tee -a "$out/summary.txt"
	a shell 'input keyevent HOME'; sleep 1
done
a shell 'cat /sys/block/zram0/comp_algorithm; cat /sys/block/zram0/mm_stat' | tee -a "$out/summary.txt"
echo "results: $out"

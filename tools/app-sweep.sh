#!/bin/bash
# Launch every launchable app once and report crashes/ANRs from the logs.
# Usage: tools/app-sweep.sh <build-id> [seconds-per-app]
set -uo pipefail
. "$(dirname "$0")/env"
R="$(dirname "$0")/remote.sh"
id=${1:?build-id}; wait=${2:-6}
out=$DIZI_ROOT/logs/$id/app-sweep-$(date +%H%M%S)
mkdir -p "$out"
a() { "$R" adb "$@" </dev/null 2>/dev/null | tr -d '\r'; }
# Binary output (screenshots): no \r stripping.
raw() { "$R" adb "$@" </dev/null 2>/dev/null; }

a shell 'svc power stayon true; input keyevent WAKEUP; wm dismiss-keyguard'
trap '"$(dirname "$0")/remote.sh" adb shell svc power stayon false </dev/null >/dev/null 2>&1' EXIT  # let the tablet idle (ART dexopt) again
a shell 'cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER' |
	grep '/' | sed 's/^ *//' | sort -u > "$out/activities.txt"
a logcat -c -b all
while read -r comp; do
	a shell "am start -n '$comp'" >/dev/null
	sleep "$wait"
	a shell "screencap -p /data/local/tmp/sweep.png"
	raw exec-out cat /data/local/tmp/sweep.png > "$out/$(echo "$comp" | tr '/' '_').png"
	a shell 'input keyevent HOME'
	sleep 1
done < "$out/activities.txt"
a logcat -d -b crash > "$out/crash.txt"
a logcat -d -b events | grep -E 'am_anr|am_crash' > "$out/anr-crash-events.txt"
{
	echo "apps launched: $(wc -l < "$out/activities.txt")"
	echo "crashing processes:"
	grep -a 'Process:' "$out/crash.txt" | sed 's/.*Process: //; s/, PID.*//' | sort | uniq -c | sort -rn
	echo "native crashes (tombstones):"
	grep -ac 'Build fingerprint' "$out/crash.txt"
	echo "ANRs:"
	grep -c am_anr "$out/anr-crash-events.txt"
} | tee "$out/summary.txt"
echo "results: $out"

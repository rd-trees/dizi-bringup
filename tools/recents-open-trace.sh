#!/bin/bash
# Perfetto trace of Recents -> app cycles: SF frame timeline, gfx/view/wm atrace, GPU and CPU
# frequency, and RPHASE logcat markers (overview/open/home/idle) to split the jank by phase.
# Works on user builds. Usage: tools/recents-open-trace.sh <build-id> [cycles] [landscape|portrait]
# Analyse with trace_processor_shell (evox/prebuilts/tools/linux-x86_64/perfetto/).
set -euo pipefail
. "$(dirname "$0")/env"
R="$(dirname "$0")/remote.sh"
id=${1:?build-id}; cycles=${2:-6}; orient=${3:-landscape}
out=$DIZI_ROOT/logs/$id/recents-open-trace-$orient-$(date +%H%M%S)
mkdir -p "$out"
a() { "$R" adb "$@" </dev/null 2>/dev/null | tr -d '\r'; }
. "$(dirname "$0")/check.sh"
require_device
. "$(dirname "$0")/apps.sh"
a shell "settings put system accelerometer_rotation 0; settings put system user_rotation $([[ $orient == portrait ]] && echo 0 || echo 1)"
dev=/data/misc/perfetto-traces/recents-open.pftrace

# Populate recents the same way recents-open-jank.sh does (the cards are found by name).
for intent in "$clock_intent" \
	"-a android.intent.action.MAIN -c android.intent.category.APP_CALCULATOR" \
	"-a android.intent.action.VIEW -d https://en.wikipedia.org/wiki/Android_version_history" \
	"-a android.settings.SETTINGS"; do
	a shell "am start -W $intent" >/dev/null
	sleep 2
done
a shell 'input keyevent HOME'
sleep 2

a shell "rm -f $dev"
ssh -i "$DIZI_SSH_KEY" "$DIZI_HOST" \
	"/opt/homebrew/bin/adb -s $DIZI_SERIAL shell perfetto --txt -c - -o $dev --background" \
	< "${CFG:-$DIZI_ROOT/tools/perfetto/recents-open.pbtxt}" >/dev/null
sleep 2
a shell 'svc power stayon true; input keyevent WAKEUP; wm dismiss-keyguard; input keyevent HOME'
sleep 2
opened=0
for ((i = 0; i < cycles; i++)); do
	t=$( ((i % 2)) && echo "$browser_label" || echo Settings )
	xy=$(a shell 'log -t RPHASE overview; input keyevent APP_SWITCH; sleep 1.5; uiautomator dump /data/local/tmp/o.xml >/dev/null; cat /data/local/tmp/o.xml' |
		grep -o '<node [^>]*>' | grep 'id/snapshot' | grep -E "content-desc=\"$t( [^\"]*)?\"" | head -1 |
		sed -E 's/.*bounds="\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]".*/\1 \2 \3 \4/' |
		awk '{print int(($1 + $3) / 2), int(($2 + $4) / 2)}' || true)
	if [[ -z $xy ]]; then
		((i == 0)) && { a shell 'pkill -INT perfetto'; die "cycle 0: no $t card in overview"; }
		echo "cycle $i: no $t card" >&2; continue
	fi
	opened=$((opened + 1))
	a shell "log -t RPHASE open; input tap $xy; sleep 2; log -t RPHASE home; input keyevent HOME; sleep 1.5; log -t RPHASE idle"
done
sleep 1
a shell 'pkill -INT perfetto' || true  # already stopped if the cycles outlast duration_ms
sleep 4
ssh -i "$DIZI_SSH_KEY" "$DIZI_HOST" "/opt/homebrew/bin/adb -s $DIZI_SERIAL exec-out cat $dev" > "$out/trace.pftrace"
size=$(stat -c %s "$out/trace.pftrace")
((size > 1000000)) || die "trace is only $size bytes"
((opened == cycles)) || die "only $opened of $cycles cycles found their card"
echo "trace: $((size / 1048576)) MB, $opened cycles, $orient"
echo "results: $out"

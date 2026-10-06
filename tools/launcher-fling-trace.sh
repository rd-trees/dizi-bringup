#!/bin/bash
# Perfetto trace of the launcher part of ui-jank.sh: from home, alternate up/down swipes through the
# middle of the screen (opens and closes all apps), with FPHASE logcat markers per swipe.
# Same config as recents-open-trace.sh. Usage: tools/launcher-fling-trace.sh <build-id> [swipes]
set -euo pipefail
. "$(dirname "$0")/env"
R="$(dirname "$0")/remote.sh"
id=${1:?build-id}; swipes=${2:-12}
out=$DIZI_ROOT/logs/$id/launcher-fling-trace-$(date +%H%M%S)
mkdir -p "$out"
a() { "$R" adb "$@" </dev/null 2>/dev/null | tr -d '\r'; }
dev=/data/misc/perfetto-traces/launcher-fling.pftrace

a shell 'svc power stayon true; input keyevent WAKEUP; wm dismiss-keyguard; settings put system accelerometer_rotation 0; settings put system user_rotation 1; input keyevent HOME'
trap '"$(dirname "$0")/remote.sh" adb shell svc power stayon false </dev/null >/dev/null 2>&1' EXIT  # let the tablet idle (ART dexopt) again
w=2560; h=1600; x=$((w / 2)); y1=$((h * 3 / 10)); y2=$((h * 8 / 10))
sleep 2
a shell "rm -f $dev"
ssh -i "$DIZI_SSH_KEY" "$DIZI_HOST" \
	"/opt/homebrew/bin/adb -s $DIZI_SERIAL shell perfetto --txt -c - -o $dev --background" \
	< "${CFG:-$DIZI_ROOT/tools/perfetto/recents-open.pbtxt}" >/dev/null
sleep 2
for ((i = 0; i < swipes; i++)); do
	if ((i % 2)); then
		a shell "log -t FPHASE down; input swipe $x $y1 $x $y2 120"
	else
		a shell "log -t FPHASE up; input swipe $x $y2 $x $y1 120"
	fi
	sleep 0.6
done
a shell 'log -t FPHASE idle; input keyevent HOME'
sleep 1
a shell 'pkill -INT perfetto' || true
sleep 4
ssh -i "$DIZI_SSH_KEY" "$DIZI_HOST" "/opt/homebrew/bin/adb -s $DIZI_SERIAL exec-out cat $dev" > "$out/trace.pftrace"
ls -l "$out/trace.pftrace"
echo "results: $out"

#!/bin/bash
# Reboot repeatedly and check the display pipeline after each boot, to catch the
# intermittent "44 ms per frame" composer state seen on b27 and b31. Each boot:
# short QS jank run plus MDP clock samples during a pulldown. On a bad boot
# (QS jank > 20%), capture a perfetto trace, SurfaceFlinger dump, composer logcat
# and dmesg. Quiet: dim screen, no sound.
# Usage: tools/boot-health.sh <build-id> [boots]
set -uo pipefail
. "$(dirname "$0")/env"
T=$(dirname "$0")
R="$T/remote.sh"
id=${1:?build-id}; boots=${2:-8}
out=$DIZI_ROOT/logs/$id/boot-health-$(date +%H%M%S)
mkdir -p "$out"
a() { "$R" adb "$@" </dev/null 2>/dev/null | tr -d '\r'; }
raw() { "$R" adb "$@" </dev/null 2>/dev/null; }
booted() { [[ $(a shell getprop sys.boot_completed) == 1 ]]; }

for ((n = 1; n <= boots; n++)); do
	a reboot
	sleep 30
	for _ in $(seq 100); do booted && break; sleep 3; done
	sleep 40
	a root >/dev/null; sleep 5
	a shell 'settings put system screen_brightness_mode 0; settings put system screen_brightness 10; svc power stayon true; input keyevent WAKEUP; wm dismiss-keyguard; input keyevent BACK; input keyevent HOME'
	trap '"$(dirname "$0")/remote.sh" adb shell svc power stayon false </dev/null >/dev/null 2>&1' EXIT  # let the tablet idle (ART dexopt) again
	mdp=$(a shell 'c=/sys/kernel/debug/clk/disp_cc_mdss_mdp_clk/clk_rate; (for i in $(seq 1 20); do cat $c; sleep 0.05; done > /data/local/tmp/mdp.txt &); input swipe 1280 2 1280 800 150; sleep 0.4; input swipe 1280 533 1280 1550 150; sleep 1; input keyevent BACK; sort /data/local/tmp/mdp.txt | uniq -c | tr "\n" " "')
	dfps=$(a shell 'cat /sys/devices/virtual/mi_display/disp_feature/disp-DSI-0/dynamic_fps')
	modes=$(a shell 'dmesg | grep -cE "dsi_display_set_mode"')
	QS_ONLY=1 "$T/ui-jank.sh" "$id" 6 landscape > "$out/qs-$n.txt" 2>&1
	jank=$(grep -oE 'Janky frames: [0-9]+ \(([0-9.]+)%' "$out/qs-$n.txt" | head -1 | sed -E 's/.*\(([0-9.]+)%/\1/')
	line="boot $n: QS jank ${jank:-?}%  dynamic_fps=$dfps  mode sets=$modes  mdp during pulldown: $mdp"
	echo "$line" | tee -a "$out/summary.txt"
	if [[ -n $jank ]] && awk -v j="$jank" 'BEGIN { exit !(j > 20) }'; then
		echo "  BAD boot $n: capturing" | tee -a "$out/summary.txt"
		d=$out/bad-$n; mkdir -p "$d"
		a shell dumpsys SurfaceFlinger > "$d/sf.txt"
		a shell 'dmesg' > "$d/dmesg.txt"
		a logcat -d -b all > "$d/logcat.txt"
		a shell 'getprop' > "$d/getprop.txt"
		a shell 'for c in disp_cc_mdss_mdp_clk disp_cc_mdss_ahb_clk; do echo "$c $(cat /sys/kernel/debug/clk/$c/clk_rate)"; done; cat /sys/class/kgsl/kgsl-3d0/devfreq/cur_freq' > "$d/clocks.txt"
		raw push "$DIZI_REMOTE_DIR/qs-trace2.cfg" /data/misc/perfetto-configs/qs-trace2.cfg >/dev/null
		a shell '(perfetto --txt -c /data/misc/perfetto-configs/qs-trace2.cfg -o /data/misc/perfetto-traces/bad.pftrace >/dev/null 2>&1 &); sleep 1; for i in 1 2 3; do input swipe 1280 2 1280 800 150; sleep 0.6; input swipe 1280 533 1280 1550 150; sleep 0.6; input keyevent BACK; sleep 0.6; done; sleep 5'
		raw exec-out cat /data/misc/perfetto-traces/bad.pftrace > "$d/bad.pftrace"
	fi
done
echo "results: $out"

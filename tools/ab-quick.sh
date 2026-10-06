#!/bin/bash
# One line of jank numbers for the launcher transition paths, for quick A/B runs: Recents -> app and
# icon -> app (CYCLES each, default 5, warm), launcher hwui janky % and SF display timeline janky %.
# Stops with the sub-test's reason if either run fails, instead of printing empty fields.
# Usage: tools/ab-quick.sh <build-id> <label>
set -uo pipefail
. "$(dirname "$0")/env"
T=$(dirname "$0")
id=${1:?build-id}; label=${2:?label}; cycles=${CYCLES:-5}
log=$DIZI_ROOT/logs/$id/ab-quick.log
mkdir -p "$DIZI_ROOT/logs/$id"
pct() { grep -oE "Janky frames: [0-9]+ \([0-9.]+%\)" "$1" | grep -oE "[0-9.]+%" | head -1; }
disp() { awk '$4 == "(display)" {print $3}' "$1" | head -1; }

# Run one sub-test; print its results dir, or its FAILED line and stop.
run() {
	local name=$1 tmp rc; shift
	tmp=$(mktemp)
	echo "== $label: $name" >>"$log"
	"$@" >"$tmp" 2>>"$log"
	rc=$?
	cat "$tmp" >>"$log"
	if ((rc != 0)); then
		echo "$label: $name FAILED: $(grep '^FAILED:' "$log" | tail -1 | sed 's/^FAILED: //')" >&2
		rm -f "$tmp"
		exit 1
	fi
	awk '/^results:/ {print $2}' "$tmp"
	rm -f "$tmp"
}
r=$(run recents "$T/recents-open-jank.sh" "$id" "$cycles") || exit 1
o=$(run icon-open "$T/app-open-jank.sh" "$id" "$cycles") || exit 1
line=$(printf '%-28s recents: launcher %-7s display %-7s | icon-open: launcher %-7s display %-7s' "$label" \
	"$(pct "$r/summary.txt")" "$(disp "$r/summary.txt")" "$(pct "$o/summary.txt")" "$(disp "$o/summary.txt")")
echo "$line" | tee -a "$DIZI_ROOT/logs/$id/ab-quick.txt"

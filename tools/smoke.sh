#!/bin/bash
# Two-minute dry run of the measurement scripts, before any long session: every test once at its
# smallest size, each with its own checks (device state, apps found, frames counted). Prints PASS
# or the first failure.
# Usage: tools/smoke.sh <build-id>
set -uo pipefail
. "$(dirname "$0")/env"
T=$(dirname "$0")
R="$T/remote.sh"
id=${1:?build-id}
a() { "$R" adb "$@" </dev/null 2>/dev/null | tr -d '\r'; }
. "$T/check.sh"

start=$SECONDS
require_device
echo "build: $(a shell getprop ro.build.fingerprint)"
echo "vendor built: $(a shell getprop ro.vendor.build.date)"
echo "selinux: $(a shell getenforce); refresh: $(a shell dumpsys display | grep -m1 -oE 'renderFrameRate [0-9.]+')"

CYCLES=2 "$T/ab-quick.sh" "$id-smoke" smoke || die "ab-quick (see logs/$id-smoke/ab-quick.log)"
"$T/ui-jank.sh" "$id-smoke" 2 >/dev/null || die "ui-jank (rerun tools/ui-jank.sh $id-smoke 2 to see why)"
"$T/app-start.sh" "$id-smoke" 1 >/dev/null || die "app-start (rerun tools/app-start.sh $id-smoke 1 to see why)"
echo "PASS in $((SECONDS - start)) s; smoke results are under logs/$id-smoke, not logs/$id"

# Sourced by the measurement scripts after a() is defined. Each check prints why it failed and
# exits non-zero, so a broken run stops in seconds instead of producing empty or partial numbers.

die() {
	echo "FAILED: $*" >&2
	exit 1
}

# The tablet is reachable, booted, awake and unlocked.
require_device() {
	[[ $(a get-state) == device ]] || die "no adb device (is the tablet connected?)"
	[[ $(a shell getprop sys.boot_completed) == 1 ]] || die "boot not completed"
	a shell 'svc power stayon true; input keyevent WAKEUP; wm dismiss-keyguard' >/dev/null
	# Give the screen timeout back afterwards: with stayon left on, the tablet never goes idle on
	# the charger, so ART's nightly background dexopt never runs and apps stay uncompiled.
	trap '"$(dirname "${BASH_SOURCE[0]}")/remote.sh" adb shell svc power stayon false </dev/null >/dev/null 2>&1' EXIT
	# Capture before matching: with pipefail, `dumpsys | grep -q` fails when grep exits early and
	# dumpsys gets SIGPIPE, which looks like "no match".
	local out
	out=$(a shell dumpsys power)
	[[ $out == *mWakefulness=Awake* ]] || die "screen is not on"
	out=$(a shell dumpsys window)
	if [[ $out =~ mDreamingLockscreen=true|isKeyguardShowing=true ]]; then
		die "keyguard is showing (unlock the tablet)"
	fi
	a shell input keyevent HOME >/dev/null
	sleep 1
	home_in_focus
}

# Wait until the framework is back after `stop; start`, then let the launcher settle.
# sys.boot_completed stays 1 across a framework restart, so wait for a system_server other than
# $1 (its pid before the restart; empty = any), the activity service and a resumed home activity.
wait_boot() {
	local old=${1:-} i pid
	for ((i = 0; i < 90; i++)); do
		sleep 2
		# adb can drop for a moment while the framework restarts; under set -e a failed
		# assignment would end the script, so failures just mean "not yet".
		pid=$(a shell pidof system_server) || continue
		[[ -n $pid && $pid != "$old" ]] || continue
		[[ $(a shell service check activity) == *": found"* ]] || continue
		a shell input keyevent HOME >/dev/null || continue
		[[ -n $(top_package) ]] || continue
		sleep 10
		home_in_focus
		return 0
	done
	die "framework did not come back within 3 min"
}

# The window in focus, e.g. "com.android.settings/...UsbModeChooserActivity".
focus() {
	a shell dumpsys window | awk '/mCurrentFocus=/ && !n++ { sub(/.*mCurrentFocus=/, ""); print }'
}

# Home has focus. Dialogs that pop up after a framework restart (the "Use USB for" chooser, a
# crash dialog) get a BACK; anything still covering home stops the run, since taps would hit it.
home_in_focus() {
	local i f
	for ((i = 0; i < 3; i++)); do
		f=$(focus)
		[[ $f == *launcher* ]] && return 0
		echo "closing $f" >&2
		a shell input keyevent BACK >/dev/null
		sleep 1
		a shell input keyevent HOME >/dev/null
		sleep 2
	done
	die "something covers the home screen: $(focus)"
}

# Total frames rendered in a gfxinfo dump: at least $2.
require_frames() {
	local file=$1 min=$2 what=$3 n
	n=$(grep -m1 -oE 'Total frames rendered: [0-9]+' "$file" | grep -oE '[0-9]+$')
	[[ -n $n && $n -ge $min ]] || die "$what: ${n:-no} frames in gfxinfo (want >= $min; wrong package or the UI didn't move?)"
}

# The SF timestats dump has a display timeline.
require_timestats() {
	local n
	n=$(grep -m1 -E '^totalTimelineFrames = ' "$1" | grep -oE '[0-9]+$')
	[[ -n $n && $n -gt 0 ]] || die "SF timestats are empty ($1)"
}

# The package currently in front.
top_package() {
	a shell dumpsys activity activities | awk '/topResumedActivity/ && !n++ {
		if (match($0, /[a-zA-Z0-9_.]+\//)) print substr($0, RSTART, RLENGTH - 1) }'
}

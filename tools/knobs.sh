#!/bin/bash
# Live performance experiments that need no build (research/pixel-graphene.md action numbers).
# "on" saves each node's or prop's current value on the tablet before writing it; "off" puts the
# saved values back. Nothing survives a reboot except the dex2oat/ISA props, which "off" clears.
#
# Usage: tools/knobs.sh <knob> on|off|show [arg]
#        tools/knobs.sh list
#
#   powerhint <variant>  power HAL config from the cnb device tree: fix (cnb-10's powerhint.json),
#                        old, trim, launch, frame; restarts the HAL. "off" goes back to the build's
#   walt120              #1  WALT window 8 ms (2 ticks) + predictive load, as stock at 120 Hz
#   stockfps             #1+ all of stock's 120 Hz boost 0x109B: adds the RTG and low-latency
#                        settings, a silver 806 MHz floor and 3 golds online
#   stocksched           stockfps without the floors: the WALT/RTG scheduler settings only
#   stockfloor           stockfps floors only: 3 golds online, silver min 806 MHz
#   gpumod [percent]     #22 kgsl TZ governor busy-time multiplier (default 200)
#   irqpin               #23 msm_drm IRQ on CPU2, kgsl_3d0_irq on CPU1; stops msm_irqbalance
#   sfadpf               #2  SurfaceFlinger ADPF hints (restarts the framework)
#   regionsamp [ms]      SF region sampling period and idle timeout (default 500 ms, AOSP 100);
#                        "regionsamp 0" turns luma sampling off entirely. Restarts the framework
#   layercache           SF planner: flatten layers that stopped updating into one cached buffer, so
#                        they take one display pipe instead of several (restarts the framework)
#   prop <name=value>    any property read at framework start (debug.sf.*, debug.renderengine.*,
#                        debug.hwui.*); restarts the framework
#   latsens              #31 top-app cpu.uclamp.latency_sensitive
#   wmark                #10 vm.watermark_scale_factor 200
#   wboost               #26 vm.watermark_boost_factor 0
#   dexopt               #6  dex2oat off the prime core, bg-dexopt concurrency 2
#   isa                  #9  ART ISA variant cortex-a76 (recompile an app to take effect)
set -euo pipefail
. "$(dirname "$0")/env"
R="$(dirname "$0")/remote.sh"

knob=${1:?knob (or list)}
if [[ $knob == list ]]; then
	sed -n '/^#   [a-z]/,/^set /s/^#   //p' "$0"
	exit 0
fi
mode=${2:?on|off|show}
arg=${3:-}

# Device-side helpers (POSIX sh, run by the tablet's mksh). f <path> <value> writes a node and
# p <prop> <value> sets a prop; each records the old value in $S the first time, so running "on"
# twice still restores the real original.
lib='
S=/data/local/tmp/knobs/'"$knob"'
'"$(cat "$(dirname "$0")/nsbind.sh")"'
mkdir -p /data/local/tmp/knobs
f() {
	case $MODE in
	on) [ -e "$1" ] || { echo "missing: $1"; return; }
	    grep -q "^f|$1|" $S 2>/dev/null || echo "f|$1|$(cat "$1")" >> $S
	    echo "$2" > "$1" || echo "write failed: $1"
	    v=$(cat "$1"); echo "$1 = $v"
	    # The kernel may round or clamp (frequencies); flag it so the A/B is not silently different.
	    [ "$v" = "$2" ] || echo "differs: $1 wanted $2, reads $v" ;;
	show) echo "$1 = $(cat "$1" 2>/dev/null)" ;;
	esac
}
p() {
	case $MODE in
	on) grep -q "^p|$1|" $S 2>/dev/null || echo "p|$1|$(getprop "$1")" >> $S
	    setprop "$1" "$2"; v=$(getprop "$1"); echo "$1 = $v"
	    [ "$v" = "$2" ] || echo "write failed: $1 (setprop refused; reads $v)" ;;
	show) echo "$1 = $(getprop "$1")" ;;
	esac
}
restore() {
	[ -f $S ] || { echo "nothing saved"; return; }
	while IFS="|" read -r kind key val; do
		if [ "$kind" = f ]; then echo "$val" > "$key"; echo "$key = $(cat "$key")"
		else setprop "$key" "$val"; echo "$key = $(getprop "$key")"; fi
	done < $S
	rm $S
}
irq() { grep -E " $1\$" /proc/interrupts | head -1 | cut -d: -f1 | tr -d " "; }
'

post=:
case $knob in
powerhint)
	# Bind-mount the variant over /vendor/etc/powerhint.json in init's mount namespace, so this
	# also works on builds without the variants in /vendor/etc; "off" unmounts it.
	v=${arg:-old}
	body='f=/vendor/etc/powerhint.json
	      [ "$MODE" = show ] || nsunbind $f
	      if [ "$MODE" = on ]; then
	          src=/data/local/tmp/'"powerhint-$v.json"'
	          chcon u:object_r:vendor_configs_file:s0 $src
	          nsbind $src $f || echo "mount failed: $f"
	          want=$(sha256sum $src | cut -d" " -f1)
	          for p in 1 $(pidof surfaceflinger) $(pidof vold); do
	              [ "$(nsenter -t $p -m -- sha256sum $f | cut -d" " -f1)" = "$want" ] ||
	                  echo "write failed: $f does not show '"$v"' in the mount namespace of pid $p"
	          done
	      fi'
	[[ $v == launch ]] && body+='
	      [ "$MODE" = on ] && /data/adb/ksu/bin/ksud sepolicy patch \
	          "allow hal_power_default vendor_sysfs_scsi_host file { open read write getattr }" 2>/dev/null; :'
	post='[ "$MODE" = show ] && { for p in 1 $(pidof vold) $(pidof android.hardware.power-service.lineage-libperfmgr); do
	          echo "pid $p: $(nsenter -t $p -m -- sha256sum /vendor/etc/powerhint.json)"; done; exit 0; }
	      old=$(pidof android.hardware.power-service.lineage-libperfmgr)
	      stop vendor.power-hal-aidl; start vendor.power-hal-aidl; sleep 2
	      new=$(pidof android.hardware.power-service.lineage-libperfmgr)
	      [ -n "$new" ] && [ "$new" != "$old" ] || echo "write failed: the power HAL did not restart"
	      echo "power HAL pid $old -> $new"'
	;;
walt120)
	body='f /proc/sys/walt/sched_ravg_window_nr_ticks 2
	      for c in 0 4; do f /sys/devices/system/cpu/cpufreq/policy$c/walt/pl 1; done'
	;;
stockfps)
	body='f /proc/sys/walt/sched_ravg_window_nr_ticks 2
	      for c in 0 4; do f /sys/devices/system/cpu/cpufreq/policy$c/walt/pl 1; done
	      f /proc/sys/walt/walt_rtg_cfs_boost_prio 119
	      f /proc/sys/walt/sched_coloc_downmigrate_ns 100000000
	      f /proc/sys/walt/walt_low_latency_task_threshold 100
	      f /proc/sys/walt/sched_min_task_util_for_colocation 0
	      f /proc/sys/walt/sched_min_task_util_for_boost 0
	      f /proc/sys/walt/sched_coloc_busy_hysteresis_enable_cpus 112
	      f /sys/devices/system/cpu/cpu4/core_ctl/min_cpus 3
	      f /sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq 806400'
	;;
stocksched)
	body='f /proc/sys/walt/sched_ravg_window_nr_ticks 2
	      for c in 0 4; do f /sys/devices/system/cpu/cpufreq/policy$c/walt/pl 1; done
	      f /proc/sys/walt/walt_rtg_cfs_boost_prio 119
	      f /proc/sys/walt/sched_coloc_downmigrate_ns 100000000
	      f /proc/sys/walt/walt_low_latency_task_threshold 100
	      f /proc/sys/walt/sched_min_task_util_for_colocation 0
	      f /proc/sys/walt/sched_min_task_util_for_boost 0
	      f /proc/sys/walt/sched_coloc_busy_hysteresis_enable_cpus 112'
	;;
stockfloor)
	body='f /sys/devices/system/cpu/cpu4/core_ctl/min_cpus 3
	      f /sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq 806400'
	;;
gpumod)
	body="f /sys/class/kgsl/kgsl-3d0/devfreq/mod_percent ${arg:-200}"
	;;
irqpin)
	body='d=$(irq msm_drm); k=$(irq kgsl_3d0_irq); echo "msm_drm irq $d, kgsl_3d0_irq irq $k"
	      [ "$MODE" = on ] && stop vendor.msm_irqbalance
	      f /proc/irq/$d/smp_affinity_list 2
	      f /proc/irq/$k/smp_affinity_list 1'
	post='[ "$MODE" = off ] && start vendor.msm_irqbalance; :'
	;;
sfadpf)
	body='p debug.sf.enable_adpf_cpu_hint true'
	post='[ "$MODE" = show ] || { stop; start; echo "framework restarted"; }'
	;;
regionsamp)
	if [[ ${arg:-500} == 0 ]]; then
		body='p debug.sf.luma_sampling 0'
	else
		ns=$((${arg:-500} * 1000000))
		body="p debug.sf.region_sampling_period_ns $ns
		      p debug.sf.region_sampling_timer_timeout_ns $ns"
	fi
	post='[ "$MODE" = show ] || { stop; start; echo "framework restarted"; }'
	;;
layercache)
	body='p debug.sf.enable_layer_caching 1'
	post='[ "$MODE" = show ] || { stop; start; echo "framework restarted"; }'
	;;
prop)
	[[ $mode == off || $arg == *=* ]] || { echo "prop needs name=value" >&2; exit 1; }
	body="p ${arg%%=*} ${arg#*=}"
	post='[ "$MODE" = show ] || { stop; start; echo "framework restarted"; }'
	;;
latsens)
	body='f /dev/cpuctl/top-app/cpu.uclamp.latency_sensitive 1'
	;;
wmark)
	body='f /proc/sys/vm/watermark_scale_factor 200'
	;;
wboost)
	body='f /proc/sys/vm/watermark_boost_factor 0'
	;;
dexopt)
	body='p dalvik.vm.background-dex2oat-cpu-set 0,1,2,3
	      p dalvik.vm.background-dex2oat-threads 4
	      p dalvik.vm.dex2oat-cpu-set 0,1,2,3,4,5,6
	      p pm.dexopt.bg-dexopt.concurrency 2'
	;;
isa)
	body='p dalvik.vm.isa.arm64.variant cortex-a76'
	;;
*)
	echo "unknown knob: $knob (try: $0 list)" >&2
	exit 1
	;;
esac

case $mode in
on | show) script="$lib MODE=$mode; $body; $post" ;;
off) script="$lib MODE=off; restore; $post" ;;
*) echo "mode: on|off|show" >&2; exit 1 ;;
esac

a() { "$R" adb "$@" </dev/null 2>/dev/null | tr -d '\r'; }
. "$(dirname "$0")/check.sh"
# Root: adbd as root on userdebug builds, KernelSU/Magisk su on user builds.
"$R" adb root >/dev/null 2>&1 || true
"$R" adb wait-for-device
if [[ $(a shell id -u) == 0 ]]; then
	sh=sh
elif [[ $(a shell su -c id -u) == 0 ]]; then
	sh="su -c sh"
else
	die "no root (adb root and su both failed)"
fi
if [[ $knob == powerhint && $mode == on ]]; then
	if [[ ${arg:-old} == fix ]]; then
		json=$DIZI_ROOT/evox-cnb/device/xiaomi/dizi/configs/power/powerhint.json
	else
		json=$DIZI_ROOT/evox-cnb/device/xiaomi/dizi/configs/power/powerhint-${arg:-old}.json
	fi
	[[ -f $json ]] || die "no such variant: $json"
	"$R" adb shell "cat > /data/local/tmp/powerhint-${arg:-old}.json" <"$json"
fi
"$R" adb shell "cat > /data/local/tmp/knobs.sh" <<<"$script"
ss=$(a shell pidof system_server)
result=$("$R" adb shell "$sh /data/local/tmp/knobs.sh" </dev/null | tr -d '\r')
echo "$result"
# A knob that restarted the framework isn't ready until the new system_server is up.
if [[ $mode != show && $post == *"stop; start"* ]]; then
	wait_boot "$ss"
	echo "framework back"
fi
if grep -qE '^(missing|write failed|mount failed):' <<<"$result"; then
	die "$knob $mode: not every node was written (see above)"
fi

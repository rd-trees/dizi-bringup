# Jank flight recorder: metrics and data sources (root, SM7435 / Adreno 710, Android 16/17)

Research date: 2026-09-29. Target: a root app on dizi (kernel 5.10 GKI, KernelSU/Magisk, SELinux enforcing, `su` unrestricted).

**How this was checked.** Most claims come from source code: the local Android 16 tree (`/build/alex/dizi/evox`,
EvoX bka, which ships **perfetto v51.2**), the Android 17 tree (`/build/alex/dizi/evox-cnb`, **perfetto v54.0**), the device
kernel (`/build/alex/dizi/kernel/lineage`, with display modules in `kernel/lineage-modules`), the stock vendor dump
(`/build/alex/dizi/stock/dump`), and upstream perfetto `main` (v58.3, from github.com/google/perfetto). Upstream docs are
linked where they exist.

Tags:
- **[src]**: read in the source.
- **[doc]**: read in the official docs.
- **[UNVERIFIED]**: not checked on the tablet (it was offline during this research), or taken from secondary sources.

---

## 0. Findings that change the design

1. **Most Qualcomm ftrace events are blocked for the system `traced_probes` on user builds.** It can only enable events
   whose tracefs files have the `debugfs_tracing` label. That allowlist is in
   `system/sepolicy/private/genfs_contexts` [src]. It includes `sched/*` (the main ones), `power/cpu_frequency`,
   `power/gpu_frequency`, `power/gpu_work_period`, `power/cpu_idle`, `power/suspend_resume`, `binder/*`, `dma_fence/`,
   `fence/`, `sync/`, `thermal/thermal_temperature`, `thermal/cdev_update`, `gpu_mem/gpu_mem_total`, `vmscan/*`,
   `lowmemorykiller/`, `oom/*`, `kmem/rss_stat`, `ftrace/print`, `irq/`, `ipi/`, `clk/*`, `cpuhp/*` and `cgroup/`.
   - Everything else has the `debugfs_tracing_debug` label. `traced_probes` only gets write access to that label under
     `userdebug_or_eng` (`private/traced_probes.te`) [src]. Blocked on user builds: `kgsl/*`, `sde/*`, `dcvs/*`,
     `dcvsh/*`, `devfreq/*`, `schedwalt/*`, `mdss/*`.
   - The stock vendor policy does not relabel any of them (`stock/dump/vendor/etc/selinux/vendor_sepolicy.cil`) [src].
   - Fix (pick one):
     - Add a KernelSU policy rule, for example
       `ksud sepolicy patch "allow traced_probes debugfs_tracing_debug file { open read write getattr }"` (and `dir`).
     - Run your own `traced` and `traced_probes` (or `tracebox`) as root.
     - Test on userdebug.
   - [UNVERIFIED on device]
2. **InteractionJankMonitor (CUJs) is off on user builds by default.** In the code,
   `DEFAULT_ENABLED = Build.IS_DEBUGGABLE` (`frameworks/base/core/java/com/android/internal/jank/InteractionJankMonitor.java:100`) [src].
   Turn it on with `device_config put interaction_jank_monitor enabled true`.
   - When a CUJ crosses its threshold (≥3 missed frames or a frame ≥64 ms, by default), it **already fires a Perfetto
     trigger** named `com.android.telemetry.interaction-jank-monitor-<cujType>` through `/system/bin/trigger_perfetto`.
     The trigger is throttled to one per trigger name every 5 minutes (`PerfettoTrigger.java`) [src].
   - This makes it a ready-made jank trigger for a STOP_TRACING or CLONE_SNAPSHOT flight recorder.
3. **`android.input.inputevent` is only registered when `ro.debuggable=1`.** See
   `inputflinger/trace/InputTracingThreadedBackend.cpp:41` [src]. On user builds, get input latency from the atrace
   `input` category instead (the `android_input_events` stdlib table).
4. **The HWUI "Davey!" log line is commented out in the EvoX Android 16 tree.** This is an EvoX change, not AOSP
   (`libs/hwui/JankTracker.cpp:244`). It is still active in the Android 17 (cnb) tree [src]. Choreographer
   "Skipped N frames!" still works: the threshold is `debug.choreographer.skipwarning`, default 30.
5. **Both device perfetto versions (v51 and v54) support `--clone-by-name` and `CLONE_SNAPSHOT` (value 4).** They also
   write numbered files on clone triggers (`out.0`, `out.1`, …) [src]. The prebuilt `android-arm64.zip` from perfetto
   GitHub releases (v58.x) also works as a newer client against the system `traced`.

---

## 1. Perfetto data sources

The config field is `data_sources { config { name: "<name>" … } }`. The name → config mapping is in
[`data_source_config.proto`](https://github.com/google/perfetto/blob/main/protos/perfetto/config/data_source_config.proto) [src].

### 1.1 SurfaceFlinger / frames

| Data source | Config | Notes |
|---|---|---|
| `android.surfaceflinger.frametimeline` | none | Android 12+ [doc](https://perfetto.dev/docs/data-sources/frametimeline). Produces the `expected_frame_timeline_slice` and `actual_frame_timeline_slice` tables. Columns: `jank_type`, `present_type` (On-time/Late/Early/Dropped/Unknown), `on_time_finish`, `gpu_composition`, `prediction_type`, `layer_name`, `surface_frame_token`, `display_frame_token`, `upid`. Jank types: None, App Deadline Missed, Buffer Stuffing, SurfaceFlinger CPU/GPU Deadline Missed, SurfaceFlinger Scheduling, Display HAL, Prediction Error, Unknown, Dropped Frame, App Resynced Jitter. Registered in `Scheduler/FrameTimeline.h:531` [src]. Low overhead: about 2 slices per layer-frame. |
| `android.surfaceflinger.transactions` | `surfaceflinger_transactions_config { mode: MODE_CONTINUOUS \| MODE_ACTIVE }` | SF always keeps a 512 KB in-process transaction ring buffer (`TransactionTracing.h:149`). MODE_CONTINUOUS dumps it on flush, so it costs almost nothing while running [src]. Useful for Winscope-style "what changed" analysis. |
| `android.surfaceflinger.layers` | `surfaceflinger_layers_config { mode: MODE_ACTIVE\|MODE_GENERATED\|MODE_DUMP\|MODE_GENERATED_BUGREPORT_ONLY; trace_flags: TRACE_FLAG_INPUT\|COMPOSITION\|EXTRA\|HWC\|BUFFERS\|VIRTUAL_DISPLAYS }` | MODE_ACTIVE serialises the layer tree on every SF frame, which is **expensive**; avoid it in a flight recorder. MODE_GENERATED rebuilds snapshots from the transaction buffer **at flush or clone time** (`LayerTracing.cpp:102`), so the cost is paid only when you snapshot [src]. |
| `android.surfaceflinger.frame` | none | FrameTracer: per-buffer lifecycle events (dequeue, queue, latch, present fence) (`FrameTracer.h:68`) [src]. Medium volume. Optional. |

### 1.2 `linux.ftrace`

Key fields of `ftrace_config`
([proto](https://github.com/google/perfetto/blob/main/protos/perfetto/config/ftrace/ftrace_config.proto)) [src]:
- `ftrace_events`
- `atrace_categories`
- `atrace_apps` (`"*"` = all apps)
- `buffer_size_kb` (per-CPU kernel buffer)
- `drain_period_ms`
- `compact_sched { enabled: true }` (use it, it makes sched events much smaller)
- `symbolize_ksyms`
- `throttle_rss_stat`
- `disable_generic_events`
- `atrace_userspace_only`
- `tids_to_trace`

**atrace categories (userspace plus the kernel events they enable)** come from
`frameworks/native/cmds/atrace/atrace.cpp` [src]:
- `gfx`: `ATRACE_TAG_GRAPHICS` plus `gpu_mem/gpu_mem_total`. On this device the vendor atrace HAL
  (`hardware/interfaces/atrace/1.0/default`, present in stock `/vendor/bin/hw/android.hardware.atrace@1.0-service`)
  also maps `gfx` to the `mdss`, `sde` and `mali_systrace` tracefs groups [src]. Whether `hal_atrace_default` can write
  `events/sde/enable` on a user build is **[UNVERIFIED]**.
- `view` (HWUI/Choreographer: `Choreographer#doFrame`, `DrawFrame`, `dequeueBuffer`), `input` (InputDispatcher
  `sendMessage`/`receiveMessage`, `deliverInputEvent`), `wm`, `am`, `dalvik` (GC and monitor contention slices, which
  `android_monitor_contention` needs), `ss`, `binder_driver` (the `binder_transaction*` events), `sched`, `freq`
  (`power/cpu_frequency`, `cpu_frequency_limits`, `clk_*`, `suspend_resume`, `cpuhp_*`), `idle`, `memreclaim`,
  `memory`, `thermal`, `aidl`, `hal`, `res`, `pm`, `disk`, `sync`, `workq`, `irq`.
- Apps: TRACE_TAG_APP sections show up for any app that is debuggable or profileable (the default) (`ActivityThread.java:7993`) [src].

**Kernel events for jank (group/name).** Perfetto parses all of these into typed tables; the rest are kept as generic events.

| Area | Events | Allowed for traced_probes on user builds? |
|---|---|---|
| Scheduler | `sched/sched_switch`, `sched_waking`, `sched_wakeup_new`, `sched_blocked_reason`, `sched_process_exit/free`, `task/task_newtask`, `task/task_rename` | yes |
| CPU freq / idle | `power/cpu_frequency`, `power/cpu_frequency_limits`, `power/cpu_idle`, `power/suspend_resume` | yes |
| Qualcomm CPU limits | `dcvsh/dcvsh_freq` (LMh hardware throttle, from `drivers/cpufreq/qcom-cpufreq-hw.c`) | **no** |
| WALT | `schedwalt/*` (`sched_update_task_ravg`, `waltgov_next_freq`, `core_ctl_*`, `sched_set_boost`, …) | **no** |
| GPU freq | `power/gpu_frequency` (kgsl emits it through `KGSL_TRACE_GPU_FREQ` → `trace_gpu_frequency` in `kgsl_power_trace.h`, TRACE_SYSTEM power) [src] | yes |
| GPU (kgsl) | `kgsl/kgsl_gpu_frequency`, `kgsl_pwrlevel`, `kgsl_gpubusy`, `kgsl_pwrstats`, `kgsl_clk`, `kgsl_buslevel`, `kgsl_constraint`, `kgsl_clock_throttling`, `kgsl_thermal_constraint`, `kgsl_bcl_clock_throttling`, `adreno_cmdbatch_queued/submitted/sync/retired`, `adreno_drawctxt_wait_start/done`, `adreno_preempt_*`, `kgsl_timeline_*`, `kgsl_pool_*`. The list is from `drivers/gpu/msm/{kgsl,adreno}_trace.h` [src]. Perfetto has typed protos for `adreno_cmdbatch_*`. | **no** |
| GPU memory | `gpu_mem/gpu_mem_total` | yes |
| Fences | `dma_fence/*` (`dma_fence_init`, `emit`, `signaled`, `wait_start`, `wait_end`), `fence/*`, `sync/*` | yes |
| Display (SDE) | `sde/tracing_mark_write` produces slices: `encoder_kickoff`, `crtc_frame_event`, `pp_done_irq`, `rd_ptr_irq`, `encoder_vblank_callback`, `plane_wait_input_fence`, `sde_crtc_atomic_flush`, `encoder_underrun_callback`. Also `sde/sde_evtlog`, `sde_perf_crtc_update`, `sde_perf_calc_crtc`, `sde_perf_update_bus`, `sde_encoder_underrun`, `sde_perf_uidle_*`. Source: `display-drivers/msm/sde/sde_trace.h` [src]. | **no** |
| Bus / DDR | `dcvs/qcom_dcvs_update`, `dcvs/qcom_dcvs_boost`, `dcvs/memlat_dev_update`, `dcvs/memlat_dev_meas`, `dcvs/bw_hwmon_meas`, `dcvs/bw_hwmon_update`, `bus_prof/*` (`drivers/soc/qcom/dcvs/trace-dcvs.h`) [src] | **no** |
| Thermal | `thermal/thermal_temperature`, `thermal/cdev_update` | yes |
| Memory | `vmscan/mm_vmscan_direct_reclaim_begin/end`, `vmscan/mm_vmscan_kswapd_wake/sleep`, `kmem/rss_stat` (use with `throttle_rss_stat`), `oom/oom_score_adj_update`, `oom/mark_victim` | yes |
| Binder | `binder/binder_transaction`, `binder_transaction_received`, `binder_set_priority`, `binder_command`, `binder_return`, `binder_transaction_alloc_buf` | yes |

GKI 5.10 does not enable `CONFIG_KPROBE_EVENTS` or the function tracer (`arch/arm64/configs/gki_defconfig`) [src], so
`kprobe_events` and `enable_function_graph` do not work. `CONFIG_PSI`, `CONFIG_UCLAMP_TASK(_GROUP)`,
`CONFIG_CPU_FREQ_STAT` and `CONFIG_SCHEDSTATS` are all `=y`.

### 1.3 Other sources

| Data source | Key config | Notes |
|---|---|---|
| `linux.sys_stats` | `meminfo_period_ms` + `meminfo_counters`, `vmstat_period_ms` + `vmstat_counters`, `stat_period_ms` + `stat_counters` (STAT_CPU_TIMES, IRQ_COUNTS, SOFTIRQ_COUNTS, FORK_COUNT), `devfreq_period_ms`, `cpufreq_period_ms`, `buddyinfo_period_ms`, `diskstat_period_ms`, `psi_period_ms`, `thermal_period_ms`, `cpuidle_period_ms`, `gpufreq_period_ms` (v51+ in the tree; `slab_period_ms` is only upstream). The minimum period is 10 ms [src]. | Paths: `/proc/{meminfo,vmstat,stat,pressure/{cpu,io,memory}}`, `/sys/class/thermal/*/temp` and `type`, `/sys/class/devfreq/*/cur_freq`. **gpufreq reads `/sys/class/kgsl/kgsl-3d0/devfreq/cur_freq`** (`sys_stats_data_source.cc:410`) [src]. `traced_probes` sepolicy allows only `sysfs_devfreq_*`, `proc_diskstats` and the generic proc files; the kgsl sysfs and thermal zone labels may be denied **[UNVERIFIED]**. Bus DCVS (DDR/LLCC) is **not** under devfreq on this SoC (see §6). Cost: negligible at 250–1000 ms. |
| `linux.process_stats` | `scan_all_processes_on_start`, `proc_stats_poll_ms`, `record_thread_names` | Needed for pid → name mapping. |
| `android.packages_list` | `package_name_filter` | uid → package. Cheap. |
| `android.log` | `log_ids` (LID_DEFAULT, LID_EVENTS, LID_SYSTEM, LID_CRASH…), `min_prio`, `filter_tags`, `preserve_log_buffer` | Catches "Skipped N frames", lmkd "Kill '…'", FrameTracker "Missed App/SF frame". **High volume**; filter tags (Choreographer, FrameTracker, InteractionJankMonitor, lowmemorykiller, ActivityManager, ActivityTaskManager). |
| `android.statsd` | `statsd_tracing_config { push_atom_id: ATOM_… ; raw_push_atom_id; pull_config { pull_atom_id, pull_frequency_ms, packages } }` | Present in the A16 perfetto (`statsd_binder_data_source.cc:205`) [src]; introduced around Android 14 **[UNVERIFIED]**. Useful atoms (ids from `atom_ids.proto`) are listed below this table. |
| `android.power` | `battery_poll_ms`, `battery_counters`, `collect_power_rails`, `collect_entity_state_residency` | Rails depend on a PowerStats HAL. Optional. |
| `android.gpu.memory` | none | gpuservice `GpuMemTracer` (`GpuMemTracer.h:69`) [src]. Initial per-process GPU memory snapshot. Traceur adds it for gfx/memory. |
| `gpu.counters` | `gpu_counter_config { counter_period_ns, counter_ids \| counter_names }` | The stock vendor has the Adreno producer `libgpudataproducer.so` (registers `gpu.counters`, Adreno counters such as "GPU % Utilization" and "GPU % Bus Busy") and `/system/bin/gpu_counter_producer` (AOSP `frameworks/base/cmds/gpu_counter_producer`), which dlopens it. AGI starts it; as root you run it yourself (`-f` keeps it in the foreground). Counter IDs are listed in the data source descriptor (`perfetto --query`). [src]; runtime behaviour [UNVERIFIED]. [doc](https://perfetto.dev/docs/data-sources/gpu), [AGI](https://developer.android.com/agi/sys-trace/counters). Medium overhead at 1–10 ms periods. |
| `gpu.renderstages` | none | Vulkan/GL driver render-stage timeline. Needs the driver to support it (`debug.graphics.gpu.profiler.perfetto` sysprop, found in the stock `vulkan.adreno.so` strings) **[UNVERIFIED]**. Heavy. |
| `android.input.inputevent` | `android_input_event_config { mode: TRACE_MODE_TRACE_ALL\|USE_RULES; rules{trace_level,match_all_packages,…}; trace_dispatcher_input_events; trace_dispatcher_window_dispatch; trace_evdev_events }` | **Only when `ro.debuggable=1`** [src]. Feeds the `android_key_events` and `android_motion_events` tables. |
| `android.game_interventions` | `package_name_filter` | Userdebug only [doc](https://perfetto.dev/docs/data-sources/android-game-intervention-list). Not useful for UI jank. |
| `track_event` | `track_event_config { enabled_categories, disabled_categories }` | Only for apps or processes built with the Perfetto SDK. On A16/A17 the framework `PerfettoTrace` Java SDK also uses this path; not needed for jank. |
| `linux.perf` | `perf_event_config { timebase, callstack_sampling { scope… } }` | Callstack sampling ("what was the UI thread doing"). Only profileable or debuggable processes on user builds. **High overhead**, so use it only in short snapshot windows. |

Useful `android.statsd` atoms:
- `ATOM_UI_INTERACTION_FRAME_INFO_REPORTED` = 305 (per-CUJ frames, missed frames, max frame time)
- `ATOM_UI_ACTION_LATENCY_REPORTED` = 306
- `ATOM_SLOW_INPUT_EVENT_REPORTED` = 375 (events ≥200 ms, `input_native_boot/slow_event_min_reporting_latency_millis`)
- `ATOM_INPUT_EVENT_LATENCY_REPORTED` = 932
- `ATOM_LMK_KILL_OCCURRED` = 51
- `ATOM_THERMAL_THROTTLING_SEVERITY_STATE_CHANGED` = 189
- `ATOM_APP_START_OCCURRED` = 48 and `ATOM_APP_START_FULLY_DRAWN` = 50
- `ATOM_ANR_OCCURRED` = 79
- pulled: `ATOM_SURFACEFLINGER_STATS_GLOBAL_INFO` = 10062, `ATOM_SURFACEFLINGER_STATS_LAYER_INFO` = 10063 (TimeStats),
  `ATOM_GRAPHICS_STATS` = 10068 (HWUI), `ATOM_INPUT_EVENT_LATENCY_SKETCH` = 10110

**Overhead guide [estimates, UNVERIFIED on dizi].** The androidperformance.com field-tracing article gives about
1–2 MB/s for a typical sched + atrace config, so a 64 MB ring holds about 30–60 s
([link](https://androidperformance.com/en/2026/05/04/Android-Perfetto-15-Boot-And-Long-Running-Field-Tracing/)).
The biggest contributors, in order:
- `sched_switch`/`sched_waking` (use compact_sched)
- `atrace_apps:"*"` combined with `view`/`gfx`
- `android.log`
- `binder_driver`
- kgsl `adreno_cmdbatch_*`, `dma_fence/*` and `sde/*` (all per-frame, so moderate)

frametimeline, sys_stats, process_stats and packages_list are negligible. Measure on the device with `perfetto --query`
(buffer stats) and with the `stats` table (`traced_buf_*`, `ftrace_cpu_overrun_end`).

---

## 2. Flight-recorder features

Sources: `trace_config.proto` and `perfetto_cmd.cc` [src].

- **Ring buffer:** `buffers { size_kb: N fill_policy: RING_BUFFER }` (the default policy). Use two buffers: a big one
  for ftrace and a small one for frametimeline, process_stats and packages so semantic data isn't overwritten; pick one
  per data source with `target_buffer` (index) or `target_buffer_name` [doc](https://perfetto.dev/docs/concepts/config).
  - Guardrails (`kGuardrailsMaxTracingBufferSizeKb` = 128 MB, 24 h max) only apply when `enable_extra_guardrails` is set
    (the statsd/upload paths). Otherwise the limit is 7 days [src].
  - Session limits: 5 concurrent sessions per UID, 15 in total.
- **`unique_session_name: "jankrec"`** allows at most one session with that name, and is what `--clone-by-name` looks up.
- **Clone (snapshot without stopping):**
  - `perfetto --clone-by-name jankrec -o /data/misc/perfetto-traces/snap_<ts>.pftrace`, or `--clone <TSID>` (TSID from
    `perfetto --query`).
  - `--clone-for-bugreport` skips the trace filter.
  - Needs Android 14 / perfetto v49+ for `--clone-by-name`
    ([doc](https://perfetto.dev/docs/getting-started/periodic-trace-snapshots),
    [version notes](https://perfetto.dev/docs/reference/android-version-notes)).
  - Available in both device builds (v51 and v54) [src].
- **Triggers:** `trigger_config { trigger_mode: …; trigger_timeout_ms: (required, >0); triggers { name, producer_name_regex, stop_delay_ms, max_per_24_h, skip_probability } }`. Modes:
  - `START_TRACING` (1): data sources stay idle until the trigger fires, then record for `stop_delay_ms`.
  - `STOP_TRACING` (2): the classic flight recorder. The ring buffer runs until the trigger, and the trace ends
    `stop_delay_ms` later (use about 1–3 s to catch the tail). If no trigger arrives within `trigger_timeout_ms`, the
    session ends with **no data**.
  - `CLONE_SNAPSHOT` (**4**; value 3 is reserved and was buggy in U): the session keeps running and each trigger writes
    a snapshot `stop_delay_ms` later. With the `perfetto` CLI as consumer, snapshots go to `<out>.0`, `<out>.1`, ….
    Only use it on Android 15+ / perfetto v38+ (b/274931668). `use_clone_snapshot_if_available: true` together with
    STOP_TRACING gives a fallback on older builds [src].
  - `prefer_suspend_clock_for_duration: true` makes durations and delays count suspend time.
- **Firing triggers:**
  - `/system/bin/trigger_perfetto <name> [<name>…]` (no other flags) [src].
  - A config that contains only `activate_triggers: "name"`, passed to `perfetto -c -`.
  - Apps and the framework use `com.android.internal.util.PerfettoTrigger.trigger()` (which forks `trigger_perfetto`
    or goes through the SDK).
  - **There is no `perfetto --trigger` flag.**
- **Built-in triggers you get for free:** `com.android.telemetry.interaction-jank-monitor-<N>`, where N is the Cuj id.
  Examples:
  - 0 `NOTIFICATION_SHADE_EXPAND_COLLAPSE`
  - 5 `NOTIFICATION_SHADE_QS_EXPAND_COLLAPSE`
  - 7 `LAUNCHER_APP_LAUNCH_FROM_RECENTS`
  - 8 `LAUNCHER_APP_LAUNCH_FROM_ICON`
  - 9 `LAUNCHER_APP_CLOSE_TO_HOME`
  - 11 `LAUNCHER_QUICK_SWITCH`
  - 25 `LAUNCHER_OPEN_ALL_APPS`
  - 65 `RECENTS_SCROLLING`
  - 66 `LAUNCHER_APP_SWIPE_TO_RECENTS`

  The full list is in `core/java/com/android/internal/jank/Cuj.java` (141 CUJs). List each name you care about in
  `triggers {}`.
- **bugreport_score:** Android S+. On U+ `perfetto --save-for-bugreport` (called by dumpstate) takes a read-only
  snapshot of the highest-scoring session without stopping it. `bugreport_filename` (v42 / Android V) names the file
  under `/data/misc/perfetto-traces/bugreport/`. Setting `bugreport_score` also lets other UIDs clone the session.
  Traceur uses `bugreport_score: 500` [src].
- **Long traces instead of a ring:** `write_into_file: true`, `file_write_period_ms` (≥100), `max_file_size_bytes`,
  `flush_period_ms`, `write_flush_mode` (upstream). Traceur's long-trace mode uses `file_write_period_ms: 1000`,
  `flush_period_ms: 30000` and `incremental_state_config { clear_period_ms: 15000 }` (clear_period is required so
  interned data survives a ring wrap) [src].
- **Useful CLI flags** (`perfetto --help`, [doc](https://perfetto.dev/docs/reference/perfetto-cli)):
  - `-c <file|->`, `--txt`, `-o <file|->`
  - `-d/--background`, `-D/--background-wait` (waits for data sources to start)
  - `--notify-fd`, `--no-clobber`
  - `--query [--long]`, `--query-raw`
  - `--clone`, `--clone-by-name`, `--clone-for-bugreport`
  - `--save-for-bugreport`, `--save-all-for-bugreport`
  - `--detach=key`, `--attach=key [--stop]`, `--is_detached=key` (discouraged)
  - `--add-attribute k=v` (v58; older builds have `--add-note`)
  - `--upload`
- **Other features:**
  - `exclusive_prio` (perfetto v52 / Android 25Q3+): blocks concurrent sessions.
  - `persist_trace_across_reboots` (v59 / 26Q4+): upstream only, not on these builds.
  - `enable_concurrent_session_events` (v58).
- Suggested supervisor loop:
  1. Start with `perfetto -c cfg --txt --background-wait -o /data/misc/perfetto-traces/jr` (unique_session_name,
     CLONE_SNAPSHOT triggers).
  2. Your app fires `trigger_perfetto jankrec_manual` or `perfetto --clone-by-name jankrec -o …` on its own heuristics
     (for example the frametimeline jank rate in a live poll of `dumpsys SurfaceFlinger --timestats`).
  3. Watch for the session disappearing (`--query`) and restart it.

---

## 3. Offline analysis: trace processor stdlib and metrics

Python usage [doc](https://perfetto.dev/docs/analysis/trace-processor-python):
- `pip install perfetto` (0.58.2 today)
- `from perfetto.trace_processor import TraceProcessor, TraceProcessorConfig`
- `tp = TraceProcessor(trace='snap.pftrace', config=TraceProcessorConfig(bin_path=...))`
- `tp.query("INCLUDE PERFETTO MODULE android.frames.timeline; SELECT * FROM android_frames").as_pandas_dataframe()`
- Legacy v1 metrics: `tp.metric(['android_jank_cuj'])` (deprecated in favour of `tp.trace_summary(specs=…)`).
- Many traces at once: `BatchTraceProcessor`.

Stdlib modules and their public tables, verified in `src/trace_processor/perfetto_sql/stdlib/android/` (main) [src]:

| Module | Tables / functions |
|---|---|
| `android.frames.timeline` | `android_frames` (frame_id, ts, dur, do_frame_id, draw_frame_id, actual/expected_frame_timeline_id, render_thread_utid, ui_thread_utid, layer counts), `android_frames_layers`, `android_frames_choreographer_do_frame`, `android_frames_draw_frame`, `android_first_frame_after(ts)` |
| `android.frames.jank_type` | `android_is_sf_jank_type(t)`, `android_is_app_jank_type(t)`, `android_is_missed_frame_type(t)` |
| `android.frames.per_frame_metrics` | `android_frames_overrun`, `android_frames_ui_time`, `android_app_vsync_delay_per_frame`, `android_cpu_time_per_frame`, `android_frame_stats` |
| `android.cujs.base` / `android.cujs.frames` / `android.cujs.sysui_cujs` | `android_jank_cuj` (CUJ boundaries), `android_jank_cuj_layer_name`, `android_jank_cuj_slice_summary`, `android_sysui_jank_cujs`, `android_sysui_latency_cujs`, `android_jank_latency_cujs`, `android_cuj_blocking_calls` |
| `android.input` | `android_input_events` (dispatch_latency_dur, handling_latency_dur, ack_latency_dur, total_latency_dur, **end_to_end_latency_dur** from read to present, frame linkage). Built from atrace `input` + `view` slices, so it **works on user builds**. `android_key_events` / `android_motion_events` / `android_input_event_dispatch` need `android.input.inputevent`. |
| `android.monitor_contention` | `android_monitor_contention`, `android_monitor_contention_chain`, `…_chain_thread_state(_by_txn)`, `android_monitor_contention_graph()`; needs the atrace `dalvik` category |
| `android.binder` / `android.binder_breakdown` | `android_binder_txns`, `android_binder_metrics_by_process`, `android_sync_binder_thread_state_by_txn`, `android_sync_binder_blocked_functions_by_txn`, `android_binder_{client,server,client_server}_breakdown`, graph functions |
| `android.surfaceflinger` | `android_surfaceflinger_workloads`, `android_app_to_sf_frame_timeline_match` |
| `android.gpu.frequency` / `android.gpu.work_period` / `android.gpu.memory` | `android_gpu_frequency` (from `power/gpu_frequency`), `android_gpu_work_period_track` |
| `android.dvfs` | `android_dvfs_counters`, `android_dvfs_counter_stats`, `android_dvfs_counter_residency` |
| `android.memory.lmk` | `android_lmk_events` (from lmkd `lowmemorykiller` instant track, `ATRACE_TAG_ALWAYS`) |
| `android.startup.startups` | `android_startups`, `android_startup_processes`, `android_startup_threads`, `android_thread_slices_for_all_startups` |
| others | `android.critical_blocking_calls`, `android.frame_blocking_calls.blocking_calls_aggregation`, `android.anrs`, `android.suspend`, `android.screen_state`, `android.oom_adjuster`, `android.thread` |

- v1 metrics (in `metrics/sql/android/`): `android_jank_cuj`, `android_frame_timeline_metric`, `android_startup`,
  `android_binder`, `android_monitor_contention(_agg)`, `android_surfaceflinger`, `android_gpu`, `android_hwui_threads`,
  `android_blocking_calls_cuj_per_frame_metric`.
- CUJ markers in traces (async track, TRACE_TAG_APP, in the process that runs the CUJ; `FrameTracker.java`) [src]:
  - Slice `J<CUJ_NAME>` for jank CUJs, `L<NAME>` for latency CUJs.
  - Instants on the same track: `FT#beginVsync`, `FT#layerId`, `FT#deferMonitoring`, `FT#end`, `FT#endVsync`,
    `FT#cancel`, `FT#finish`, `FT#MissedHWUICallback`, `FT#MissedSFCallback`, `<name>#UIThread`.
  - Counters: `J<…>#missedFrames`, `#missedAppFrames`, `#missedSfFrames`, `#totalFrames`, `#maxFrameTimeMillis`,
    `#maxSuccessiveMissedFrames`.
  - Stdlib only picks up CUJs from `com.android.*` and `com.google.android*` processes.
- Import the stdlib into your own analysis rather than copying it. `trace_processor_shell` is pinned per pip version;
  newer stdlib tables need a newer binary (`fetch_latest_trace_processor=True`).

---

## 4. SurfaceFlinger TimeStats and other SF dumps

Still present and unchanged in Android 17 (`TimeStats/TimeStats.cpp` is identical in both trees) [src].

- **Commands:** `dumpsys SurfaceFlinger --timestats [-enable] [-disable] [-clear] [-dump [-maxlayers N]]`, plus
  `-proto` for binary output (`TimeStats::parseArgs`) [src]. The statsd pull of atoms 10062/10063 enables TimeStats
  automatically, and pulls clear it, so on a device where statsd pulls regularly your deltas get reset. Take
  **your own** `-clear` / `-dump` pairs over short windows.
- **Global section:**
  - Legacy fields: `statsStart`/`statsEnd`, `totalFrames`, `missedFrames`, `clientCompositionFrames`,
    `clientCompositionReusedFrames`, `refreshRateSwitches`, `compositionStrategyChanges`/`Predicted`/`PredictionSucceeded`/`Failed`,
    `displayOnTime`, `displayConfigStats` (ms per fps).
  - Histograms: `totalP2PTime` + `presentToPresent`, `averageFrameDuration` + `frameDuration`,
    `averageRenderEngineTiming` + `renderEngineTiming`.
  - Per (displayRefreshRate, renderRate) bucket: jank payload `totalTimelineFrames`, `jankyFrames`,
    `sfLongCpuJankyFrames`, `sfLongGpuJankyFrames`, `sfUnattributedJankyFrames`, `appUnattributedJankyFrames`,
    `sfSchedulingJankyFrames`, `sfPredictionErrorJankyFrames`, `appBufferStuffingJankyFrames`, plus `sfDeadlineMisses`
    and `sfPredictionErrors` histograms.
- **Per layer** (max 200 layers, 64 in-flight records each): `layerName`, `packageName`, `uid`, `gameMode`,
  `displayRefreshRate`, `renderRate`, `frameRate`, `frameRateCompatibility`, `seamlessness`, `totalFrames`,
  `droppedFrames`, `lateAcquireFrames`, `badDesiredPresentFrames`, `averageFPS`, the same jank payload, and histograms
  `present2present`, `present2presentDelta`, `post2present`, `acquire2present`, `latch2present`, `desired2present`,
  `post2acquire`, `appDeadlineDeltas` (1 ms buckets that get coarser at larger values) [src].
- **`dumpsys SurfaceFlinger --latency [<layer name>]`:** the first line is the vsync period in ns. With an exact layer
  name (from `--list`), you get the last 128 frames as `desiredPresent actualPresent frameReady` [src].
  `--latency-clear [name]` resets it. The code uses `traverseLegacyLayers`, so with the new frontend some layers may
  not be found **[UNVERIFIED]**.
- **`dumpsys SurfaceFlinger --frametimeline [-jank|-all]`** prints recent DisplayFrames and SurfaceFrames with their
  jank reasons [src].
- **Other SF dumps:** `--scheduler` (refresh-rate policy, frame-rate votes), `--vsync`, `--displays`, `--hwclayers`.
- **Other tools use this too.** FPS-overlay apps such as FrameX read `--timestats` from a privileged shell
  ([github](https://github.com/MaheshSharan/FrameX-Android)).

---

## 5. InteractionJankMonitor / CUJ

- **Settings** (namespace `interaction_jank_monitor`, from `InteractionJankMonitor.java:92-106`) [src]:

  | Key | Default |
  |---|---|
  | `enabled` | `Build.IS_DEBUGGABLE` |
  | `sampling_interval` | 1 |
  | `trace_threshold_missed_frames` | 3 |
  | `trace_threshold_frame_time_millis` | 64 |
  | `debug_overlay_enabled` | false (colour overlay while a CUJ is running) |

  Example:
  ```
  device_config put interaction_jank_monitor enabled true
  device_config put interaction_jank_monitor debug_overlay_enabled true
  device_config set_sync_disabled_for_tests persistent   # keep server sync from reverting it
  ```
- **Outputs:**
  - Trace markers, as in §3.
  - logcat tag `FrameTracker`: `W … Missed App frame:<JankInfo>, CUJ=<name>`, `W … Missed SF frame:…`,
    `V … Missing HWUI/SF jank callback for vsyncId`, `E … force finish cuj, time out`.
  - Statsd atom 305 `UIInteractionFrameInfoReported`, for CUJs where `Cuj.logToStatsd()` is true.
  - A perfetto trigger when a threshold is crossed (§2).
- **Where CUJs come from:** SystemUI (shade, QS, lockscreen, volume) and Launcher3/Quickstep (they use the same IJM
  through `InteractionJankMonitorWrapper`); the prebuilt Pixel Launcher does too **[UNVERIFIED]**.

---

## 6. Signals you can read directly as root (sysfs / procfs / dumpsys)

Paths come from the device kernel source. Values were not read on the tablet.

**GPU (kgsl)** is at `/sys/class/kgsl/kgsl-3d0/` (`drivers/gpu/msm/kgsl_pwrctrl.c`) [src]:
- Read-only:
  - `gpubusy` (two numbers: busy and total ticks since the last read)
  - `gpu_busy_percentage`
  - `clock_mhz`
  - `gpuclk` (Hz, RW)
  - `max_gpuclk`
  - `freq_table_mhz`, `gpu_available_frequencies`
  - `num_pwrlevels`
  - `temp`
  - `gpu_model`
  - `reset_count` (GPU hangs and recoveries, a jank signal)
  - `gpu_clock_stats` (time-in-state per power level)
  - `popp`
- Read-write:
  - `min_clock_mhz`, `max_clock_mhz`
  - `min_pwrlevel`, `max_pwrlevel`, `default_pwrlevel`
  - `thermal_pwrlevel` (the thermal cap; watch it change)
  - `idle_timer`
  - `force_*`, `bus_split`
- devfreq: `/sys/class/kgsl/kgsl-3d0/devfreq/{cur_freq,min_freq,max_freq,governor,trans_stat,available_frequencies}`
  (Perfetto sys_stats reads `cur_freq`).
- There is no plain `throttling` node in this driver (the `kgsl_clock_throttling` tracepoint is its replacement).
  Per-process GPU memory is in `/sys/class/kgsl/kgsl/proc/<pid>/`.
- Sample `gpubusy` and `gpuclk` at 50–100 ms yourself if SELinux blocks traced_probes.

**Bus / DDR / LLCC.** On this kernel these are Qualcomm DCVS, not devfreq (`drivers/soc/qcom/dcvs/dcvs.c`, `memlat.c`, `bwmon.c`) [src]:
- `/sys/devices/system/cpu/bus_dcvs/{DDR,LLCC,L3}/{cur_freq,available_frequencies,hw_min_freq,hw_max_freq,boost_freq}`.
  Which hardware types exist comes from `parrot.dtsi` `qcom,dcvs` (the DDR, LLCC and maybe DDRQOS children)
  **[UNVERIFIED which on device]**.
- The same directories hold per-path voter subdirectories, `memlat_settings`, the `memlat` group with monitors
  (min_freq, max_freq, sample_ms, freq_map), and the bwmon node `bwmon-ddr` (`qcom,bwmon5` in `parrot.dtsi:1428`).
- `/sys/class/devfreq/` then holds only kgsl-3d0, the GPU bus and some mmc/ufs devices.

**CPU:**
- `/sys/devices/system/cpu/cpufreq/policy{0,4,7}/{scaling_cur_freq,scaling_min_freq,scaling_max_freq,cpuinfo_max_freq,stats/time_in_state,stats/trans_table,stats/total_trans}`
  (`CONFIG_CPU_FREQ_STAT=y`). The policy numbers follow SM7435's cluster layout; check `related_cpus` on the device.
- The scaling governor is `walt`: `/sys/devices/system/cpu/cpufreq/policyN/walt/*`.
- WALT tunables: `/proc/sys/walt/*`, for example `sched_boost`.
- `cpuidle`: `/sys/devices/system/cpu/cpu*/cpuidle/state*/{time,usage}`.
- `/sys/devices/system/cpu/cpu*/online`, plus core_ctl under `/sys/devices/system/cpu/cpu*/core_ctl/`.
- LMh throttle limits: `/sys/devices/system/cpu/cpufreq/policyN/` `scaling_max_freq` changes, or the `dcvsh_freq`
  tracepoint **[UNVERIFIED sysfs]**.

**Scheduler / uclamp:**
- `/dev/cpuctl/<group>/{cpu.uclamp.min,cpu.uclamp.max,cpu.uclamp.latency_sensitive,cpu.shares}` for the top-app,
  foreground and background groups.
- Per-task values with `sched_getattr`, or `/proc/<pid>/sched`.
- `/proc/<pid>/task/<tid>/schedstat` (run time, wait time, timeslices; `CONFIG_SCHEDSTATS=y`) is a cheap way to get
  per-thread run-queue latency for the UI thread and RenderThread.

**Pressure and memory:**
- `/proc/pressure/{cpu,memory,io}` (`some`/`full` avg10/avg60/avg300/total).
- You can also open a PSI trigger fd yourself (write `"some 150000 1000000"`, then poll), the same mechanism lmkd uses.
- `/proc/meminfo`, `/proc/vmstat` (pgscan_direct, pgsteal, allocstall, workingset_refault).
- `/proc/zoneinfo`, `/sys/block/zram0/{mm_stat,io_stat}`, `/proc/swaps`.
- `dumpsys meminfo` gives the per-process swap PSS summary.

**Thermal:**
- `/sys/class/thermal/thermal_zone*/{type,temp,mode,trip_point_*}`.
- `/sys/class/thermal/cooling_device*/{type,cur_state,max_state}`. Watch `cur_state` on the cpu/gpu/cdsp cooling
  devices; `thermal/cdev_update` gives the same as a tracepoint.
- `dumpsys thermalservice` [src]: `IsStatusOverride`, `Thermal Status`, `Cached temperatures`, `HAL Ready`,
  `Current temperatures from HAL`, `Current cooling devices from HAL`, `Temperature static thresholds from HAL`,
  `Temperature headroom thresholds`.
- `cmd thermalservice headroom <sec>`.

**Display / refresh rate:**
- `dumpsys SurfaceFlinger --scheduler` and `dumpsys display` (active mode, `mActiveSfDisplayMode`, refresh-rate votes).
- `dumpsys SurfaceFlinger` shows the "refresh rate" / active mode.
- In the trace, the SF atrace counters (`VSYNC-app`, `VSYNC-sf`, `HW_VSYNC`) and the display power mode.

**Per-app HWUI:**
- `dumpsys gfxinfo <pkg>` summary: `Total frames rendered`, `Janky frames` (and `(legacy)`), 50/90/95/99th
  percentile, `Number Missed Vsync`, `High input latency`, `Slow UI thread`, `Slow bitmap uploads`,
  `Slow issue draw commands`, `Frame deadline missed`, `HISTOGRAM`, GPU percentiles, `GPU HISTOGRAM`
  (`libs/hwui/ProfileData.cpp`) [src].
- `dumpsys gfxinfo <pkg> framestats` prints the last **120** frames (ring buffer; `JankTracker.h:100`) between
  `---PROFILEDATA---` markers.
  - A16 columns: `Flags, FrameTimelineVsyncId, IntendedVsync, Vsync, InputEventId, HandleInputStart, AnimationStart, PerformTraversalsStart, DrawStart, FrameDeadline, FrameStartTime, FrameInterval, WorkloadTarget, SyncQueued, SyncStart, IssueDrawCommandsStart, SwapBuffers, FrameCompleted, DequeueBufferDuration, QueueBufferDuration, GpuCompleted, SwapBuffersCompleted, DisplayPresentTime, CommandSubmissionCompleted`.
  - **A17 adds `AnimationTime` after `WorkloadTarget`**, so parse columns by header name, not by position [src].
  - Timestamps are CLOCK_MONOTONIC ns. `Flags` ≠ 0 means ignore the row (1 WindowVisibilityChanged, 2 RTAnimation,
    4 SurfaceCanvas, 8 SkippedFrame).
  - Useful spans: total = FrameCompleted − IntendedVsync; UI thread = SyncQueued − HandleInputStart; RT = FrameCompleted
    − SyncStart; GPU = GpuCompleted − max(IssueDrawCommandsStart, SwapBuffers); present jitter from DisplayPresentTime.
  - `dumpsys gfxinfo <pkg> reset` clears the counters.
  - Old column docs: [developer.android.com dumpsys](https://developer.android.com/tools/dumpsys).
- `dumpsys graphicsstats` has daily per-package aggregates.

**Input:**
- `dumpsys input` only shows `LatencyAggregator` sketch counts and slow-event counters (`mLastSlowEventTime`,
  `mNumSkippedSlowEvents`). There are no per-event latencies (`LatencyAggregator.cpp:273`) [src].
- Use the atrace `input` category (the `android_input_events` table) or statsd atom 375 / 932.

**Logcat lines:**
- `Choreographer: Skipped N frames!  The application may be doing too much work on its main thread.` fires when
  N ≥ `debug.choreographer.skipwarning` (30). The property is read at class init in zygote, so set it and then restart
  zygote.
- `OpenGLRenderer: Davey! duration=…ms; <all FrameInfo fields>` fires for frames ≥700 ms (**disabled in the EvoX A16
  build**, active in AOSP and A17).
- `FrameTracker: Missed App/SF frame`.
- lmkd: `lowmemorykiller: Kill '<proc>' (<pid>), uid <uid>, oom_score_adj <adj> to free <rss>kB rss, <swap>kB swap; reason: …`,
  plus binary `killinfo` in the events buffer (tag 10195355) (`system/memory/lmkd/lmkd.cpp:2518`) [src].
- `ActivityManager` / `am_kill` / `am_proc_died` events.
- `ActivityTaskManager: Displayed <cmp> +Nms` for launch latency.

---

## 7. Existing tools to learn from

- **Traceur** (System Tracing, `packages/apps/Traceur/src_common/.../PerfettoUtils.java`) [src]. Its config is a good
  template:
  - RING_BUFFER with a 16 MB per-CPU ftrace buffer and `compact_sched`
  - `atrace_apps:"*"`
  - frametimeline and `android.gpu.memory` when gfx is selected
  - `linux.sys_stats` (meminfo, psi and vmstat at 1 s)
  - `android.power` (1 s, or 5 s for long traces)
  - `bugreport_score: 500`, `notify_traceur`
  - `incremental_state_config { clear_period_ms: 15000 }`
  - a priority boost
- **Perfetto docs:**
  - [periodic snapshots cookbook](https://perfetto.dev/docs/getting-started/periodic-trace-snapshots)
  - [FrameTimeline](https://perfetto.dev/docs/data-sources/frametimeline)
  - [config/triggers](https://perfetto.dev/docs/concepts/config)
  - [android version notes](https://perfetto.dev/docs/reference/android-version-notes)
- **Android Perfetto series 15** (field and long traces, a two-buffer design, trigger examples):
  [androidperformance.com](https://androidperformance.com/en/2026/05/04/Android-Perfetto-15-Boot-And-Long-Running-Field-Tracing/).
  Part 16 covers GPU and power counters.
- **JankStats** (androidx.metrics): in-app, per-frame `FrameData` (`frameStartNanos`, `frameDurationUiNanos`,
  `frameDurationCpuNanos`, `isJank`, `states`) through FrameMetrics on API 24+. `PerformanceMetricsState` attaches UI
  state strings to frames. It only covers your own app, so it is useful for its heuristics (jank = duration > 2×
  refresh interval by default) [doc](https://developer.android.com/topic/performance/jankstats).
- **AGI (Android GPU Inspector)** starts `gpu_counter_producer` and uses `gpu.counters` and `gpu.renderstages`;
  Adreno is supported [doc](https://developer.android.com/agi/sys-trace/counters).
- **Snapdragon Profiler** (Qualcomm): 150+ Adreno counters in realtime and trace modes, host-driven
  [link](https://www.qualcomm.com/developer/software/snapdragon-profiler). Command-line capture details
  **[UNVERIFIED]**.
- **Scene** (omarea/helloklf, `vtools`): root/Shizuku overlay for FPS, CPU, GPU and temperature with recording and
  charts. It reads SF latency/timestats plus kgsl and thermal sysfs [link](https://deepwiki.com/helloklf/vtools). The
  exact method is **[UNVERIFIED]**.
- **FrameX**: an FPS overlay that uses `SurfaceFlinger --timestats` through Shizuku
  ([github](https://github.com/MaheshSharan/FrameX-Android)). Also see
  [alibaba/mobileperf fps.py](https://github.com/alibaba/mobileperf/blob/master/mobileperf/android/fps.py), which
  derives FPS and jank from `SurfaceFlinger --latency` and gfxinfo.
- **GameBench**: commercial; FPS, jank, CPU/GPU and power, all from SF-level data **[UNVERIFIED specifics]**.

---

## 8. Suggested starting config (pbtxt, for perfetto v51+)

```
unique_session_name: "jankrec"
buffers { size_kb: 98304 fill_policy: RING_BUFFER }   # 0: ftrace/atrace
buffers { size_kb: 16384 fill_policy: RING_BUFFER }   # 1: semantic (frames, procs, counters, log)
bugreport_score: 100
incremental_state_config { clear_period_ms: 10000 }
trigger_config {
  trigger_mode: CLONE_SNAPSHOT
  trigger_timeout_ms: 604800000
  triggers { name: "jankrec_manual" stop_delay_ms: 1500 }
  triggers { name: "com.android.telemetry.interaction-jank-monitor-0"  stop_delay_ms: 1500 max_per_24_h: 20 }
  triggers { name: "com.android.telemetry.interaction-jank-monitor-66" stop_delay_ms: 1500 max_per_24_h: 20 }
  # ... one per CUJ id of interest
}
data_sources { config { name: "linux.ftrace" target_buffer: 0 ftrace_config {
  compact_sched { enabled: true } symbolize_ksyms: true throttle_rss_stat: true
  buffer_size_kb: 8192 drain_period_ms: 250
  atrace_categories: "gfx" atrace_categories: "view" atrace_categories: "input"
  atrace_categories: "wm" atrace_categories: "am" atrace_categories: "dalvik"
  atrace_categories: "binder_driver" atrace_categories: "freq" atrace_categories: "idle"
  atrace_categories: "sched" atrace_categories: "thermal" atrace_categories: "memreclaim"
  atrace_apps: "*"
  ftrace_events: "sched/sched_blocked_reason" ftrace_events: "power/gpu_frequency"
  ftrace_events: "power/cpu_frequency_limits" ftrace_events: "dma_fence/dma_fence_signaled"
  ftrace_events: "thermal/cdev_update" ftrace_events: "oom/oom_score_adj_update"
  # need the sepolicy patch (section 0.1):
  ftrace_events: "kgsl/kgsl_pwrlevel" ftrace_events: "kgsl/kgsl_clock_throttling"
  ftrace_events: "kgsl/adreno_cmdbatch_submitted" ftrace_events: "kgsl/adreno_cmdbatch_retired"
  ftrace_events: "sde/tracing_mark_write" ftrace_events: "sde/sde_encoder_underrun"
  ftrace_events: "dcvs/qcom_dcvs_update" ftrace_events: "dcvsh/dcvsh_freq"
}}}
data_sources { config { name: "android.surfaceflinger.frametimeline" target_buffer: 1 } }
data_sources { config { name: "android.surfaceflinger.transactions" target_buffer: 1
  surfaceflinger_transactions_config { mode: MODE_CONTINUOUS } } }
data_sources { config { name: "linux.process_stats" target_buffer: 1
  process_stats_config { scan_all_processes_on_start: true } } }
data_sources { config { name: "android.packages_list" target_buffer: 1 } }
data_sources { config { name: "linux.sys_stats" target_buffer: 1 sys_stats_config {
  psi_period_ms: 250 meminfo_period_ms: 1000 vmstat_period_ms: 1000
  thermal_period_ms: 1000 devfreq_period_ms: 250 gpufreq_period_ms: 100 cpufreq_period_ms: 250 } } }
data_sources { config { name: "android.log" target_buffer: 1 android_log_config {
  log_ids: LID_DEFAULT log_ids: LID_EVENTS log_ids: LID_SYSTEM min_prio: PRIO_INFO } } }
data_sources { config { name: "android.statsd" target_buffer: 1 statsd_tracing_config {
  push_atom_id: ATOM_UI_INTERACTION_FRAME_INFO_REPORTED push_atom_id: ATOM_LMK_KILL_OCCURRED
  push_atom_id: ATOM_THERMAL_THROTTLING_SEVERITY_STATE_CHANGED push_atom_id: ATOM_SLOW_INPUT_EVENT_REPORTED } } }
```

Before relying on this config:
- The whole config is **[UNVERIFIED on dizi]**: check `perfetto --query`, the trace `stats` table and `logcat -s perfetto`.
- The ftrace `buffer_size_kb` is per CPU (8 CPUs × 8 MB).
- The atrace `sched` category duplicates `ftrace_events`; that is harmless.

# Pixel, GrapheneOS and other well-engineered sources: what dizi can reuse for performance

Survey date: 2026-10-05. Target: Evolution X `cnb` (Android 17), the main release. Scope: UI smoothness, app launch,
efficiency and memory.

Method: six research passes (Pixel power HAL; Pixel system config; GrapheneOS; Pixel Tablet; Sultan and other
kernel developers; Qualcomm Pixels, AOSPA and other QTI trees) over public sources, each checked against `evox-cnb` (source and built `out` props, rc
and sh files) and against our earlier research (`performance.md`, `adpf.md`, `peer-trees.md`,
`performance-report.md`), so items already tried or rejected are not repeated. **Nothing here has been measured on
the tablet yet**: the tablet was unreachable during the survey. Sysfs/procfs nodes were checked against the kernel
source, the stock `post_boot` script and the DTS, not live.

Status tags used below: **new** (we don't have it), **differs** (we set something else), **have** (already the
same).

## TL;DR

- **Google stopped publishing Pixel sources.** The newest public Pixel device trees (`device/google/tangorpro`,
  `gs201`, `gs-common`, `zuma`, `caimito`) stop at **2025-03-08**, Android 15 QPR2. The Pixel power HAL
  (`hardware/google/pixel`) stops at **Android 16 QPR2** (`android-16.0.0_r4`, 2025-09-30). The A17 manifest has
  no `hardware/google/pixel` at all. Google's kernel modules (`kernel/google-modules/*`) are still published.
- **We already have all the Pixel power HAL code.** Our `lineage-libperfmgr` session engine is byte-identical to
  Pixel's newest public one, and we are one AIDL version ahead (v7). The famous ADPF features (CPU/GPU headroom,
  AUTO_CPU/AUTO_GPU, GRAPHICS_PIPELINE, LOAD_SPIKE hints) are stubs even in Google's public code. **Pixel's gains
  come from device config, and most of that config can be mapped onto WALT and kgsl as JSON.**
- **GrapheneOS no longer has Pixel device trees.** It builds from stock vendor binaries with `adevtool`. But
  `adevtool/vendor-skels/` holds the **current stock Pixel props and overlays (A17 QPR1, CP3A.260905.009)**, the
  freshest public view of real Pixel settings. Nearly all of Graphene's own code is security hardening that
  *costs* performance.
- **The best Pixel reference for us is a Qualcomm Pixel.** `device/google/redbull` (Pixel 4a 5G / 5, SM7250,
  `android14-qpr3-release`) is a QTI + libperfmgr device tuned by Google.
- **The strongest lead is from our own stock ROM, confirmed by the Pixel pattern.** Pixels retune the scheduler
  per refresh rate. Stock HyperOS does the same on dizi through the QTI perf HAL: at 120 Hz it shortens the WALT
  load window to 8 ms and turns on predictive load. We dropped perfd, so at 120 Hz we run a 16 ms window, about twice
  the 8.3 ms frame time (action #1).
- **The best kernel lead is from Sultan's Qualcomm-era kernels.** The GPU governor assumes 60 Hz frames and clocks
  too low at 120 Hz. Our kgsl exposes a sysfs multiplier for exactly this (`mod_percent`, action #22). Also, at
  more than 60 Hz, the display driver's PM QoS keeps all four silver cores out of deep idle (action #24, an
  efficiency item).
- **Bug found in our own power config (action #28).** Our `powerhint.json` came from LineageOS garnet, which
  generated it with a parser that swaps the two CPU clusters. On every touch, INTERACTION pins the four A55s at max
  and gives the A78s only 1.5 GHz; stock does the reverse. Camera hints cap the wrong cluster too. Verified against
  stock's own boost tables.
- **App launch is missing what Qualcomm and Google use (action #29):** a CPU idle-state limit, UFS clock gating off,
  and GPU no-nap. Google measured 5-20% faster cold launches from the UFS part alone.
- **Biggest power-HAL gap:** SurfaceFlinger ADPF is still off (`debug.sf.enable_adpf_cpu_hint` is unset). HWUI ADPF is
  on. SF is where the shade, QS and Recents client-composition jank lives.

## Action list, ranked by expected value / cost

All of these are unmeasured. Measure each one separately (see "How to measure" below). §N refers to the detailed
sections below.

| # | Change | Source | Where | Cost / risk |
|---|---|---|---|---|
| 1 | Shorter WALT load window and predictive load at 120 Hz: `sched_ravg_window_nr_ticks` 4 to 2 (16 to 8 ms), `walt/pl` 0 to 1 | **Stock HyperOS** perf HAL (fps boost `0x109B`); Pixel per-fps modes (§4.1) | `init.dizi.rc` | 2 writes. Low risk; check idle power |
| 2 | Enable SF ADPF: `debug.sf.enable_adpf_cpu_hint=true` | Every Pixel; tangorpro `ba8ccf3` (§1) | vendor props | 1 line. Low/medium risk |
| 3 | Pre-warm GPU and DDR on the first frame after idle (`CPU_LOAD_RESET` / `*_FIRST_FRAME` actions) | tangorpro `12b6dd3`, `f55c796`; caiman (§1, §4.2) | `powerhint.json` | JSON. Low risk |
| 4 | Add a `DISPLAY_UPDATE_IMMINENT` action: hold WALT `down_rate_limit_us` for 50 ms | caiman (§1) | `powerhint.json` | JSON. Low risk |
| 5 | CPU-share weights: foreground/system 20480, background 1024, dex2oat 512 | zuma/gs201 (§2) | `init.dizi.rc` | About 6 rc lines. Low risk |
| 6 | dex2oat off the big cores; `pm.dexopt.bg-dexopt.concurrency=2` | redbull; GrapheneOS (§2, §3) | vendor props | Props only. Low risk |
| 7 | Add a DDR floor to LAUNCH, and consider a 5 s cap | tangorpro (§4.5) | `powerhint.json` | JSON. Low risk |
| 8 | Tablet input: `config_enableMotionPrediction=true`, touch slop 8 to 6 dp | tangorpro overlay (§4.7) | framework overlay | Overlay. Low risk |
| 9 | ART ISA variant `cortex-a76` instead of `kryo300` | redbull, gs201 (§2) | `BoardConfig.mk` | 1 line. Low risk |
| 10 | `vm.watermark_scale_factor` 60 to 200 | gs201 `55f8dbd` (§2) | rc / post_boot | 1 sysctl; test live |
| 11 | Pinner list (framework/services jars, surfaceflinger, SystemUI) | gs201 `59615c9` (§4.8) | framework overlay | Tens of MB locked RAM; check the 6 GB SKU |
| 12 | `ro.egl.blobcache.multifile=true` with a 32 MB limit | gs201 `5c4cbe4` (§4.6) | vendor props | GL apps only |
| 13 | Real WALT actions for the ADPF task profiles (MVP for SF and RenderThread) | Pixel vendor_sched, mapped to WALT (§1, §4.4) | `task_profiles.json` | JSON. **Medium** risk |
| 14 | HeuristicBoost and per-tag ADPF profiles; use Pixel 9/Fold (120 Hz) as the reference, not tangorpro (60 Hz) | komodo/comet (§1) | `powerhint.json` | JSON. Medium power risk |
| 15 | Efficiency: lower the EXPENSIVE_RENDERING GPU floor (940 MHz fmax to 600-734 MHz); slim INTERACTION | Pixel uses mid-level GPU floors and has no INTERACTION action (§4.12) | `powerhint.json` | Saves power; check jank |
| 16 | Video at 60 Hz: `debug.sf.frame_rate_multiple_threshold=120` | gs201 (§4.9) | vendor props | Power only |
| 17 | lmkd props: `filecache_min_kb=153600`, `kill_timeout_ms=50`, `stall_limit_critical=40` | `hardware/google/pixel/mm/device_gki.mk` (§4.11) | vendor props | Under memory pressure only |
| 18 | Narrower background cpusets (background 2-3, system-background 1-3) | redbull (§2) | cpuset rc | A/B together with #5 |
| 19 | DISPLAY_CHANGE action (boost on rotation) | tangorpro `9360f84` (§4.10) | `powerhint.json` | First confirm the hint fires on dizi |
| 20 | Ship APEXes uncompressed | GrapheneOS (§3) | product mk | Boot after OTA and +250-300 MB `/data`; not runtime |
| 21 | `ro.surface_flinger.set_display_power_timer_ms=1000` | Every Pixel | vendor props | Tiny |

**Kernel-side items** (from Sultan's kernels, §5). They are numbered after the config items, but #22 and #23 rank
next to #1: both can be tested live with root, with no build.

| # | Change | Source | Where | Cost / risk |
|---|---|---|---|---|
| 22 | GPU DVFS assumes 60 Hz: try `/sys/class/kgsl/kgsl-3d0/devfreq/mod_percent` 100 to 200 at 120 Hz | Sultan floral `61aed63acdfe` | `init.dizi.rc` (later per-fps) | 1 sysfs write; watch GPU power |
| 23 | Pin `msm_drm` and `kgsl_3d0_irq` by name, each to its own **single** silver CPU (e.g. drm on CPU2, kgsl on CPU1), and exclude both in `msm_irqbalance.conf` | Sultan floral/redbull/tensynos; refines `peer-trees.md` item 3 | rc + irqbalance conf | Low risk |
| 24 | SDE PM QoS keeps CPUs 0-3 out of deep idle whenever the panel runs above 60 Hz: narrow `qcom,sde-qos-cpu-mask-performance` 0x0f to 0x03/0x00, or add a module param | Sultan floral `ce9326fc66c9` | DT or source msm_drm | Efficiency; check jank |
| 25 | `kgsl_devfreq_wq` as a WQ_HIGHPRI workqueue | Sultan gs201 `50a18e8bc5c7` | kgsl module (1 line) | Needs a module build |
| 26 | `vm.watermark_boost_factor=0` | Sultan tensynos `6458cdba62b5` | sysctl | Test with the zram/lmkd A/B |
| 27 | kgsl and msm_drm hot-path patches (fenced GMU write outside the spinlock, fence names, stack/kmem_cache allocations, commit QoS) | Sultan floral, arter97 sm8475 | kgsl / msm_drm modules | Tens of µs per frame; do last |

**Items from Qualcomm Pixels, the CLO parrot reference and LineageOS QTI trees** (§6). #28 is a **bug in our own
config**, and it goes first.

| # | Change | Source | Where | Cost / risk |
|---|---|---|---|---|
| 28 | **Fix the swapped CPU clusters in powerhint.json.** INTERACTION pins the A55s at max and the A78s at 1.5 GHz; stock does the reverse (gold 2208, silver 1497). Camera hints cap the wrong cluster. core_ctl goes to cpu0, where it's disabled | Verified against stock perfboostsconfig and CLO comments | `powerhint.json` | JSON. Changes the power profile; measure drain |
| 29 | LAUNCH: CPU idle limit (`cpu_dma_latency`), UFS clock gating off, GPU no-nap/force-clk | CLO parrot reference, Xiaomi stock, every Qualcomm Pixel; Google measured 5-20% faster cold launch | `powerhint.json` + UFS sepolicy | JSON + 1 genfscon. Low risk |
| 30 | Bring back the large-composition boost: implement the `*_offload` symbols in our perfd-client stub, and pin the HWC thread to the golds on hint `0x1097` | Stock HyperOS mechanism (`peer-trees.md` item 1) | `libqti-perfd-client/client.c` | Small C change. Low/medium risk |
| 31 | `cpu.uclamp.latency_sensitive=1` on top-app | Qualcomm Pixels (prefer_idle), moto sm7435 | `init.dizi.rc` | 1 line; measure |
| 32 | Add the msm_drm/kgsl IRQ numbers to `IGNORED_IRQ` | AOSPA parrot `0dd777c2` | `msm_irqbalance.conf` | Pairs with #23 |
| 33 | `drm vblankoffdelay -1` (vblank IRQ off immediately) | coral `abd0ad81`, redbull | `init.dizi.rc` | Power only; check vblank use first |

**What to test first:** #28, #1, #22, #29, #2. The rest follows the suggested order in "How to measure".

## 1. Pixel power HAL (libperfmgr / ADPF)

### Current state

- **Our tree already has the newest public code.** `evox-cnb/hardware/google/pixel` merges `android-16.0.0_r4`
  (`b38821afd45b`). `hardware/lineage/interfaces/power-libperfmgr/aidl` is byte-identical to Pixel for
  PowerHintSession, PowerSessionManager, ChannelManager/FMQ, SessionChannel, GpuCapacityNode, SessionRecords
  (HeuristicBoost) and UClampVoter. libperfmgr (HintManager, AdpfConfig parser) is identical too.
- **Lineage only removed things:** MetricUploader (pixelstats), DisplayLowPower, VR mode and the camera-mode cases.
- **We are one version ahead.** We implement IPower v7 (AUDIO_PERFORMANCE, disabled) against Pixel's v6.
- **Stubs even on Pixel's public code:**
  - CPU/GPU headroom: `Power.cpp:214-220` returns UNSUPPORTED.
  - GRAPHICS_PIPELINE: reported unsupported.
  - AUTO_CPU/AUTO_GPU: advertised as supported, but `setModeLocked` (`PowerHintSession.cpp:657`) only accepts
    POWER_EFFICIENCY.
  - CPU/GPU LOAD_SPIKE and the GPU_LOAD_DOWN/RESET hints: TODO stubs (`PowerHintSession.cpp:616-627`).
  - `sendCompositionData`: a log-only stub, and SF never calls it.
- **ADPF on dizi today:** HWUI is on (`725a92f`, `debug.hwui.use_hint_manager=true`, `ADPF_DEFAULT` profile from
  `adpf.md` §3.2, SELinux in place). SF is off. That was "Phase B" of `adpf.md` and was never done.

### What the A17 framework sends, and which HAL paths run

**HWUI** (`frameworks/base/libs/hwui/renderthread/HintSessionWrapper.cpp:136-202`):
- Uses tag `SessionTag::HWUI`. For SystemUI and the launcher, HintManagerService rewrites it to **SYSUI**.
- Reports CPU-only durations.
- CPU_LOAD_RESET after more than 100 ms idle.
- CPU_LOAD_UP on touch-down (`ViewRootImpl.java:7775`) and on inflations.
- GPU_LOAD_UP from SysUI `BlurUtils.kt:151` and the launcher blur.

**SurfaceFlinger** (`services/surfaceflinger/PowerAdvisor/PowerAdvisor.cpp`):
- Only active when `debug.sf.enable_adpf_cpu_hint` is set.
- Uses `createHintSessionWithConfig(SURFACEFLINGER)` plus FMQ.
- Reports durations **with GPU time** (`adpf_gpu_sf` is enabled).
- CPU_LOAD_UP when blur, shadow or client-composition effects appear (`:786-815`).
- CPU_LOAD_RESET plus `setBoost(DISPLAY_UPDATE_IMMINENT)` after more than 80 ms idle (`:147-178`).
- `setMode(EXPENSIVE_RENDERING)` on GPU composition.

**The HAL** (`PowerHintSession.cpp:558-647`):
- Every session hint also runs `DoHint("<HINT_NAME>")` **if powerhint.json has an Action with that name**. The
  names are `CPU_LOAD_UP`, `CPU_LOAD_RESET`, `CPU_LOAD_RESUME`, `GPU_LOAD_UP`, and the "stale session" variants
  `PER_ADPF_SESSION_FIRST_FRAME` and `ALL_ADPF_SESSIONS_FIRST_FRAME` (commit `921f30dbe6a6`).
- **Our powerhint.json defines none of these names, and no `DISPLAY_UPDATE_IMMINENT` action.** So SF skips that
  boost (`isBoostSupported` is false).
- For SF and SYSUI sessions, GPU_LOAD_UP also fires `EXPENSIVE_RENDERING` for 175 ms. On dizi that action sets
  the kgsl `min_freq` to 940 MHz (fmax), so every blur pins the GPU at fmax. Item #15 checks whether 734 MHz is
  enough.

### Candidates

1. **Enable SF ADPF** (action #2):
   - What it adds: PID uclamp on SF main and RenderEngine; SF's own CPU_LOAD_UP and RESET hints; GPU-time
     reporting.
   - Already in place: the kernel and SELinux prerequisites (RT uclamp default 0 in
     `init.kernel.post_boot-parrot.sh:74`; setsched on surfaceflinger in `hal_power_default.te`).
   - Keep the SF uclamp ceiling at about 400. A floor above about 440 moves SF onto the A78s (`adpf.md` §3.3).
2. **`CPU_LOAD_RESET` action** (#3):
   - Sets kgsl `devfreq/min_freq` to 600 MHz for 50 ms, plus bwmon DDR `min_freq` 1555000 for 33 ms.
   - Pixel caiman uses the same pattern: GPUMinFreq 50 ms, MemFreq 33 ms.
   - Optionally make `ALL_ADPF_SESSIONS_FIRST_FRAME` stronger, for a true wake from idle.
   - Both nodes already exist in our JSON. Fires once per idle-to-active transition.
3. **`DISPLAY_UPDATE_IMMINENT` action** (#4):
   - Pixel raises the cpufreq `down_rate_limit_us` for 50 ms (5000 on little, 20000 on mid/big), so frequency
     doesn't collapse during the first frames after idle.
   - The WALT equivalent is `/sys/devices/system/cpu/cpufreq/policy{0,4,7}/walt/down_rate_limit_us`
     (`cpufreq_walt.c:505`). `post_boot` sets it to 0, and our JSON already writes `policy*/walt/` nodes.
   - Optionally add `ro.surface_flinger.display_update_imminent_timeout_ms=50`, Pixel's value.
4. **Real WALT actions for the ADPF task profiles** (#13):
   - The HAL applies these profiles, all of which are no-ops on dizi (`a25d7c8`):
     - `SCHED_QOS_SENSITIVE_EXTREME` to HWUI, SYSUI and SF threads;
     - `SCHED_QOS_SENSITIVE_STANDARD` to other sessions;
     - `SCHED_QOS_NONE` on pause or close;
     - `PreferIdleSet` to its own threads.
   - Mapping in `task_profiles.json` (`<pid>` becomes the tid):

     | Profile | Action |
     |---|---|
     | EXTREME | `WriteFile /proc/sys/walt/sched_wake_up_idle "<pid> 1"` and `sched_pipeline "<pid> 1"` |
     | STANDARD | `sched_wake_up_idle` only |
     | NONE | both set to `0` |
     | PreferIdleSet | `sched_wake_up_idle` |

   - The WALT sysctls are in `walt/sysctl.c:811-868`. `sched_pipeline` is MVP queueing, up to 12 ms per window
     (`walt.h:891`).
   - Risk: MVP lets RenderThread pre-empt other CFS work. Watch for starvation and power.
5. **HeuristicBoost** (#14):
   - Counts missed cycles and raises the PID floor/ceiling.
   - tangorpro values: thresholds 2/8, ceiling [480,722], floor [230,410].
   - 722 is about 2 GHz on the A78s, and any floor above 0 changes WALT placement. Start with ceiling [512,640] and
     floor [0,256].
6. **Per-tag profiles** (#14): give SF a lower High, and give SYSUI a higher Init for the shade and Recents.
7. **Correctness fix** (no performance effect): `SupportManager.cpp:212` should report AUTO_CPU/AUTO_GPU as
   unsupported.
8. **Low value:**
   - GpuCapacityNode port to kgsl: about 200 LOC. Only SF and games feed it, and blur already pins fmax.
   - Headroom API: only games use it.

Not applicable: HeuristicRampup and TgidTypeChecker (they need `/proc/vendor_sched`), `EnableSFPreferHighCap` (SF
is RT, and Pixel itself ramped it down), `GPU_LOAD_UP_SYSTEM`, and MetricUploader.

## 2. Pixel device and system config (memory, ART, scheduler, graphics)

Sources: `device/google/{gs-common,gs201,zuma,zumapro,tangorpro,caimito,redbull}`, `kernel/google-modules/soc/gs`.

### Candidates

1. **ART ISA variant** (#9), status **differs**:
   - Our setting: `TARGET_CPU_VARIANT_RUNTIME := kryo300` (`BoardConfig.mk:28-32`), which becomes
     `dalvik.vm.isa.arm64.variant=kryo300`. Stock HyperOS is the same.
   - Problem: in `art/runtime/arch/arm64/instruction_set_features_arm64.cc`, `kryo300` has no CRC, LSE atomics, FP16
     or dotprod. All on-device AOT and JIT code (Play apps, bg-dexopt) misses them, although the A55/A78 have them.
   - What Pixel uses: redbull uses `cortex-a76`. gs201 and zuma use `armv8-2a` + `cortex-a55`.
   - Cheapest change: the runtime variant alone, which needs no full rebuild.
   - Test:
     1. `setprop dalvik.vm.isa.arm64.variant cortex-a76`.
     2. `pm compile -f -m speed-profile <pkg>`.
     3. `oatdump --header-only` to confirm the features.
     4. `app-start.sh`.
   - Expected gain: small, unpublished.
2. **CPU-share weights** (#5), status **new**:
   - Pixel (`zuma/conf/init.zuma.rc:901-910`) sets `cpu.shares` 20480 for system, foreground, camera-daemon,
     nnapi-hal and rt; 1024 for background and system-background; 512 for dex2oat. The rc comment says background
     gets about 5% under contention.
   - We set no `cpu.shares` anywhere.
   - This is plain CFS, so it works with WALT.
   - Only matters under background load. Test while bg-dexopt or a Play update runs.
3. **dex2oat CPU placement** (#6), status **new**:
   - We set no `dalvik.vm.*dex2oat-cpu-set/threads`, so dex2oat can use the prime core.
   - redbull sets `dex2oat-cpu-set 0,1,2,3,4,5,7` and `dex2oat-threads 6` (`redbull/init.hardware.rc:801-803`).
   - Proposed:
     - `dalvik.vm.background-dex2oat-cpu-set=0,1,2,3`
     - `background-dex2oat-threads=4`
     - `dex2oat-cpu-set=0-6`
     - Leave `boot-dex2oat-*` unset, so first boot stays fast.
   - artd reads these in `art/artd/artd.cc:2204-2216`. See also GrapheneOS item 1 (concurrency 2).
4. **`vm.watermark_scale_factor` 200** (#10), status **differs**: ours is 60, from Xiaomi post_boot.
   - Effect: kswapd starts earlier, so fewer direct-reclaim stalls during launch. Costs some cache.
   - Test: `/proc/vmstat` `allocstall_*`/`pgsteal_direct`, plus app-start.
   - Leave swappiness at 180. Pixel's 60 depends on its pixel_mm_hint module.
5. **Background cpusets** (#18): redbull keeps background off its first little cores. Candidate: background 2-3,
   system-background 1-3 (both are 0-3 today).
6. **SurfaceFlinger:**
   - `set_display_power_timer_ms=1000` (#21) is still missing.
   - Pixel durations: zuma 10.5/16.6 ms; redbull 10.5/20.5 ms, earlyGl 13.5/21 ms. The "odd" values in the
     M0Rf30/noble6 dizi trees are redbull's. Our measurements already rejected them (sf 10 ms worse; 20.8 ms adds
     pen latency), so keep 16.7/16.7.
7. **zram writeback**, status **new**, medium cost:
   - Pixel: `config_zramWriteback=true`, a 512 MB backing device, `ro.zram_backing_device_min_free_mb=1536`.
   - A17 `mmd` supports it (behind the aconfig flag `mmd_enabled`).
   - Mainly helps the 6 GB SKU. Costs UFS 2.2 wear.
   - Only worth trying if lmkd kill counts show cached apps dying.
8. **Kernel-module ideas, all low priority:**
   - **pixel_mm_hint:** forces swappiness to 0 while file cache is sufficient. Its hook `android_vh_tune_swappiness`
     exists in our 5.10 kernel and is unused. Its userspace is not public.
   - **pa_kill:** frees memory on camera launch.
   - **kswapd/kcompactd:** Pixel keeps them off the prime core; we could do the same with `taskset` from rc.
   - **WALT `sched_lib_name`/`sched_lib_mask_force`:** redbull sets `"UnityMain,libunity.so"`, mask 255. Games only.

### Already the same as Pixel, or measured and rejected

- **Memory:**
  - zram lz4 at 50% of RAM (capped at 4 GB), page-cluster 0, compaction_proactiveness 0.
  - lmkd at AOSP defaults. Pixel's lmkd tuning comes from server-side `device_config`, which isn't public.
- **ART:**
  - The dalvik heap `phone-xhdpi-6144` profile was rejected (`performance.md` §15). `heapgrowthlimit=256m` matches
    redbull.
  - SystemUI and the launcher are compiled with `speed`.
  - `pm.dexopt.*` and the boot image profile are AOSP's.
  - CMC GC, the freezer and `config_customizedMaxCachedProcesses=1024` are AOSP defaults.
- **Graphics:**
  - Already have: Vulkan HWUI, 3 framebuffer acquired buffers, content detection, the 200 ms touch timer.
  - Measured and rejected: layer caching, Vulkan/Graphite RenderEngine. gl backpressure was neutral.
- **MGLRU:** Pixel itself disables it on zuma (`zuma/conf/init.zuma.rc:8`). Don't backport it to 5.10.

### Not applicable or placebo

- `ro.launcher.blur.appLaunch=0`: nothing reads it (not in cnb Launcher3, not in the Pixel Launcher dex).
- `audio.spatializer.effect.util_clamp_min`: nothing reads it.
- `frame_rate_multiple_threshold` saves power but doesn't improve smoothness.
- The 80 ms SF idle timer is tuned for Pixel's OLED; we keep 1100 ms.
- Tensor-only, nothing to port: vendor_sched/vh_sched (ug, group throttle, auto_uclamp_max), pixel_em, the teo
  cpuidle switch, lz77eh, `/sys/kernel/vendor_mm`.
- Not possible on our kernel or hardware:
  - `percpu_pagelist_high_fraction` needs 5.14+.
  - `blkio.prio.class` needs `BLK_CGROUP_IOPRIO`, which our GKI lacks.
  - Pixel's f2fs `data_io_flag` and UFS tweaks are tuned for Pixel's UFS driver.
- Not performance:
  - PixelPropsUtils, Adaptive Battery and DPS.
  - Copying swappiness=60 without pixel_mm_hint, or global `speed` compilation, would make things worse.

## 3. GrapheneOS

Branch `17` (base `android-17.0.0_r1`, release 2026100200; adevtool 649267e9, 2026-09-30).

### What it offers

- **No Pixel device trees any more.** Release 2025111800 replaced their remnants with `adevtool`, which builds from
  stock vendor images. `powerhint.json` and `task_profiles.json` ship as stock prebuilts; the repo only stores their
  SHA-256 (`vendor-specs/google_devices/tangorpro.yml`).
- **To read the stock A17 Pixel Tablet powerhint.json**, run `adevtool download` and extract the tangorpro factory
  image. This is the only way to see Google's current tablet power config.
- **Current stock props and overlays are committed** in `adevtool/vendor-skels/google_devices/<device>/`
  (`sysprop/vendor.prop`, `product.prop`, decompiled RROs), at CP3A.260905.009 (A17 QPR1). tangorpro's include:
  - SF durations 16.6/10.5 ms, early 16.6 ms;
  - `debug.sf.enable_adpf_cpu_hint=true`, `debug.hwui.use_hint_manager=true`;
  - `ro.lmk.filecache_min_kb=153600`, `ro.lmk.stall_limit_critical=40`;
  - `mmd.zram.*` writeback.
- **Graphene's own changes** are almost all security hardening. No hidden perf patch set.

### Worth taking

1. **`pm.dexopt.bg-dexopt.concurrency=2`**, status **new**:
   - From [art 2c1741d06b48](https://github.com/GrapheneOS/platform_art/commit/2c1741d06b480bd6886bd8a98615e651e2f7e7c0).
     AOSP `ReasonMapping` already reads the prop.
   - Idle-time compilation finishes about 2x sooner, at no runtime cost.
   - Combine it with the dex2oat CPU placement in §2.
2. **Uncompressed APEXes** (`OVERRIDE_PRODUCT_COMPRESSED_APEX := false`), status **new**:
   - From [build 2e7d90daf427](https://github.com/GrapheneOS/platform_build/commit/2e7d90daf427e63919f9669da9700cb9172413cc).
   - cnb ships 27 of 37 system APEXes as `.capex` (136 MB).
   - Saves decompression on first boot and after each OTA, and about 250-300 MB of `/data`. super has room (3.9 of
     9.1 GB used).
3. **ContentService without the 10 s delay for Settings observers**, status **new**:
   - From [frameworks_base 038cf989db46](https://github.com/GrapheneOS/platform_frameworks_base/commit/038cf989db46ea329023373744a9c4774c0b3450).
   - Responsiveness of background system apps, not smoothness.
4. **Stability watch for two A17 flags, both ENABLED in cnb:**
   - `disable_frozen_process_wakelocks`
     ([896f0aff33f0](https://github.com/GrapheneOS/platform_build_release/commit/896f0aff33f0122bd2b47ced05757cd5de6b2ed0),
     [#6851](https://github.com/GrapheneOS/os-issue-tracker/issues/6851)). Symptom: system_server
     `weak global reference table overflow` full of `PowerManagerService$WakeLock`.
   - `no_sbnholder`
     ([702ecd870126](https://github.com/GrapheneOS/platform_build_release/commit/702ecd870126cbf92fe6ebf23031fbc0dbd2f35c)).
     Symptom: `TransactionTooLarge` in NotificationManager.
   - Keep both on unless those crashes show up in our logs.
5. **Small robustness fixes:**
   - MediaMetadata `Bitmap.asShared()`
     ([6a65e03eea53](https://github.com/GrapheneOS/platform_frameworks_base/commit/6a65e03eea53aff0d0b6c0f083ea84f888651c6f)).
   - Safety Center A17 slow-scan fix
     ([Permission 4d6005dbabf3](https://github.com/GrapheneOS/platform_packages_modules_Permission/commit/4d6005dbabf3f2bf96e5215c5c2801809b051bf3)).
6. **A test, not a fix:** `ColdFileReadBenchmark`
   ([cf9df0172e8b](https://github.com/GrapheneOS/platform_frameworks_base/commit/cf9df0172e8b7435ed416f9ee3038b525563a32c)).
   - It measures cold mmap reads when swap is nearly full, which suits our 4 GB zram at swappiness 180.
   - The Pixel bug it targets (`vh_mm` readahead, issues #8830/#8843) doesn't apply: no stock dizi module registers
     those hooks.

### Costs performance: don't port

| Feature | Why not |
|---|---|
| Exec spawning ([c74617c8e9c0](https://github.com/GrapheneOS/platform_frameworks_base/commit/c74617c8e9c068d24893cf79592f6fcea28f77af)) | Graphene's [docs](https://grapheneos.org/usage#exec-spawning): about 200 ms per cold start on flagships, more on weaker SoCs, plus more RAM (no zygote sharing). |
| hardened_malloc | Slower and uses more memory than scudo. Also needs 48-bit VA; our GKI is 39-bit, and Graphene itself falls back to scudo there. |
| MTE | The A55/A78 don't have it. |
| No JIT + `speed` AOT for everything | Larger odex, slow installs, a full recompile after every OTA. Matches our "no global speed" verdict. |
| Package parser cache disabled | Slower boot. |
| Kernel hardening (init_on_free, slub canaries, RANDSTRUCT, BPF JIT hardening, ...) | All cost. Keep our `INIT_ON_FREE` off. |
| Debloat savings | They come from not shipping privileged GMS. EvoX ships GMS. |
| `DeviceIdleJobsController` whitelist change, FusedLocation GNSS policy | With privileged GMS these cost battery. |

## 4. Pixel Tablet device tree (tangorpro) and newer Pixels

- **The Pixel Tablet has a 60 Hz panel.** Commit `7567ae2` removed its 90/120 FPS profiles "since the display only
  supports 60FPS". Its ADPF numbers are tuned for 16.6 ms frames. For 120 Hz tuning, use Pixel 9
  (`caimito/perf/powerhint-komodo.json`) and Pixel 9 Pro Fold (`comet/powerhint-comet.json`).
- **Most Pixel scheduler tuning won't carry over.** It goes through `/proc/vendor_sched` and the `sched_pixel`
  governor, which dizi doesn't have. What carries over is the pattern (which hint does what), AOSP-level
  props and overlays, and libperfmgr features our HAL already has but our JSON doesn't use.

### 4.1 Scheduler settings per refresh rate (action #1)

- **What Pixel does:** the HWC sends `REFRESH_60FPS`/`REFRESH_120FPS` modes to the power HAL. Each selects its own
  ADPF profile (`ReportingRateLimitNs` 83 ms at 120 Hz) and top-app uclamp.
- **Stock HyperOS on dizi does the same** through the QTI perf HAL, boost `0x0000109B`, per fps
  (`stock/dump/vendor/etc/perf/perfboostsconfig.xml:541-583`, decoded through `targetresourceconfigs.xml`):

  | Refresh rate | `walt/pl` (both clusters) | `sched_ravg_window_nr_ticks` | Other |
  |---|---|---|---|
  | 120 Hz | 1 | 2 (8 ms) | `walt_rtg_cfs_boost_prio`=119, `walt_low_latency_task_threshold`=100 |
  | 45/60 Hz | 0 | 5 (20 ms) | — |

- **dizi today:** we don't ship perfd. At 120 Hz the window stays at 4 ticks (16 ms), about twice the 8.3 ms frame
  time, and `post_boot` sets `pl` to 0. That slows frequency ramp-up for SF, HWC and RenderThread bursts.
- **Translation:**
  1. Write `2` to `/proc/sys/walt/sched_ravg_window_nr_ticks` (the kernel accepts only 2/3/4/5/8,
     `walt/sysctl.c:176`).
  2. Write `1` to `policy{0,4}/walt/pl` in `init.dizi.rc`.
  3. Measure jank and idle power.
  4. If idle power suffers, make it dynamic later. We have no refresh-rate notifier: our HWC sends no fps hint, and
     AOSP SF doesn't tell the power HAL.
- **Check stock first:** on HyperOS at 120 Hz, run `cat /proc/sys/walt/sched_ravg_window_nr_ticks`.
- **Why this ranks first:** it is the only item backed by Xiaomi's own tuning for this exact SoC and panel.

### 4.2 First-frame actions (action #3)

- **tangorpro:** `CPU_LOAD_RESET` raises the DDR (MIF) floor for 33 ms, the GPU floor (302 MHz) for 50 ms, and sets
  `TAPreferHighCap` for 33 ms. Pixel 9 adds `GPUPowerOn` (10 ms) and DSU floors.
- **Google's reasons:**
  - [`12b6dd3`](https://android.googlesource.com/device/google/tangorpro/+/12b6dd337ec8bee664f10af0f20863537ebebdf0):
    "Set minimum mif freq for 1st frame to avoid memlat can't reflect in time".
  - [`f55c796`](https://android.googlesource.com/device/google/tangorpro/+/f55c7962842f3829d35c6921cd45bdac05660aa4):
    "Boost GPU(302000) by 1st frame".
  - [`af98660`](https://android.googlesource.com/device/google/tangorpro/+/af98660b14d33ecfe1e093256463ff4d366bf294):
    "janks caused by longer runnable time".
- **Translation:**
  - `...BwmonDdrMinFreq` = 1555000 for 33 ms.
  - kgsl `devfreq/min_freq` = 600 MHz for 50 ms.
  - Optionally kgsl `idle_timer` as the analogue of GPU power-on.
  - Put a bigger pulse on `ALL_ADPF_SESSIONS_FIRST_FRAME` (wake from full idle).

### 4.3 SF ADPF (action #2)

- Google enabled it in [`ba8ccf3`](https://android.googlesource.com/device/google/tangorpro/+/ba8ccf33f5d756199ee2b753a4cfe5c85a498e17),
  "to reduce drops and save power".
- The same commit **removed the static SF uclamp boosts**. When we enable SF ADPF, re-check
  `ro.surface_flinger.uclamp.min` (`peer-trees.md` item 2): the two may double up.

### 4.4 MVP for SF threads via task profiles (action #13)

- **Pixel:** with `"OtherConfigs": {"EnableSFPreferHighCap": true}`, the HAL applies `PreferHighCapSet` to SF main
  and RenderEngine only (libperfmgr [`71dde5f`](https://android.googlesource.com/platform/hardware/google/pixel/+/71dde5fc5ee88c453354fec47408d43b9c0d8000)).
  This is narrower than §1's EXTREME mapping, which also covers every app's HWUI threads. **Start with the SF-only
  variant.**
- **Which WALT knob to use:**
  - `sched_low_latency "<pid> 1"` is what stock QTI uses (perf opcode 0x34; HyperOS's QTI SF extension passes the
    compositor tids through `libcomposerextn SendCompositorTid`). But it is a **no-op while
    `walt_low_latency_task_threshold` is 0**, and stock sets that threshold to 100 only at 120 Hz (§4.1). So use it
    together with that threshold.
  - Alternatively use `sched_pipeline`, or `sched_wake_up_idle` (§1).
- **Don't map it through `SFMainPolicy`.** SF calls `SetTaskProfiles(0, …)`, and WALT rejects pid 0.
- Google later added the flag `ramp_down_sf_prefer_high_cap` ([`bee4686`](https://android.googlesource.com/platform/hardware/google/pixel/+/bee4686d6bc75bd526f0a2416d5180ddad12f6bc)).
  Measure before keeping it.

### 4.5 LAUNCH (action #7)

- **tangorpro:** LAUNCH lasts 5000 ms with DDR at max, TA uclamp 764 and FG 159. `LAUNCH_EXTEND` adds 2 s of
  uncapped frequency after LAUNCH ends.
- **dizi:** LAUNCH has `sched_boost` 1 and CPU floors with a 2000 ms cap. No DDR or GPU floor.
- **Change:** add bwmon DDR `min_freq` 1555000. The framework ends LAUNCH early anyway, so a 5 s cap is cheap.

### 4.6 EGL blob cache (action #12)

- gs201 sets `ro.egl.blobcache.multifile=true` and `multifile_limit=33554432`. The default is false
  (`egl_cache.cpp:239`).
- [`5c4cbe4`](https://android.googlesource.com/device/google/gs201/+/5c4cbe4023afd9a4380d8acd0249e6cd9c264310) cut
  the limit from 128 MB to 32 MB: "Loading the larger limit is taking too long in the field".
- Effect: fewer GLES shader recompiles. It does not affect HWUI-Vulkan.

### 4.7 Tablet input (action #8)

- **Motion prediction:** tangorpro's overlay sets `config_enableMotionPrediction=true` and
  `config_motionPredictionOffsetNanos=-4000000`. dizi already ships `system/etc/motion_predictor_model.tflite`, but
  the AOSP default is false. Enabling it lowers perceived pen latency in apps that use `MotionPredictor`.
- **Touch slop:** tangorpro sets `config_viewConfigurationTouchSlop=5dp` because 8 dp "is roughly 1.5mm on this
  device". On dizi, 8 dp is about 1.63 mm (320 dpi logical vs about 249 physical); 6 dp would be about 1.2 mm, so
  scrolls start sooner.

### 4.8 Pinner list (action #11)

- gs201 pins core-oj, core-libart, framework, services, `/system/bin/surfaceflinger` and the SystemUI apk
  ([`59615c9`](https://android.googlesource.com/device/google/gs201/+/59615c9496a7e5ee8b6c525be3c7e86cb90d1141)).
  It also sets `config_pinnerHomePinBytes=6291456`.
- cnb's default list is empty, and none of our overlays set it.
- Effect: fewer major faults on hot paths under memory pressure.

### 4.9-4.12 Smaller items

- **`debug.sf.frame_rate_multiple_threshold=120`** (gs201 `device.mk:709`): video stays at 60 Hz
  (`RefreshRateSelector.cpp:931-964`). Saves power.
- **DISPLAY_CHANGE** ([`9360f84`](https://android.googlesource.com/device/google/tangorpro/+/9360f84ce1c3d295d35068b02edc00f2cc1a1713)):
  a 5 s boost on rotation. First check that `M:DISPLAY_CHANGE` appears in a trace when dizi rotates.
- **Memory props:**
  - `hardware/google/pixel/mm/device_gki.mk`: `ro.lmk.filecache_min_kb=153600`, `kill_timeout_ms=50`,
    `stall_limit_critical=40`. dizi sets no `ro.lmk.*`.
  - gs-common: `pm_freeze_timeout 1000` ([`fa0cce4`](https://android.googlesource.com/device/google/gs-common/+/fa0cce475e349be3c681071b18ec8704817bf9d7)).
  - gs201's watermark change [`55f8dbd`](https://android.googlesource.com/device/google/gs201/+/55f8dbd064ce0a17d8c3c82126e3ca59ec7ddd0d):
    "better handle burst memory allocation".
  - Our 60 comes from `post_boot` (a dizi/ruan special case; QTI's comment says efk is used instead).
- **Efficiency (action #15):**
  - Current tangorpro, Pixel 9 and Fold configs have **no INTERACTION action**. They rely on ADPF, top-app uclamp
    and CPU_LOAD_RESET. That supports slimming dizi's heavy INTERACTION (silver at max, `sched_boost` 2) once ADPF
    covers SF.
  - Pixel's EXPENSIVE_RENDERING floors the GPU at a mid level (572 of 848 MHz on G2; 419 MHz on Pixel 9). Ours
    floors at max.
- **SystemUI profile:** low value.
  - Pixel detects SystemUI via `/proc/vendor_sched/check_tgid_type`. We'd need a cmdline fallback patch.
  - Google itself excluded SystemUI from the higher initial boost (libperfmgr `0978e98`).

### Not applicable

- **vendor_sched / sched_pixel knobs:** prefer_idle/high_cap/fit, rampup_multiplier, dvfs_headroom, npi_packing,
  pixel_em, PMU limits.
- **Pixel 9's DISPLAY_UPDATE_IMMINENT DPU early wakeup.** The msm_drm analogue (`sde_encoder_early_wakeup`) only
  works on command-mode panels. dizi's `n83_35_02_0a_wqxga_video_cphy` is video mode (`recon/running.dts:19962`).
  The CPU down-rate hold (action #4) still applies.
- **Mali/Exynos devfreq nodes** (`hint_min_freq`, `capacity_headroom`, MIF/INT/DSU). Only the intent carries over,
  through kgsl and bwmon.

## 5. Sultan (kerneltoast) and other kernel developers

### Context

- **Best port source:** Sultan's archived Pixel 7 kernel `android_kernel_google_gs201` (branch `15.0.0-sultan`) is
  **5.10.214 GKI**. SBalance, the kswapd changes and his other work are already ported to 5.10 there. His newest
  kernel, `tensynos` (Pixel 9, 16.0.0-sultan), is 6.1.
- **Little measured data.** His XDA threads advertise features without numbers. The only figures in his commits:
  - `60d154ffc7e5`: −7% energy in light gaming (Tensor G4);
  - floral `f9a3cc06231b`: fenced GMU writes average 28 µs on SD855.
- **His build approach doesn't transfer.** On Pixel he drops GKI entirely (integrated modules, kabi removed, vendor
  hooks off). We need KMI/CRC compatibility with Xiaomi's blob modules, so only vendor-module changes (kgsl, msm_drm),
  KMI-safe core changes, and runtime knobs are usable.
- **His Qualcomm-era kernels (floral = Pixel 4 SM8150, redbull, OnePlus sm8250) matter more than his Tensor ones.**
  They touch the same kgsl and SDE drivers we use.
- **Already in our 5.10.269 tree:**
  - TTWU_QUEUE off (WALT, `walt.c:4423`);
  - SCHED_FIFO kgsl dispatcher and events workers;
  - POPP/L2PC removed;
  - the gen7 GMU AB vote;
  - IRQ-affined SDE PM QoS (`sde_kms_irq_affinity_notify`);
  - `compaction_proactiveness=0`.

### 5.1 GPU DVFS assumes 60 Hz (action #22)

- Sultan's [61aed63acdfe](https://github.com/kerneltoast/android_kernel_google_floral/commit/61aed63acdfe), "adreno_tz:
  Fix GPU target frequency calculation for high refresh rates". The TZ governor assumes 60 Hz frames and picks
  frequencies that are too low; he scales `busy_time` by refresh/60.
- Our kgsl already has the multiplier as a sysfs knob: `priv->mod_percent` (`governor_msm_adreno_tz.c:367`, clamped
  to 10-1000), at `/sys/class/kgsl/kgsl-3d0/devfreq/mod_percent`, default 100.
- The stock perf HAL defines opcode GPU minor 0xA for it (`commonresourceconfigs.xml:226`), but no stock perfboost
  uses it.
- **Test:** `echo 200 >` it at 120 Hz. Compare GPU frequency residency (`gpuclk`, `trans_stat`), SF GPU-composition
  frame times, jank and power.
- **If it helps:** set it in rc, or per refresh rate.
- **Why it ranks high:** it goes straight at the known bottleneck, GPU composition during transitions.

### 5.2 Display and GPU IRQ pinning (action #23)

- Sultan put the DRM IRQ and kthreads on prime and kgsl on big ([eb82f72059ab](https://github.com/kerneltoast/android_kernel_google_floral/commit/eb82f72059ab),
  [343ac2ef1acf](https://github.com/kerneltoast/android_kernel_google_floral/commit/343ac2ef1acf)).
- On redbull he reverted the blanket kgsl affinity because it also moved `kgsl_hfi_irq`/`kgsl_gmu_irq`
  ([0630f44302ba](https://github.com/kerneltoast/android_kernel_google_redbull/commit/0630f44302ba)). The reapply
  targets only `kgsl_3d0_irq` ([a50f128202f3](https://github.com/kerneltoast/android_kernel_google_redbull/commit/a50f128202f3)).
  **Pin by name.**
- **Use a single-CPU mask.** On 5.10 the SDE affinity notifier copies the *requested* mask and applies a 300 µs
  resume-latency QoS to every CPU in it (`sde_kms.c:4301-4390`), but the IRQ only fires on the first CPU. See
  Sultan's [673289d33ccc](https://github.com/kerneltoast/android_kernel_google_tensynos/commit/673289d33ccc).
- **Don't use prime or CPU0.** The QoS follows the drm IRQ, so pinning it to prime keeps prime out of deep idle
  whenever the screen is on. Use separate silver CPUs, as Spacewar does.

### 5.3 SDE PM QoS blocks silver deep idle at 120 Hz (action #24)

- `_sde_encoder_pm_qos_add_request` (`sde_encoder.c:267`) applies `qcom,sde-qos-cpu-dma-latency = 300 µs` to mask
  `0x0f` when `frame_rate > 60` (`kernel/scratch/dt/base.5.dts:16924-16927`).
- Silver power-collapse exit latency is 900 µs ("pc") and 750 µs ("rail-pc"), so at 120 Hz CPUs 0-3 never collapse
  while the screen is on. That also blocks the l3-off and cx-ret cluster states.
- Sultan removed the equivalent requests on floral ([ce9326fc66c9](https://github.com/kerneltoast/android_kernel_google_floral/commit/ce9326fc66c9)).
- **Check on the device:** compare cpuidle `state*/usage` on cpu0 at 60 vs 120 Hz.
- **Test:** narrow the DT mask, or add a module param to our source msm_drm (like patch 0003). Measure screen-on
  idle and reading power, and check jank (HWC runs on silver today).

### 5.4 Other items

- **`kgsl_devfreq_wq` high priority (action #25).** From [gs201 50a18e8bc5c7](https://github.com/kerneltoast/android_kernel_google_gs201/commit/50a18e8bc5c7).
  - kgsl DVFS updates run on nice-0 freezable kworkers (`kgsl_pwrscale.c:750`), which get starved during busy
    transitions.
  - Change it to `alloc_workqueue(..., __WQ_ORDERED|WQ_HIGHPRI|WQ_FREEZABLE|WQ_UNBOUND|WQ_MEM_RECLAIM, 1)`.
- **`vm.watermark_boost_factor=0` (action #26).** From [6458cdba62b5](https://github.com/kerneltoast/android_kernel_google_tensynos/commit/6458cdba62b5):
  boosting causes kswapd thrashing. Our default is 15000 and nothing sets it.
- **kgsl hot path (action #27):**
  - Fenced GMU write outside the spinlock ([f9a3cc06231b](https://github.com/kerneltoast/android_kernel_google_floral/commit/f9a3cc06231b)).
    Ours spins with `udelay(10)` under `preempt_lock` with IRQs off (`adreno_gen7_ringbuffer.c:179`). Port with care
    around preemption.
  - Drop the fence debug names ([19b88cc83ca4](https://github.com/kerneltoast/android_kernel_google_floral/commit/19b88cc83ca4)).
  - Stack or kmem_cache allocations for drawobjs ([0fd878a6e4f3](https://github.com/kerneltoast/android_kernel_google_floral/commit/0fd878a6e4f3),
    arter97 [888bbe476b81](https://github.com/arter97/android_kernel_nothing_sm8475/commit/888bbe476b81)).
  - Lock-less page pool ([848a61724f66](https://github.com/kerneltoast/android_kernel_google_floral/commit/848a61724f66)).
- **msm_drm commit path (action #27):**
  - Shallow-idle QoS during the atomic ioctl and commit worker ([2524cb82c8db](https://github.com/kerneltoast/android_kernel_google_floral/commit/2524cb82c8db),
    [117ded9308c6](https://github.com/kerneltoast/android_kernel_google_floral/commit/117ded9308c6)). Port it with
    `dev_pm_qos` in `msm_atomic.c`.
  - Skip the per-kickoff VBIF error clear ([1b0ade69f426](https://github.com/kerneltoast/android_kernel_google_floral/commit/1b0ade69f426),
    `sde_crtc.c:4093`).
  - Stack allocations ([788cc01213c6](https://github.com/kerneltoast/android_kernel_google_floral/commit/788cc01213c6),
    [ff8b205588c2](https://github.com/kerneltoast/android_kernel_google_floral/commit/ff8b205588c2)).
  - arter97's `sde_fence` kmem_cache ([2b31bad42641](https://github.com/arter97/android_kernel_nothing_sm8475/commit/2b31bad42641)).
  - Avoid the dim-layer optimization `c8a0caa98741`: kdrag0n reverted it
    ([7adc211eaf15](https://github.com/kdrag0n/proton_kernel_redbull/commit/7adc211eaf15)).
  - Expected effect: tens of µs per commit. Do these last, and measure with `perf top`.
- **kgsl wake-on-touch.** Enabled on dizi. Sultan wakes on the `GPU_COMMAND` ioctl instead
  ([1df7a5777009](https://github.com/kerneltoast/android_kernel_google_floral/commit/1df7a5777009)). That is a small
  power gain, and it costs a little first-frame latency.
- **SBalance: low value here.**
  - On Pixel it replaced having no balancer at all; dizi already runs `msm_irqbalance`.
  - Sultan's own changelog says it "never work[ed] correctly" until December 2024
    ([53139c598e6e](https://github.com/kerneltoast/android_kernel_google_tensynos/commit/53139c598e6e)).
  - Its 2024 statistics fix adds a field to the ABI `struct irq_desc`. Use a side array instead.
  - Do action #23 first.
- **kswapd stops early when no allocation is waiting** (gs201 `6c9701998f23`, `7a38f9f65b69`, `45c25fcc77fb`).
  KMI-safe, but it changes the PSI behaviour that lmkd depends on. Low priority.
- **Scheduler knobs to try at runtime** (we have `SCHED_DEBUG=y`): `sched_migration_cost_ns=0` and
  `NO_CACHE_HOT_BUDDY` ([9fdc36b53228](https://github.com/kerneltoast/android_kernel_google_tensynos/commit/9fdc36b53228),
  [4c9612701dac](https://github.com/kerneltoast/android_kernel_google_tensynos/commit/4c9612701dac)). WALT does
  most placement, so expect a small effect.
- **Measured energy model** via kdrag0n's freqbench ([4b577a681411](https://github.com/kdrag0n/proton_kernel_redbull/commit/4b577a681411)).
  Research only: needs power metering.

### Skip

| Item | Why |
|---|---|
| Simple LMK | Requires `!PSI`; we run PSI lmkd |
| cpu_input_boost / devfreq_boost | Sultan dropped them himself; WALT `input_boost`, the power HAL and bus_dcvs cover this |
| CASS, schedutil changes, PELT 16 ms, TEO revert, Tensor AIO, EH, mali | WALT owns this on our SoC, or Tensor-only |
| Compile-time `sched_feat`, disabling `GENERIC_IRQ_EFFECTIVE_AFF_MASK` | Breaks KMI |
| kshrinkd, shrinker locks, pageblock order, UFS QoS rewrite | Break KMI or risk CMA |
| The 4.14 `qos:` series, rmqueue_bulk relaxing, DRM cleanup offload | Obsolete or reverted by Sultan |
| GCC LTO, -O3, -mcpu tuning | No published gains; CFI and full LTO pin us to clang r416183b |
| PREEMPT_RT, kabi removal, integrated modules | Too heavy, or no measurable gain |

**Other developers:** arter97's sm8475 (5.10 QTI) adds mostly stable merges plus the kmem_cache pools above.
freak07 (Kirisakura) and Panchajanya mostly carry upstream merges and Sultan's patches; nothing unique. kdrag0n:
the dim-layer revert and freqbench.

**Sources:** [kerneltoast GitHub](https://github.com/kerneltoast), [Pixel 9 XDA thread](https://xdaforums.com/t/kernel-sultan-kernel-for-pixel-9-pro-fold-xl-march-14-2026.4696685/),
[Pixel 4 XDA thread](https://forum.xda-developers.com/t/kernel-11-0-0-sultan-kernel-october-18-2021.4219247/),
[arter97 sm8475](https://github.com/arter97/android_kernel_nothing_sm8475), [kdrag0n proton redbull](https://github.com/kdrag0n/proton_kernel_redbull).

## 6. Qualcomm Pixels, AOSPA, LineageOS QTI trees, Sony ODP, ProtonAOSP, CLO parrot reference

Sources:
- Qualcomm Pixels: `device/google/{redbull,coral,sunfish,barbet}`.
- AOSPA (which carries Qualcomm's CLO parrot configs).
- LineageOS `xiaomi_sm8450-common`, `xiaomi_sm8250-common`, `oneplus_*`.
- `sonyxperiadev`.
- ProtonAOSP.

The CodeLinaro `device/qcom/parrot` tree itself requires a login. QC's parrot values are reachable through AOSPA's
copies.

### 6.1 Bug: swapped CPU clusters in our powerhint.json (action #28)

- **Evidence.** In perf-HAL opcodes, cluster field 0 is the **big** cluster:
  - The CLO parrot `config/parrot/powerhint.xml` labels `0x40800000` as "MIN_FREQ_CLUSTER_BIG_CORE_0" and
    `0x40804100` as "L CPU max freq"
    ([AOSPA copy](https://github.com/AOSPA/android_vendor_qcom-opensource_power/blob/calcite/config/parrot/powerhint.xml)).
  - Stock's 120 fps scroll boost (`stock/dump/vendor/etc/perf/perfboostsconfig.xml:252`, `0x1080`) asks cluster 0
    for **2208** MHz and cluster 1 for 1497. The A55 max is 1958 MHz, so cluster 0 must be the A78s (verified).
- **Cause:** [qcom-perf-parser](https://github.com/ArianK16a/qcom-perf-parser) `main.py:111` maps the opcode
  cluster nibble straight onto `targetconfig.xml` ClustersInfo Id, where 0 is little. LineageOS garnet generated its
  JSON with it ([b3a753c](https://github.com/LineageOS/android_device_xiaomi_garnet/commit/b3a753c9fdb53803128ab393e7742e35a62c9095)),
  and ours is a copy. `performance.md` §1 documented "silver pinned at max" as the intended stock behaviour; it is
  actually this bug.
- **What is wrong** in `evox-cnb/device/xiaomi/dizi/configs/power/powerhint.json` (verified):

  | Hint | What we write | What it should be |
  |---|---|---|
  | INTERACTION | `cpu_min_freq` 0-3 at 1958400 (A55 max), 4-7 at 1497600 | silver 1497600, gold 2208000 (stock), or a trimmed gold value such as 1.8 GHz |
  | INTERACTION | `cpu0/core_ctl/min_cpus` 3 | `cpu4/core_ctl/min_cpus` 3. post_boot disables core_ctl on cpu0, so today only the 2 default golds are guaranteed online during a scroll |
  | CAMERA_STREAMING_* | 1.5 GHz max cap and 960 MHz floor on 4-7 | on the silvers |
  | CAMERA_STREAMING_* | core_ctl 4 on cpu0 | on cpu4 |
  | CAMERA_STREAMING_* | "L CPU hispeed 940 MHz" as `940` into `cpu4/.../hispeed_freq` | `940000` on policy0 |
  | INTERACTION | `sched_busy_hyst_ns` 39 (effectively off) | probably meant as ms by the perf HAL; verify before changing |

- **Supporting evidence:** Google's redbull [c91d24f](https://android.googlesource.com/device/google/redbull/+/c91d24f)
  ("sf mainthread is over 1 vsync" at 1.07 GHz) supports keeping a silver floor around 1.4-1.5 GHz, not at max.
- **Interaction with other items:** this also changes the efficiency picture in #15 ("slim INTERACTION"). Fix the
  clusters first, then trim.
- **Test:**
  - `tools/ui-jank.sh`, `recents-open-jank.sh` and QS, with perfetto per-cluster cpufreq and the gold online count.
  - Screen-on drain.
  - Stock-faithful values first, then trim the gold floor.
- **Upstream:** worth reporting to LineageOS garnet.

### 6.2 LAUNCH: idle limit, UFS clocks, GPU no-nap (action #29)

- **CLO parrot reference** ([AOSPA perfboostsconfig](https://github.com/AOSPA/android_device_qcom_common/blob/calcite/vendor/perf/configs/parrot/perf/perfboostsconfig.xml),
  `0x1081` Type 2, 1.5 s): `cpu_dma_latency`, storage clock, GPU wakeup.
- **Xiaomi stock** `0x1081`: all cores' min freq at max, `cpu_dma_latency`, storage clock, GPU no-nap
  (`0x4281C000`), task boost.
- **Qualcomm Pixels** (redbull/coral/barbet LAUNCH, 5 s): `PMQoSCpuDmaLatency` 61, `UfsClkGateEnable` 0, kgsl
  `force_clk_on`/`force_rail_on` 1, `idle_timer` 10000.
- **Google's measurement:** [redbull ece4027](https://android.googlesource.com/device/google/redbull/+/ece4027),
  "disable UFS gating work in touch and app launch boost". Launch times:

  | App | Before | After |
  |---|---|---|
  | Photos | 224 ms | 177 ms |
  | Camera | 674 ms | 587 ms |
  | Maps | 839 ms | 769 ms |

  [coral f7d9dade](https://android.googlesource.com/device/google/coral/+/f7d9dade) adds a 200 ms UFS hold on
  INTERACTION, with power data.
- **dizi today:** LAUNCH has `sched_boost` 1 and a 1.5 GHz floor. Our `devCpuDmaLatency` node exists but only
  CAMERA_LAUNCH uses it.
- **Feasibility:**
  - The kgsl nodes `force_no_nap`, `force_clk_on`, `force_rail_on` and `idle_timer` exist in stock `msm_kgsl.ko`.
  - UFS `/sys/devices/platform/soc/1d84000.ufshc/clkgate_enable` needs a genfscon label and an allow rule for
    `hal_power_default`.
- **Test:** `tools/app-start.sh` (cold and warm, 9 apps), adding one node at a time.

### 6.3 Restoring the large-composition boost (action #30)

- **What stock does** (perfboostsconfig:667-673, `0x1097`): at 120 Hz, for 5 s, renewed on every GPU-composed cycle,
  it sets gold min 1.5 GHz, GPU `min_pwrlevel` 0, and `0x42C20000` "PID affine", which pins the HWC thread to the
  golds.
- **Cheap route (recommended first):**
  - Add `perf_hint_acq_rel_offload`, `perf_lock_rel_offload`, `perf_hint_offload` and `perf_event` to
    `hardware/qcom-caf/common/libqti-perfd-client/client.c`. That makes `CPUHint::Init` (cpuhint.cpp:57-71)
    succeed, so `HandleLargeCompositionHint` runs.
  - For `0x1097`, call `sched_setaffinity(tid, CPUs 4-6)` on the HWC's own thread. That needs no extra permissions,
    and 4-6 is inside the foreground cpuset. Undo it on release.
  - Optionally fire a libperfmgr boost for gold min 1.5 GHz.
  - Only the HWC tid is affected. AOSP SF can't pass SF's tids, so this is all that stock's mechanism could do on our
    SF anyway.
  - **Test:** `recents-open.sql`, per phase `prepareFrame`/`chooseCompositionStrategy` (today 2.0 ms average,
    8.8 ms peak), and which CPU the HWC thread runs on.
- **Full route:** the stock QTI perf HAL plus QTI power AIDL, as in LineageOS
  [xiaomi_sm8450-common](https://github.com/LineageOS/android_device_xiaomi_sm8450-common) since
  [ee60275](https://github.com/LineageOS/android_device_xiaomi_sm8450-common/commit/ee60275). It uses the same caf
  HWC and AOSP SF; oneplus_sm8550-common does the same.
  - **Gains:** `0x1097`, `0x109B` per-fps WALT (#1) and QC's own launch and scroll tables, with no framework
    changes.
  - **Costs:** libperfmgr ADPF and all our JSON tuning; many blobs, VINTF and sepolicy work. A trimmed
    `perfconfigstore.xml` is needed ([ce9b7bd](https://github.com/LineageOS/android_device_xiaomi_sm8450-common/commit/ce9b7bd)).
  - **Never run both HALs together.** They write the same `msm_performance` nodes.

### 6.4 Smaller items

- **Top-app `cpu.uclamp.latency_sensitive=1` (#31):**
  - Every Qualcomm Pixel keeps top-app `prefer_idle=1` (redbull `init.hardware.rc:526`), and moto sm7435 sets
    latency_sensitive.
  - On WALT, `walt_cfs.c:834` treats it as `need_idle`: prefer an idle CPU, no sync-wakeup packing.
  - Do **not** copy moto's TA `uclamp.min 30`. Any min above 0 changes WALT placement (`adpf.md`).
- **IRQ balancer exclusions (#32):** AOSPA's parrot `msm_irqbalance.conf`
  ([0dd777c2](https://github.com/AOSPA/android_device_qcom_common/commit/0dd777c2): "critical for display
  performance and should not be balanced") uses `IGNORED_IRQ=27,23,38,115,332`. Our built conf has only `27,23,38`.
  Confirm the numbers with `/proc/interrupts`.
- **`vblankoffdelay -1` (#33):** coral [abd0ad81](https://android.googlesource.com/device/google/coral/+/abd0ad81),
  "device can go to idle as soon as possible". Check first that SDE vsync uses drm vblank refcounting on 5.10.
- **Pinner (#11):**
  - LineageOS oneplus_sm8250 also pins `libhwui.so`, the boot oat/vdex and framework-res.
  - kdrag0n unpinned the camera ([c50ce5a](https://github.com/LineageOS/android_device_xiaomi_sm8250-common/commit/c50ce5a),
    up to 160 MiB) and the launcher. Pin the jars, surfaceflinger and SystemUI, not the camera.

### Skip

| Item | Why |
|---|---|
| Pixel DISPLAY_UPDATE_IMMINENT through `sde-crtc-0/early_wakeup` | The node doesn't exist on 5.10, and our panel is video mode |
| schedtune boost, bw_hwmon, mem_latency, L3 devfreq (Qualcomm Pixels) | 4.14/4.19 interfaces. Parrot uses bus_dcvs, and the DDR floor was measured as no effect (§16b) |
| Qualcomm Pixel SF durations | Already measured (9335c2c) |
| AOSPA QTI SF extensions, BoostFramework, QPerformance jars, `advanced_sf_offsets` | Need a CAF framework fork; can't go into EvoX |
| SODP | Moved to a stub QCOM power AIDL ([ce7f6de](https://github.com/sonyxperiadev/device-sony-common/commit/ce7f6de0c388ea76c87e4359ca65b6879ff2226a)); powerhint is an unmodified CLO snapshot |
| oneplus sm8350 "back to schedutil" | Parrot runs WALT |
| ProtonAOSP Vulkan HWUI | Already in (b85c44d) |
| Boot-time IO tuning | We already toggle clkgate during boot |

## How to measure

- **Check the change took effect:**
  - `dumpsys performance_hint` should show SF sessions for #2.
  - `dumpsys android.hardware.power.IPower/default` shows profiles and per-session uclamp.
  - logcat: `Power hint is supported` from SF.
- **What to look at in Perfetto** (`power gfx view sched freq`):

  | Counter or track | For |
  |---|---|
  | `adpf.<id>-min/-target/-actl_last` | #2, #14 |
  | `hboost` counters | #14 |
  | kgsl and DDR frequency tracks | #3, #7 |
  | cpufreq hold after idle, WALT window | #1, #4 |
  | GPU frequency residency (`gpuclk`, `trans_stat`) | #22 |
  | cpuidle `state*/usage` on cpu0-3 at 60 vs 120 Hz | #24 |
  | `sched_pipeline`/`sched_wake_up_idle` via `/proc/sys/walt/sched_task_read_pid` | #13 |

- **A/B runs:** 3-5 per variant at 120 Hz.
  - Scripts: `tools/ui-jank.sh` (QS_ONLY for #2/#3), `tools/recents-jank.sh`, `tools/app-open-jank.sh` (#3, #4, #10),
    `tools/launcher-fling-trace.sh`.
  - Metrics: SF timestats missed and janky frames, hwui janky % p95/p99.
  - For #5, #6 and #18, run under background load (bg-dexopt or a Play update).
- **Power:** `time_in_state` for policy0/4/7, kgsl time at 940 MHz, `current_now` over a 5-min fling loop, plus
  idle and video sanity runs.
- **Suggested order:**
  1. Build with #28 (cluster fix) alone, and measure it against the current build.
  2. Live, with root and no build: #1, then #22, then #23 + #32, one at a time.
  3. Build: #29 (LAUNCH nodes, one at a time).
  4. Build: #3 + #4 + #7 (JSON).
  5. Then #2.
  6. Then #30 (perfd-client stub).
  7. Then #5 + #6 + #18 (under background contention).
  8. Then #13 (SF-only variant first) and #31.
  9. Then #14 and #15.
  10. Then #24 and #25 (kernel module builds), then #27.
  11. #9, #10, #26 and #33 can be tested live at any time.
  - Measure #2 and #13 separately, because they interact.

## Sources

- **Pixel power HAL:** https://android.googlesource.com/platform/hardware/google/pixel/+/refs/heads/android16-qpr2-release/power-libperfmgr/
  (tag `android-16.0.0_r4`, `b38821afd45b`).
- **A17 manifest without the Pixel HAL:** https://android.googlesource.com/platform/manifest/+/refs/tags/android-17.0.0_r1/default.xml
- **Pixel configs:**
  - https://android.googlesource.com/device/google/tangorpro/+/refs/heads/main/powerhint.json
  - https://android.googlesource.com/device/google/caimito/+/refs/heads/main/perf/powerhint-caiman.json
  - https://android.googlesource.com/device/google/zuma (`conf/init.zuma.rc`)
  - https://android.googlesource.com/device/google/redbull (`android14-qpr3-release`)
- **HAL commits:** [921f30dbe6a6](https://android.googlesource.com/platform/hardware/google/pixel/+/921f30dbe6a6d4e938ffca16f064ef4f0d535151)
  (first-frame hints), [71dde5fc5ee8](https://android.googlesource.com/platform/hardware/google/pixel/+/71dde5fc5ee88c453354fec47408d43b9c0d8000),
  [ad2fed38fdb4](https://android.googlesource.com/platform/hardware/google/pixel/+/ad2fed38fdb4ab1717d96ca386c9340623244b7b).
- **Google stopped publishing device trees:** https://9to5google.com/2025/06/12/android-open-source-project-pixel-change/
- **GrapheneOS:** https://github.com/GrapheneOS/adevtool (`vendor-skels/google_devices/`), plus the commit links
  above.
- **Local files:**
  - `evox-cnb/hardware/lineage/interfaces/power-libperfmgr/aidl/`
  - `evox-cnb/frameworks/native/services/surfaceflinger/PowerAdvisor/PowerAdvisor.cpp`
  - `evox-cnb/frameworks/base/libs/hwui/renderthread/HintSessionWrapper.cpp`
  - `evox-cnb/kernel/xiaomi/sm7435/kernel/sched/walt/`
  - `evox-cnb/device/xiaomi/dizi/configs/{power/powerhint.json,task_profiles/task_profiles.json}`

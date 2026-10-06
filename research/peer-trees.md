# Peer device trees: UI-performance changes worth copying to dizi

Survey date: 2026-10-05. Scope: smoothness, jank and app-launch speed only.
Method: shallow clones in /tmp/peer (outside this repo), `git log` plus the diffs of every commit that touches SF, HWC,
power, sched, blur or HWUI, then a check of each prop against our sources (evox `bka`, lineage 23.2, cnb).
"Applies" means the same QTI SDM/HWC stack (sm8450 caf, parrot 5.10), Adreno 7xx and an AOSP-based SF (no QTI SF
extensions).

## TL;DR

- No peer fixes the GPU-composition fallback during transitions directly. Nobody raises `qcom,sde-max-bw-high-kbps`
  on parrot. LineageOS garnet only raised the *low* limit, which the HWC uses only while the camera is on (see item 8).
  Every parrot tree keeps 7.3 GB/s for LPDDR4X. QC lowers these limits on newer SoCs; it does not raise them.
- The biggest finding is a gap in our own ROM, which the peers expose. On stock, the QTI perf HAL moves HWC and SF to
  the gold cores during GPU-composition cycles at 90 Hz or more (`enable_perf_hint_large_comp_cycle`). On dizi that
  hint is a no-op, and the composer stays on the silver cpuset. Peers that dropped perfd move the composer to
  foreground instead (item 1).
- The repeated, cheap, low-risk items are:
  - SF `uclamp.min`;
  - pinning the msm_drm and kgsl IRQs;
  - the cheaper Kawase2 blur and smaller blur radii;
  - per-fps SF durations, which Lineage now converges on;
  - turning `config_deviceSupportsHighPerfTransitions` off on weaker GPUs.
- Much of the crDroid and Pong "tuning" is unmeasured churn or dead props (see "Placebo").

## Ranked: worth trying on dizi

Each item lists: Source, What it changes, Why it might matter for GPU-fallback jank, and How to test. Order: expected
value / cost.

### 1. Run the display composer (and allocator) in the foreground cpuset, not system-background
- **Source:**
  - nabu (Xiaomi Pad 5: 2560x1600 at 120 Hz LCD, LPDDR4X, the closest hardware analogue):
    [1b0d110](https://github.com/dev-harsh1998/android_device_xiaomi_nabu/commit/1b0d110f9df4f769bbaeaa393272fc05e5365f67)
    "Use foreground cpuset/uclamp for glc/hwc. Makes sure rendering has enough capacity."
  - It overrides both services with `task_profiles ProcessCapacityHigh HighPerformance`.
- **dizi today:**
  - `hardware/qcom-caf/sm8450/display/composer/vendor.qti.hardware.display.composer-service.rc` has
    `task_profiles ServiceCapacityLow`, which is cpuset `system-background`, CPUs 0-3 (silver).
  - `init.dizi.rc` says "Setup foreground cpuset for display composer", but it only widens foreground. It does not
    override the composer service.
  - Stock HyperOS also uses `writepid /dev/cpuset/system-background/tasks`, but stock has a compensation that we lack.
- **The missing stock mechanism:**
  - `HWCDisplayBuiltIn::NeedsLargeCompPerfHint()` (hwc_display_builtin.cpp:1311). At 90 Hz or more, with GPU layers in
    mixed mode, it asks the perf HAL to "run SF and HWC on the gold CPU cores".
  - The comment is at :1474. The 120 Hz threshold is 8 layers, or any skip layer.
  - CPUHint needs `perf_hint_acq_rel_offload` from the perf client lib. Our `hardware/qcom-caf/common/libqti-perfd-client`
    stub does not export it, so CPUHint is disabled and `vendor.display.enable_perf_hint_large_comp_cycle=1` does
    nothing.
  - QC's fix "Composer: fix HWC failed to be set affinity to gold cores when large Comp boost"
    ([55bcf5c](https://github.com/LineageOS/android_hardware_qcom_display/commit/55bcf5c51f)) shows that stock relies on
    this boost.
- **Why it might matter:**
  - The GPU-heavy frames (Recents->app, app drawer) are exactly where stock boosts.
  - The composer's validate/strategy (libsdmcore) and present run on A55s at whatever frequency they have.
  - SF blocks on them every frame, which shrinks the GPU's slice of the 8.3 ms budget.
- **Test:**
  - Find the cpuset: `cat /proc/$(pidof vendor.qti.hardware.display.composer-service)/cpuset`.
  - Then add an `override` service block for the composer (`ProcessCapacityHigh HighPerformance`), the same way as the
    audio-hal override in init.dizi.rc.
  - Compare the display jank % for Recents->app and the drawer, and HWC `presentDisplay`/`validateDisplay` slices in
    perfetto.
  - Variant: top-app cpuset (0-7), so the composer can also use CPU 7.

### 2. SurfaceFlinger `ro.surface_flinger.uclamp.min`
- **Source:**
  - crDroid Spacewar
    [1c613e9](https://github.com/crdroidandroid/android_device_nothing_Spacewar/commit/1c613e9f83a07e5a7d244622c375b91c1b76ea13)
    sets 205 (20%): "improved rendering stability".
  - Pong [47362f3](https://github.com/Pong-Development/device_nothing_Pong/commit/47362f3465b7795c7f3e0669a25cc4a7aab62501)
    lowered it to 165.
- **What it changes:** a read-only AOSP prop (SurfaceFlinger.cpp:7898). SF sets `sched_util_min` on its threads, so WALT
  picks a higher OPP and a bigger core for SF's main and RenderEngine threads.
- **Why it might matter:**
  - Our trace showed about 3 ms of CPU-side drawLayers plus a 3.9 ms fence wait per client-composited frame.
  - The CPU half is uclamp-sensitive. The fence-wait half is not.
  - It complements ADPF (`debug.sf.enable_adpf_cpu_hint`, already in research/adpf.md).
- **Related:**
  - Sony pdx257 (parrot)
    [235738a](https://github.com/LineageOS/android_device_sony_pdx257/commit/235738ac770a37d16db128efd8608c028d53c026)
    "Allow surfaceflinger to use the big cluster".
  - That vendor task_profiles put SF in system-background (CPUs 0-3). Perfetto showed "scrolling through recent apps
    with blur ... little cluster very busy ... big idle". They moved SF to a 4-7 cpuset.
  - On dizi, AOSP `SFMainPolicy`/`SFRenderEnginePolicy` use foreground (0-6). Run
    `cat /proc/$(pidof surfaceflinger)/task/*/cpuset | sort | uniq -c` to confirm that no vendor task_profiles override
    them.
- **Test:** add `ro.surface_flinger.uclamp.min=205` to the vendor/product prop (it needs a reboot), then run the same
  A/B as item 1.

### 3. Pin the `msm_drm` and `kgsl_3d0_irq` IRQs and keep irqbalance off them
- **Source:**
  - LineageOS Spacewar
    [51daf37](https://github.com/LineageOS/android_device_nothing_Spacewar/commit/51daf370c23ef582c68aebcfd5cd055476b11b5b)
    (Jake Weinstein): "critical for display performance and should not be balanced in order to improve latency and
    responsiveness".
    - It adds both IRQs to `IGNORED_IRQ` in `msm_irqbalance.conf` (blob fixup).
    - It sets `smp_affinity_list` to CPU 2 for drm and CPU 1 for kgsl.
  - nabu [6b006ff](https://github.com/dev-harsh1998/android_device_xiaomi_nabu/commit/6b006ffaaf65ecc4a7820c56208d187bc4974ab5)
    does the same by IRQ *name*. That is robust to kernel IRQ renumbering.
  - Pong carries the same lines.
- **dizi today:** the stock `msm_irqbalance.conf` only ignores 27, 23 and 38, so `msm_drm` (pp-done/vsync) and
  `kgsl_3d0_irq` (GPU retire, which signals the fences SF waits on) get migrated.
- **Why it might matter:**
  - Fence-signal latency is part of the 3.9 ms GPU fence wait, and vsync/retire IRQ jitter causes missed latches.
  - It cannot reduce GPU work.
- **Test:** copy the nabu script (`init.mi_perf.sh`), plus the extract-files fixup that adds both IRQ numbers to
  `IGNORED_IRQ`. Then check `/proc/interrupts`. Cost is close to zero.

### 4. Cheaper blur: Kawase dual-filter, and smaller radii
- **Source:**
  - crDroid Spacewar
    [d869e9e](https://github.com/crdroidandroid/android_device_nothing_Spacewar/commit/d869e9e1b6047fcbeeb5e3629f51fa0fa6fad732)
    sets `debug.renderengine.blur_algorithm=kawase2`.
  - The radius overlays are in LineageOS garnet
    [9b2206b](https://github.com/LineageOS/android_device_xiaomi_garnet/commit/9b2206bdf3040ab9a161e5a5421dc4defa4428ba),
    Spacewar [151d6ac](https://github.com/LineageOS/android_device_nothing_Spacewar/commit/151d6acdaefb1638964517a39657e328e6181c21)
    and pipa (PA) bb973e8. The values:
    - Launcher3 `max_depth_blur_radius=11`, `max_depth_blur_radius_enhanced=15dp`;
    - SystemUI `max_shade_window_blur_radius=17dp`.
  - asteroids (SM7635) [6f981a5](https://github.com/NullDebris/android_device_nothing_asteroids/commit/6f981a5e8c80698f7dd41359020276ca9f2e8b4d)
    set `ro.launcher.blur.appLaunch=0`: "launch transitions take a performance hit ... low-end gpu".
- **What it changes:**
  - SF reads the blur prop at RenderEngine creation (SurfaceFlinger.cpp:921-944). `kawase2` selects
    `KawaseDualFilter`; the default is plain Kawase unless the aconfig flag `window_blur_kawase2` is on.
  - Dual-filter blur samples at a lower resolution with fewer passes.
  - Blur cost grows with the radius.
- **Why it might matter:** we turned the blurs off as the measured win. This could let blur come back as an option at a
  smaller GPU cost. It does not address the Recents fallback, which persists with blur off.
- **Test:** `setprop debug.renderengine.blur_algorithm kawase2; stop; start`, then the blur-on toggle matrix from
  performance-report.md.

### 5. `config_deviceSupportsHighPerfTransitions=false` (framework overlay)
- **Source:**
  - nabu [5186713](https://github.com/dev-harsh1998/android_device_xiaomi_nabu/commit/51867131a03856c82af69e0dbd34e0607c59df60):
    "860 isn't as much powerful ... graphics blob stack is old".
  - asteroids [db37d35](https://github.com/NullDebris/android_device_nothing_asteroids/commit/db37d3512d535a61ce6f8c1267af711be3592f45).
- **What it changes:**
  - It is on by default (config.xml:7566, "lower-end devices may want to disable").
  - When on, `DisplayContent.enableHighPerfTransition()` opens a `SystemPerformanceHinter` `HINT_SF` session for every
    shell transition.
  - That session puts SF into early-wakeup scheduling (the early/earlyGl work durations), plus an SF CPU load-up hint.
- **Why it might matter:**
  - On dizi, early equals late (16.67 ms everywhere), so the vsync effect is nil. Only the hint side remains.
  - Peers report it smoother off, but give no numbers.
  - It is cheap to A/B in both directions, and it interacts with item 6. If per-fps durations are adopted, early
    becomes different from late.
- **Test:** an RRO in the framework-res overlay, then Recents->app and icon->app (display timeline).

### 6. Per-refresh-rate SF work durations (Lineage and cnb only)
- **Source:**
  - LineageOS garnet (our parent device, same SoC):
    - [6499a1d](https://github.com/LineageOS/android_device_xiaomi_garnet/commit/6499a1d513b2d11f6c5e6a53367d2d93407ec2d6)
      "base durations from stock": `sfDuration = period - sfPhase; appDuration = period + sfPhase - appPhase`;
    - [5b3cb51](https://github.com/LineageOS/android_device_xiaomi_garnet/commit/5b3cb512c2f07f416eaa461e2ade28cead2e2760)
      "per fps durations";
    - the earlier try, [ee8c061](https://github.com/LineageOS/android_device_xiaomi_garnet/commit/ee8c061952354a8fffdccee738392f826b58a3ad)
      (12.3 ms, then reverted), has a useful table: stock = 148% of a frame at 120 Hz and 94% at 60 Hz.
  - The same is in Sony pdx257 [4206baa](https://github.com/LineageOS/android_device_sony_pdx257/commit/4206baa052d65737830e5d38af9728f7e8ca2389)
    and Pong [1f05e49](https://github.com/Pong-Development/device_nothing_Pong/commit/1f05e49d34601122b4c95203fc20667bf7d9f371).
  - The values: 120 Hz sf=12333333 app=11666666; 90 Hz 16111111/16222222; 60 Hz 15666666/16666666; for all three modes
    (early, earlyGl, late).
- **Framework:**
  - `debug.sf.{early,earlyGl,late}.{sf,app}.duration.<fps>` is LineageOS frameworks/native
    [9568531](https://github.com/LineageOS/android_frameworks_native/commit/9568531f9be7ae65f260699811f32ec4e461de6e).
  - It is present in our lineage and evox-cnb trees, but **not in EvoX bka** (VsyncConfiguration.cpp has no `.fps`
    lookup).
- **Why it might matter:**
  - dizi uses 16.67/16.67 at every rate. At 120 Hz that already gives SF two vsyncs for a GPU-composited frame, which is
    the most forgiving setting for GPU-bound composition.
  - So expect latency changes, not fewer GPU misses. Our earlier offset sweeps agree.
  - The value is matching stock at 60 and 90 Hz (idle and video) and having a distinct early set for item 5.
  - Low priority.

### 7. SDE bandwidth-vote fix (only with the source-built `msm_drm.ko`, stage B)
- **Source:** QC patch "techpack: disp: sde: fix vote bandwidth failed issues", carried in Evolution-X
  [kernel_nothing_sm7325 9e02ea7](https://github.com/Evolution-X-Devices/kernel_nothing_sm7325/commit/9e02ea7520).
- **What it changes:**
  - It removes the `cstate->bw_control = false` reset in `_sde_crtc_reset`. Otherwise, if userspace never changes its
    vote, the driver drops the vote and RSC votes max DDR.
  - It also raises `IDLE_POWERCOLLAPSE_DURATION` from 58 ms to 300 ms.
- **dizi:** both old lines are present in kernel/out-display/src-fix (sde_crtc.c:4478, sde_encoder.h:52).
- **Why it might matter:** it is a correctness and power fix for the DDR/MDP vote, with a possible effect on the first
  frames after idle. It does not change the HWC strategy. Medium-low.

### 8. Kernel SDE limits: what the peers did (and did not do)
- LineageOS garnet DT [87e4d03](https://github.com/LineageOS/android_kernel_xiaomi_sm7435-devicetrees/commit/87e4d0352d9b2deddcb94a954fb364454a03e783)
  "Limit sde max to 4.9": it changes only `qcom,sde-max-bw-low-kbps`, from LP5 4.6 and LP4X 4.8 to 4.9 GB/s.
- SDM maps low to `kBwVFEOn`, the camera/video-front-end-on mode, and high to `kBwVFEOff`
  (sdm/libs/core/drm/hw_info_drm.cpp:213-221). So that commit has **no effect on normal UI** composition.
- Motorola sm7435 keeps the CLO values (low 4.6/4.8, high 8.5 for LP5 and 7.3 for LP4X).
- No parrot tree raises the high limit. QC itself *lowered* it on sun
  ([413d494](https://github.com/LineageOS/android_kernel_qcom_sm8750-devicetrees/commit/413d494ab8), 28.5 to
  24.2 GB/s). These numbers are sized to the DDR/NoC, and exceeding them risks underflow.
- Context: garnet (LPDDR4X) has the same 7.3 GB/s and the same 3-SSPP DPU, but 20% fewer pixels (2712x1220) than dizi
  (2560x1600). That fits dizi falling back sooner in identical transitions.
- If you want a direct test of the bandwidth hypothesis:
  - a temporary dtbo with high = 8.5 GB/s, read back via `/sys/kernel/debug/dri/0/debug/core_perf`;
  - plus the SF layer dump, to see whether the transition layers become DEVICE.
  - This is an experiment only. Do not ship it without an underflow soak (no peer evidence).
- Per-pipe limits are 3.9/4.1 GB/s (`qcom,sde-max-per-pipe-bw-kbps`). Only one VIG pipe has a scaler.

## Per-tree notes

### Same platform (parrot: SM7435/SM6450)

| Tree | Branch / activity | Relevant content |
|---|---|---|
| [LineageOS garnet](https://github.com/LineageOS/android_device_xiaomi_garnet) | lineage-23.2, 2026-09 | Per-fps SF durations (item 6); blur radius RRO (item 4); powerhint generated from stock perfboostsconfig with [qcom-perf-parser](https://github.com/ArianK16a/qcom-perf-parser) ([b3a753c](https://github.com/LineageOS/android_device_xiaomi_garnet/commit/b3a753c9fdb53803128ab393e7742e35a62c9095)); display blobs from ingot UKQ1.240227.165 (as in display-composer.md); `game_default_frame_rate_override=120`. Props are otherwise identical to ours (our fork). |
| [LineageOS motorola sm7435-common](https://github.com/LineageOS/android_device_motorola_sm7435-common) (avatrn = edge 2024, genevn = g stylus 5G 2023) | lineage-23.2, 2026-09 | Powerhint ported from coral/lahaina. INTERACTION: no CPU freq boost ([5be0ef8](https://github.com/LineageOS/android_device_motorola_sm7435-common/commit/5be0ef8020840304f90a5c46be97e804393823db)); TA uclamp.min 30 and latency_sensitive; DDR `boost_freq` 1555 MHz; L3 floor. LAUNCH: GPU `force_clk_on`/`force_rail_on`, `idle_timer` 10000 for 3 s. EXPENSIVE_RENDERING: GPU min 500 MHz. Props: `enable_gl_backpressure=1`; durations 15.67/13.67; `set_idle_timer_ms=500`; `enable_frame_rate_override=true`; `debug.sf.auto_latch_unsignaled=0` ([619535e](https://github.com/LineageOS/android_device_motorola_sm7435-common/commit/619535e53d251d521322a6606fd83203678b32e0)); dalvik heap "same as holi" (256m/8m/0.75, [8389cff](https://github.com/LineageOS/android_device_motorola_sm7435-common/commit/8389cffe675f01cf764ca675d069ddf941b00a1c)). No measurements in any commit. |
| [LineageOS sony pdx257](https://github.com/LineageOS/android_device_sony_pdx257) (Xperia 10 VII, `TARGET_BOARD_PLATFORM := parrot`) | lineage-23.2, 2026-08 | SF big-cluster cpuset with a perfetto rationale (item 2); per-fps durations; blur off by default. Uses `hardware/qcom-caf/sm8450-6.6` (kernel 6.6 display stack, snapalloc), so HWC behaviour is **not** comparable. |
| LineageOS xiaomi/motorola sm7435 kernels and modules | lineage-23.2 | No device-specific perf patches: CLO tag merges plus ACK LTS. Display-drivers carry only Xiaomi panel/mi_disp imports, plus "Allow video mode panels to reach LP2" (power). KGSL changes are CLO AB-vote fixes. |
| Other dizi/ruan trees: [M0Rf30](https://github.com/M0Rf30/android_device_xiaomi_dizi), [Efeisot](https://github.com/Efeisot/android_device_xiaomi_dizi), [noble6 ruan](https://github.com/noble6/android_device_xiaomi_ruan) | 2025-01 to 2026-09 | Efeisot copies the stock props (QTI-SF-only props included, see Placebo). M0Rf30 and noble6 use odd durations (late sf 10.5, app 20.5; earlyGl app 21 ms) with no rationale. Nothing to adopt. |

### Nothing Phone

| Tree | Relevant content |
|---|---|
| [LineageOS Spacewar](https://github.com/LineageOS/android_device_nothing_Spacewar) (SM7325) | IRQ pinning (item 3). `enable_gl_backpressure=0` by a QC engineer ([786077b](https://github.com/LineageOS/android_device_nothing_Spacewar/commit/786077b70a851e114c39c88f5e569ac3a29b6c9b), no rationale; we measured backpressure as neutral). `disable_client_composition_cache=0`, "causes visible jank" ([29614c0](https://github.com/LineageOS/android_device_nothing_Spacewar/commit/29614c0ca4263963e90ad8e74cba9e628511af58)). Idle/touch timers 4000 ms because of gamma shift on RR switches ([af5c67e](https://github.com/LineageOS/android_device_nothing_Spacewar/commit/af5c67ecb884b5751e95c4ba6caf81b22b8dae86); that is an OLED problem, not ours). |
| [crDroid Spacewar](https://github.com/crdroidandroid/android_device_nothing_Spacewar) | `uclamp.min=205` (item 2) and kawase2 (item 4). Otherwise heavy prop churn: backpressure off, then on again; `predict_hwc_composition_strategy=1` (we measured it worse); `render_ahead` 30 -> 3 -> 1; graphite added and then "nuked". Treat it as anecdote. |
| [Pong-Development](https://github.com/Pong-Development/device_nothing_Pong) / [EvoX Pong](https://github.com/Evolution-X-Devices/device_nothing_Pong) (SM8475) | Per-fps durations, after a detour from phase offsets to durations and then 15.6 ms. SF uclamp.min. IRQ pinning. `sched_util_clamp_min_rt_default=128` with top-app uclamp.min 15 ([076eba2](https://github.com/Pong-Development/device_nothing_Pong/commit/076eba287be91a14d9113eec974554f4c8365584)). Cpusets with top-app 0-7. About 30 powerhint commits by one author, with no numbers. |
| [NullDebris asteroids](https://github.com/NullDebris/android_device_nothing_asteroids) (Phone 3a, SM7635) | HighPerfTransitions off; app-launch blur off, later reverted ([c4ab0bb](https://github.com/NullDebris/android_device_nothing_asteroids/commit/c4ab0bb2cb410abf4fa62e571c7cba74493dcaf2)). HWUI Vulkan: "fixes some skipped frames ... in Settings" ([b31bc78](https://github.com/NullDebris/android_device_nothing_asteroids/commit/b31bc786942be46481036bd5400f02419cb79a75); see vulkan-adreno710.md, measured neutral on dizi). The prebuilt display HAL "serious jank with OSS stack" ([e4be8d5](https://github.com/NullDebris/android_device_nothing_asteroids/commit/e4be8d51aafb4c622eea07bb6a6d649c50300800)) was reverted later; it matches our hybrid-blob finding. `frame_rate_category_high=120` soong config ([5b6ee56](https://github.com/NullDebris/android_device_nothing_asteroids/commit/5b6ee5611704ecdf8d28dae264c9831714da0aca)) applies only to HWC3/ARR stacks. |
| Galaxian (3a Pro) trees | Personal repos only, no perf content found. |

### Tablets

| Tree | Relevant content |
|---|---|
| [nabu](https://github.com/dev-harsh1998/android_device_xiaomi_nabu) (Pad 5, SM8150, 2560x1600 at 120 Hz LCD, LPDDR4X) | The closest analogue. HWC/allocator in foreground (item 1); IRQ pinning by name (item 3); HighPerfTransitions off (item 5); `enable_egl_image_tracker=0` (we already set it); `debug.sf.enable_adpf_cpu_hint=true` ([95f93ec](https://github.com/dev-harsh1998/android_device_xiaomi_nabu/commit/95f93ec1166dadbea9305d8bc25d41461fc2033e), mirrors Pixel); `vendor.display.disable_metadata_dynamic_fps=1`; blur off by default. Older SDM (msmnile), so its HWC props differ. |
| [LineageOS pipa](https://github.com/LineageOS/android_device_xiaomi_pipa) / [PA pipa](https://github.com/YumeMichi/device_xiaomi_pipa) (Pad 6, SM8250, 2880x1800 at 144 Hz) | Stock timers (`set_idle_timer_ms=1100`, the same as ours). `disable_idle_time_video/hdr`. PA: a power-HAL extension that boosts the GPU to pwrlevel 0 for INTERACTION ([3418f5b](https://github.com/YumeMichi/device_xiaomi_pipa/commit/3418f5bb711a0af45a23ccc010174af12ac7b533)), only when blur is enabled ([ebe189c](https://github.com/YumeMichi/device_xiaomi_pipa/commit/ebe189c4121f9fbe122ae43634772bccdcae106b)); our INTERACTION floor is already 600 MHz, and 940 MHz was measured as not limiting. "Disable smooth motion" ([0ec8a3a](https://github.com/YumeMichi/device_xiaomi_pipa/commit/0ec8a3a7673e790d8c9a8daa9cd1b932bef76561)). |
| [sheng](https://github.com/lolipuru/android_device_xiaomi_sheng) (Pad 6S Pro) | Early bring-up (touch/pen hacks). Nothing for performance. |
| OnePlus Pad (caihong) | MediaTek, out of scope. Not checked. |

## Placebo, dead or not applicable here

All of these were checked against our sources.

**QTI-SurfaceFlinger-only props.** Our SF is AOSP-based: no `QtiExtension`/DisplayExtn in lineage, evox or cnb
frameworks/native. These do nothing on our ROMs (Moto and Sony set them by cargo):
- `debug.sf.enable_advanced_sf_phase_offset`;
- `vendor.display.enable_early_wakeup`;
- `vendor.display.disable_dynamic_sf_idle`;
- `vendor.display.use_smooth_motion`;
- `vendor.display.use_layer_ext`;
- `vendor.display.enable_display_extensions` (SF side);
- also, `debug.sf.high_fps_*_phase_offset_ns` is read only when `use_phase_offsets_as_durations=0`.

**Large-composition hint.** `vendor.display.enable_perf_hint_large_comp_cycle=1` is dead with the LineageOS
libqti-perfd-client stub, which lacks the `*_offload` symbols (item 1).

**`vendor.perf.framepacing.enable=1`** (asteroids [6390997](https://github.com/NullDebris/android_device_nothing_asteroids/commit/6390997)):
it needs QTI perfd. The commit text is generic marketing.

**HWUI props:**
- `ro.hwui.render_ahead` is declared in HWUIProperties.sysprop but has no reader in libs/hwui. The values 30/24/3/1
  seen in crDroid and nabu are all no-ops.
- `ro.hwui.*_cache_size` and `texture_cache_flushrate` (stock even ships them) are dead since the Skia pipeline.
- `debug.hwui.use_triple_buffering` has no reader.
- `renderthread.skia.reduceopstasksplitting` is real (Properties.h), but nobody measured it.

**`ro.sf.blurs_are_expensive=1`** (nabu [0b1edf1](https://github.com/dev-harsh1998/android_device_xiaomi_nabu/commit/0b1edf10e1659c1b9073d7921cb143cb89455032)):
- It has no reader in A16.
- CompositionEngine already raises EXPENSIVE_RENDERING whenever a blur layer is client-composited (Output.cpp:1446-1456).
- dizi maps that hint to a 940 MHz GPU floor.

**`ro.config.avoid_gfx_accel=true`** (crDroid): a real prop meant for low-RAM devices. It makes some system windows
software-rendered. Do not copy it.

**Flip-flopped props:**
- `debug.sf.disable_client_composition_cache`: the Lineage trees flip it both ways (Spacewar 0 "visible jank", sm8250 1
  and later dropped). We measured no gain (performance-report.md).
- `debug.sf.latch_unsignaled`: AOSP removed it
  ([1fd9bfca](https://android.googlesource.com/platform/frameworks/native/+/1fd9bfca9d86a3b0d0ff46596ec948b147f44619)),
  so the peers drop it. We measured no gain with `=1`.
- `debug.sf.enable_gl_backpressure` / `disable_backpressure`: set both ways by peers. We measured it neutral.

**`debug.sf.predict_hwc_composition_strategy=1`** (crDroid): we measured it worse.

**Powerhint micro-tuning without traces** (the Pong and crDroid series: launch 5 s -> 3 s -> 1.2 s, TA uclamp 50 -> 30
-> 15, etc.): no evidence either way. Our GPU and DDR floor tests already show that the clocks are not the limit.

**`HWUI_COMPILE_FOR_PERF`** (asteroids 544e486): a ROM-specific build flag. No measurement given.

**Refresh-rate timers** (Spacewar 4000 ms, Moto 500 ms, pipa 1100 ms): these trade OLED gamma shift against power. On
our LCD they are not a smoothness lever. We keep 1100 ms, as stock does.

## Suggested order of A/B runs

Use the existing tools/ui-jank.sh and perfetto workflow. Per step: 3 runs of Recents->app and the drawer, plus
icon->app, on the display timeline.
1. Composer in the foreground (item 1). Optionally add the allocator. Then try the top-app variant.
2. Add `ro.surface_flinger.uclamp.min=205` (item 2).
3. Add the IRQ pinning (item 3).
4. Set `config_deviceSupportsHighPerfTransitions=false` and compare against the default (item 5).
5. Run kawase2 plus the reduced radii with blur on, to see whether the blur toggles can default to on (item 4).
6. Optional experiment: the bandwidth-hypothesis dtbo (item 8). Look at the layer composition types first, the jank
   percentage second.

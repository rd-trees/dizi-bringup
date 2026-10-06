# Vulkan RenderEngine / HWUI on Adreno 710 (dizi, SM7435 "parrot")

Research date: 2026-09-27. Web + local only, no device access. Background: switching SurfaceFlinger
RenderEngine to Vulkan (`debug.renderengine.backend=skiavkthreaded`) made QS-pulldown jank go from
6% to 32-36% (p50 9 ms -> 32-34 ms), see performance.md section 11.

## TL;DR: top 3 leads

1. **GPU queue priority is lost when RE runs on Vulkan (most likely cause, cheap to test).**
   With GL, RE asks for `EGL_NV_context_priority_realtime`. The Adreno EGL supports it, so SF composites
   at realtime GPU priority, and SystemUI then raises its own HWUI context to HIGH
   (`SystemUIApplicationImpl`: "Found SurfaceFlinger's GPU Priority"). With Vulkan, RE only raises the
   queue priority above MEDIUM if `vkGetPhysicalDeviceQueueFamilyProperties2` reports priorities
   through `VkQueueFamilyGlobalPriorityPropertiesEXT`. That is the `VK_EXT/KHR_global_priority_query`
   path. Our stock `vulkan.adreno.so` only has `VK_EXT_global_priority`, with no `_query` or
   `KHR_global_priority` string. So RE probably ends up at **MEDIUM**, `getGpuContextPriority()`
   returns 0, and SystemUI stays at MEDIUM too. SF's composition then queues behind app, wallpaper and
   launcher GPU work on the same kgsl ringbuffer. That fits a p50 of about 4 vsyncs.
   Fix: a small frameworks/native patch in `VulkanInterface::init()` (see test B1).
2. **Try Graphite RE, and apply the priority fix before judging Vulkan.** `debug.renderengine.backend`
   overrides the backend choice and always picks **Ganesh**. Graphite is only chosen when that prop is
   unset or unrecognised and `debug.renderengine.graphite=true` is set. The FlagManager sysprop
   override works on userdebug, and `GraphiteVkRenderEngine` is compiled into librenderengine
   unconditionally. Pixel 9 (zumapro) ships `debug.renderengine.graphite_preview_optin=true`.
   Graphite uses the same `VulkanInterface`, so it has the same priority problem.
3. **A slightly newer parrot driver exists, and upstream Mesa now supports A710.**
   - LineageOS garnet (Redmi Note 13 Pro 5G / POCO X6, same SoC) ships
     **V@0615.99 (GIT@35ebe05c3f, 07/25/25, compiler EV031.36.08.34)** from garnet OS3.0.5.0.WNRMIXM.
     Ours is V@0615.98 (05/02/25, EV031.36.08.33). It targets the same SoC and the same 5.10 parrot
     kgsl, so it's a low-risk drop-in, but expect a small change.
   - Mesa **turnip gained official Adreno 710/720 support on 2026-09-23** (MR !44466, commit
     4db0b15c). Turnip on kgsl is usable per app today. Using it as the system driver (for SF) is
     experimental: it needs UBWC-aware gralloc, and on kgsl it only exposes MEDIUM priority.

---

## 1. Community driver sources for Adreno 7xx

### 1.1 What every parrot device ships (all on the Qualcomm "0615" branch)

The vendor partition on every parrot device is frozen at Android 12 (`ro.vendor.build.version.release=12`,
SKQ1.*). Vendor GPU drivers stay on the **0615** branch (the Android-S-era branch). Versions pulled
from firmware dumps:

| Device / firmware | Driver build | Date | Compiler |
|---|---|---|---|
| Honor "parrot" (magic, A14), dumps.tadiphone.dev/dumps/honor/parrot | d3ad32c206 | 08/06/24 | EV031.36.08.30 |
| Moto Edge 50 Fusion `cusco` A15 V1UU35H.15-15-4 | d3ad32c206 | 08/06/24 | EV031.36.08.30 |
| dizi OS2.0.3.0.VNSEUXM (A15) | ab52495952 | 11/26/24 | EV031.36.08.30 |
| **dizi OS3.0.303.0.WNSEUXM (A16, ours)** | 0c393b63cf, **V@0615.98** | 05/02/25 | EV031.36.08.33 |
| garnet CN OS3.0.2.0.WNRCNXM (A16) | 35ebe05c3f | 07/25/25 | EV031.36.08.34 |
| **garnet global OS3.0.5.0.WNRMIXM** (LineageOS 23.2 / crDroid / EvoX garnet) | 35ebe05c3f, **V@0615.99** | 07/25/25 | EV031.36.08.34 |

The garnet blobs are available in
[TheMuppets/proprietary_vendor_xiaomi_garnet](https://github.com/TheMuppets/proprietary_vendor_xiaomi_garnet)
(branch lineage-23.2, commit "garnet: Update from OS3.0.5.0.WNRMIXM", 2026-05-29).

Device trees checked (none sets `debug.renderengine.backend`, `debug.hwui.renderer`,
`ro.hwui.use_vulkan` or Graphite props, and none pins GPU blobs from another source). All declare
`android.hardware.vulkan.version-1_1` + `level-1`, and set only `ro.hardware.egl/vulkan=adreno`:
- [LineageOS/android_device_xiaomi_garnet](https://github.com/LineageOS/android_device_xiaomi_garnet) (lineage-23.2). Pins display HWC/SDM/HDR/PP from OnePlus `ingot-user 14 UKQ1.240227.165`. Worth noting for the HWC-present-time work, not for GPU.
- [crdroidandroid/android_device_xiaomi_garnet](https://github.com/crdroidandroid/android_device_xiaomi_garnet) (16.0, 2026-09-15), [Evolution-X-Devices/device_xiaomi_garnet](https://github.com/Evolution-X-Devices/device_xiaomi_garnet) (bka, 2026-09-22): same.
- dizi: [M0Rf30/android_device_xiaomi_dizi](https://github.com/M0Rf30/android_device_xiaomi_dizi) (lineage-23.0, blobs from OS2.0.207.0 A15), [Efeisot/android_device_xiaomi_dizi](https://github.com/Efeisot/android_device_xiaomi_dizi) (15.0).
- ruan (Redmi Pad Pro 5G): [noble6/android_device_xiaomi_ruan](https://github.com/noble6/android_device_xiaomi_ruan) (OS2.0.208.0 blobs).
- Motorola cusco/cuscoi: [Motorola-Parrot](https://github.com/Motorola-Parrot/android_device_motorola_cusco), [Moto-SM7435-Devs](https://github.com/Moto-SM7435-Devs/android_device_motorola_cuscoi).

Stock dizi ships `product/app/com.xiaomi.ugd` (Xiaomi "updatable GPU driver" stub, v1.2.2, no
driver libs inside) but sets no `ro.gfx.driver.*`. Xiaomi's 8-series phones do set it, for example
`ro.gfx.driver.1=com.qualcomm.qti.gpudrivers.sun.api35` (Xiaomi 15 "dada") and `...canoe.api36`
(pudding). No `gpudrivers.parrot` package was found. Updatable drivers only apply to opted-in apps,
**never to SurfaceFlinger**.

### 1.2 Newer Qualcomm driver branches (other SoCs)

These are extracted from other devices, mostly for emulators through AdrenoTools:
- [K11MCH1/AdrenoToolsDrivers](https://github.com/K11MCH1/AdrenoToolsDrivers/releases): v819.2
  (Quest 3, 2025-08-13), v842.6 (8 Elite Gen 5, 2025-09-30), v849 (iQoo 15, 2025-10-26), v837
  (Quest 3, Vulkan 1.3.295, 2026-01-14), v840 (Meta Ray-Ban, 2026-01-14). All marked "for a7xx.
  Maybe a6xx". Also turnip builds, including a710/a720 notes ("a710 and 720 can use regular or
  GMEM").
- [zoerakk/qualcomm-adreno-driver](https://github.com/zoerakk/qualcomm-adreno-driver/releases): 800.26-800.51, 842.6, 842.8 (Elite / 8 Gen 4, 2025).
- [StevenMXZ/Adreno-Tools-Drivers](https://github.com/StevenMXZ/Adreno-Tools-Drivers/releases), [whitebelyash/AdrenoToolsDrivers](https://github.com/whitebelyash/AdrenoToolsDrivers/releases) (turnip, gen8 branch, tu_v32 2026-09-19).
- System-wide Magisk modules: [tryigit/AdrenoGpuDriver](https://github.com/tryigit/AdrenoGpuDriver) (template);
  [XDA "Snapdragon Driver Update Module"](https://xdaforums.com/t/snapdragon-driver-update-module.4685775/);
  [XDA "Adreno 650 819v2 & Adreno 730 v837 Magisk module"](https://xdaforums.com/t/adreno-650-819v2-adreno-730-version-837-magisk-driver-update-module-cn-row-aosp-compatible.4739332/).
  Users report v819.1 running system-wide on A650 and **A730 (taro, same a7xx gen1 family and
  msm-5.10 kgsl as parrot)** with stock kernels. Camera encode/decode still worked. The "805 won't
  run" claims are about 32-bit kernels.
- I found **no Adreno 710-specific system driver module or ROM** shipping anything newer than 0615.
  No sm7435 ROM enables Vulkan RE or HWUI.

**kgsl ABI constraints.** The kgsl UAPI is additive, and newer userspace probes features through
`IOCTL_KGSL_DEVICE_GETPROPERTY`. So 8xx-branch drivers often run on older 5.10 kgsl. The real
risk is whether the driver's chip table (libgsl / compiler) includes **gen7_3_0 / chip id
0x07010000**. Also, the Quest/Elite builds are tuned for other SoCs. Treat anything newer than
0615.99 as a per-app experiment first (section 5, A5), not a vendor swap.

## 2. Mesa turnip on Adreno 710

- **Upstream:** [MR !44466 "freedreno: Add support for Adreno 710 and 720"](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/44466),
  merged 2026-09-23 (commit 4db0b15c, Mesa 26.3-devel). It adds FD710 with chip_id
  `0x07010000` / `0xffff07010000`, a7xx_gen1, 512 KiB GMEM, 1 CCU, hbb 15, and raw magic regs from
  blob `.rd` captures. The notes say "gen7_3_0, LineageOS parrot/SM7435". Before this, A710 support
  came only from out-of-tree patches:
  [Vauzi-17/710](https://github.com/Vauzi-17/710) (v4.0 2026-09-27, Mesa 26.3-devel, Vulkan 1.4.363),
  [The412Banner/Banners-Turnip](https://github.com/The412Banner/Banners-Turnip) and K11MCH1.
- **Known issues:** GMEM mode is prone to artifacts on A710, so builds recommend `TU_DEBUG=sysmem`.
  num_ccu was wrong until recently (3 -> 1). **UBWC detection with newer QTI gralloc** was broken
  until the `u_gralloc: always use UBWC detection path` patch (Vauzi v3.9/4.0, from whitebelyash).
  Mesa's `u_gralloc_qcom` only supports the legacy gralloc1 perform() path. The imapper4/5 paths
  rely on the standard metadata. The "One UI bug" workaround is
  `FD_DEV_FEATURES=enable_tp_ubwc_flag_hint=1`.
- **As a system Vulkan driver:** technically possible. Mesa docs describe building with
  `-Dfreedreno-kmds=kgsl`, renaming the SONAME to `vulkan.<ro.hardware.vulkan>.so` and pushing it to
  `/vendor/lib64/hw/`. On a ROM we'd set `ro.hardware.vulkan=freedreno` or similar and ship
  `vulkan.freedreno.so`. Downsides for RE:
  - `tu_knl_kgsl.cc` sets `submitqueue_priority_count = 1`, so on kgsl only **MEDIUM** is
    exposed. That's the same priority loss as lead 1, and it is not fixable without kgsl submitqueue
    priority plumbing.
  - It has seen little testing as an Android compositor. Protected content, AHB YUV and
    external-format paths, and camera/codec interop are unknowns.
  - The GL side stays on the Adreno blob, so there are two drivers sharing kgsl.
  Realistic use today: **per-app** (emulators through AdrenoTools, or an app loading its own
  driver). Treat it as a long-term option once we have a source kernel. Turnip's msm DRM backend
  needs the upstream drm/msm driver, not kgsl.

## 3. Why Vulkan RE can be slow on Qualcomm

Code facts (EvoX tree, `frameworks/native`):
- `SurfaceFlinger.cpp:chooseRenderEngineType()`: an explicit `debug.renderengine.backend` value of
  `skiagl`, `skiaglthreaded`, `skiavk` or `skiavkthreaded` always selects **Ganesh**. With the prop
  unset or unrecognised, SF picks Vulkan only if the aconfig flag `vulkan_renderengine` is set (false
  in bp4a), or Graphite only if `graphite_renderengine` / `debug.renderengine.graphite` is set, or if
  the preview rollout flag plus `debug.renderengine.graphite_preview_optin=true` are set. Otherwise
  it uses GL. So on our build, leaving the prop unset already gives GL. Non-threaded backends log an
  error: "Non-threaded RenderEngine not supported".
- `libs/renderengine/skia/VulkanInterface.cpp:377-400`: the queue priority starts at MEDIUM and is
  raised only from `VkQueueFamilyGlobalPriorityPropertiesEXT.priorities[]`. The priority create-info
  is attached only if `VK_EXT_global_priority` specVersion >= 2. `mIsRealtimePriority` is true only
  if REALTIME was reported. `SkiaVkRenderEngine::getContextPriority()` returns 0x3357 only in that
  case. **The Adreno 0615 driver has no `global_priority_query` string**, so the likely result is
  MEDIUM, and SystemUI doesn't boost itself either (`SystemUIApplicationImpl.java:165-174`).
  GL path: `SkiaGLRenderEngine` uses `EGL_CONTEXT_PRIORITY_REALTIME_NV`, which is present in
  `libEGL_adreno.so`.
- Sync: Ganesh-VK waits on acquire fences by importing sync_fd as a VkSemaphore and exports an
  exportable semaphore as the draw fence per frame (`GaneshVkRenderEngine::waitFence/flushAndSubmit`).
  It needs `VK_KHR_external_semaphore_fd`, which the driver has. Semaphore import/export overhead on
  older Qualcomm drivers is a second suspect. Look at `flush surface` and `vkQueueSubmit` durations
  in the RE thread.
- AHB: `VK_ANDROID_external_memory_android_hardware_buffer`, `VK_EXT_queue_family_foreign` and
  `VK_EXT_external_memory_dma_buf` are all present. `AutoBackendTexture` caches imports per buffer
  ID, so steady-state cost should be low. UBWC is handled by the driver
  (`vendor.gralloc.disable_ubwc=0`).
- Shader/pipeline cache: SF primes its cache at boot (`service.sf.prime_shader_cache`,
  `debug.sf.prime_shader_cache.*`; Pixel adds `ro.surface_flinger.prime_shader_cache.ultrahdr=1`).
  Ganesh-VK feeds HWUI's `ShaderCache` (`onVkFrameFlushed`). Graphite has
  `debug.renderengine.graphite.prewarm` and `.precompile` (both default true). Pipeline misses cause
  first-use hitches, **not** a steady 32 ms p50. I found no `debug.renderengine.skia_use_pipeline_cache`
  prop.
- Protected context: SF creates a second, protected VkDevice when
  `ro.surface_flinger.protected_contents=true` (stock sets it). That's a one-time cost, but it
  doubles device memory. Worth one A/B test.
- Vendor props with GPU/RE relevance on stock: `debug.sf.enable_gl_backpressure=1` (applies to any
  GPU composition), `debug.sf.latch_unsignaled=1`, `debug.sf.disable_client_composition_cache=1`,
  `vendor.gralloc.disable_ubwc=0`, `debug.egl.hw=0`, `debug.sf.hw=0`. No `debug.vulkan.*` props on
  stock.

**Which Snapdragon OEMs ship Vulkan RE?** In the stock dumps I checked, none sets
`debug.renderengine.backend` or Graphite props:
- Xiaomi 15 `dada` (sun, A16)
- Xiaomi 17-series `pudding` (canoe, A16)
- POCO F6 `peridot` (pineapple, A16)
- Redmi `zorn`/`marble`
- Nothing Phone (2) `pong` (taro, A16)
- Nothing Phone (3) `metroid` (sun, A16)
- Moto `cusco` (parrot, A15)
- dizi stock

All of them therefore run the platform default, which is GL unless the OEM's release config enables
`vulkan_renderengine`. HWUI Vulkan is what Snapdragon 8 Elite OEMs do ship:
`ro.hwui.use_vulkan=true` on Xiaomi 15/17 and Nothing Phone (3). Pixel gets Vulkan RE through
Google's release flags (not a device prop). zumapro opts in with
`debug.renderengine.graphite_preview_optin=true`, and Tensor uses Mali. **There's no evidence of
any Qualcomm OEM shipping Vulkan RE**, and none on parrot/0615.

## 4. HWUI Vulkan for apps

- **This build does not honour `debug.hwui.renderer`.** EvoX/Axion patched
  `frameworks/base/libs/hwui/Properties.cpp:peekRenderPipelineType()` to read
  **`persist.sys.ax_hwui_renderer`** (`skiavk`/`skiagl`). Its default comes from `ro.hwui.use_vulkan`,
  and it's exposed in Developer options by `SetGpuRendererPreferenceController`. Use that prop for
  tests.
- HWUI `VulkanManager` enables `VK_EXT_global_priority`, `_query` and `KHR_global_priority`, but it
  only requests a priority if `Properties::contextPriority != 0`. For SystemUI, that only happens
  when SF reports realtime. So the priority fix in lead 1 also matters for SystemUI on skiavk.
- Reports: Snapdragon 8 Elite OEMs ship HWUI Vulkan. For Adreno 7xx on 0615 drivers there are only
  anecdotes from users forcing `skiavk` with the [SkiaVK module](https://github.com/dyokism/SkiaVK),
  which warns: "SurfaceFlinger Vulkan composition depends heavily on vendor driver stability... may
  experience display flickering". No A710 measurements were found. HWUI skiavk on its own is lower
  risk than RE, because a regression only affects the app and SF keeps GL realtime.

## 5. Ranked test plan

Measure every case with `QS_ONLY=1 tools/ui-jank.sh <id> 20 landscape` (x2 runs) plus a perfetto
trace (`qs-*.pftrace`). Record the following:
- jank %, p50 and p99
- SF `RenderEngine` thread: `drawLayers`, `flush surface`, `vkQueueSubmit`/`waitFence` durations
- GPU completion (the `waitForGpuFence` / present-fence gap)
- SystemUI `dequeueBuffer` blocking
- GPU priority evidence: add ftrace events `kgsl/adreno_cmdbatch_submitted` and
  `kgsl/adreno_cmdbatch_retired`, which carry `prio` and `rb_id`, plus `kgsl/kgsl_context_create`,
  if present under `/sys/kernel/tracing/events/kgsl/`

Restart each case with `adb shell stop; adb shell start` after setting the props, and check
`dumpsys SurfaceFlinger | grep -A3 RenderEngine`. Put the props back afterwards.

**A. Live, adb only (no build)**

- **A0 (baseline evidence, 5 min).** Under skiavkthreaded, check
  `adb logcat -d | grep "SurfaceFlinger's GPU Priority"`. The expected value is 0 for Vulkan and
  13143 for GL. Also run `adb shell cmd gpu vkjson > vk.json` and look at `apiVersion`, the
  `VK_EXT_global_priority` specVersion, and whether `queueFamilyProperties` lists any priorities.
  Record which kgsl `rb_id` SF's submissions use under GL and under VK. **If VK SF runs at the same
  prio/rb as apps, lead 1 is confirmed.**
- **A1. Graphite.** `setprop debug.renderengine.backend default` (anything not recognised) plus
  `setprop debug.renderengine.graphite true`, then `stop; start`. Confirm
  "RenderEngine with SkiaVk Backend (Graphite)" in logcat. Also try with
  `debug.renderengine.graphite.precompile false` if boot or first frames stall.
- **A2. Protected context off under VK.** `setprop` can't override `ro.surface_flinger.protected_contents`,
  so this needs a build flag. Postpone it to B.
- **A3. Blur cost isolation, both backends.** `setprop debug.renderengine.blur_algorithm kawase`
  (values: `gaussian`, `kawase`, `kawase2`, `kawase2_fix_aliasing`), and SF blur off
  (`wm disable-blur 1`). This shows whether VK's penalty is in blur passes (offscreen render
  targets, which cost more on tilers with poor load/store ops) or in general submission.
- **A4. HWUI skiavk for SystemUI/apps with GL RE.**
  `setprop persist.sys.ax_hwui_renderer skiavk; stop; start`. Measure QS plus the full ui-jank app
  set, and check `dumpsys gfxinfo com.android.systemui` for "Pipeline=Skia (Vulkan)".
- **A5. Per-app newer driver / turnip, informational.** Install an AdrenoTools-using app (for
  example a Vulkan benchmark frontend) with K11MCH1 v819.2/v837 or Vauzi turnip v4.0. Check that
  the driver initialises on A710 (chip 0x07010000) with our kgsl. This shows whether 8xx-branch
  libgsl works on the stock 5.10 kgsl before any vendor swap.

**B. Build changes (ranked)**

- **B1. RE priority patch (highest value).** In `VulkanInterface::init()`: if
  `VK_EXT_global_priority` is present and the query returned `priorityCount == 0`, try `vkCreateDevice`
  with REALTIME, then HIGH on `VK_ERROR_NOT_PERMITTED_KHR`, then MEDIUM. Replace the `VK_CHECK` on
  that call with retry logic, and set `mIsRealtimePriority` from the level that succeeded. Relax the
  `specVersion >= 2` gate if the driver reports 1. Confirm with the A0 evidence, then rerun
  skiavkthreaded and Graphite. Carry it as a frameworks/native patch in our EvoX fork. It may be
  upstreamable as "drivers without global_priority_query".
- **B2. GPU blobs to V@0615.99 from garnet OS3.0.5.0.** Take the full Adreno set from TheMuppets
  garnet lineage-23.2 (`proprietary-files.txt` "Graphics (Adreno)", "(Adreno firmware)" and
  "(Vulkan)" sections): libGLESv2/EGL/GLESv1 adreno, libq3dtools, libgsl, libllvm-*, libadreno_utils,
  libadreno_app_profiles, vulkan.adreno.so, and the A710 firmware (`a710_sqe.fw`, `a662_gmu.bin`, `a710_zap.*`) that
  kgsl loads. Pin them with a comment. Same SoC and kernel family, so low risk. Rerun GL and VK.
- **B3. Vulkan feature XML.** Declare what the driver really supports (likely 1.3, from A0 vkjson)
  instead of `version-1_1`. This doesn't change RE, but it matters for apps and ANGLE.
- **B4. Protected content off (VK only, experiment).** Build with
  `ro.surface_flinger.protected_contents=false`, or skip `sProtectedContentVulkanInterface` init with
  a debug prop, to see whether a second VkDevice costs anything.
- **B5. Newer-branch Qualcomm driver (v819/837/840) as vendor blobs.** Only if A5 shows it
  initialises on A710. Expect risks for camera/codec (libgsl is shared by the GPU and C2 paths),
  CL, and app profiles. Revisit after we have the source kernel.
- **B6. Turnip as system Vulkan (`vulkan.freedreno.so`, Mesa >= 26.3 with the UBWC gralloc
  patch).** Research only for now. It's limited to MEDIUM priority on kgsl, and GLES stays on the
  blob. Becomes more interesting with a source kernel and drm/msm, which is a much bigger move.

Decision rule: keep GL RE as the default unless VK (B1 +/- B2, Ganesh or Graphite) gets to within
1-2 points of GL jank and the p50 is <= 9 ms over 2x20 QS cycles plus the full ui-jank app sweep.

## Sources
- Mesa FD710/720: https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/44466 ; `src/freedreno/common/freedreno_devices.py` ; `docs/android.rst` ; `src/freedreno/vulkan/tu_knl_kgsl.cc`
- https://github.com/Vauzi-17/710 , https://github.com/The412Banner/Banners-Turnip , https://github.com/K11MCH1/AdrenoToolsDrivers/releases , https://github.com/zoerakk/qualcomm-adreno-driver/releases , https://github.com/whitebelyash/AdrenoToolsDrivers/releases , https://github.com/StevenMXZ/Adreno-Tools-Drivers/releases
- https://xdaforums.com/t/snapdragon-driver-update-module.4685775/ , https://xdaforums.com/t/adreno-650-819v2-adreno-730-version-837-magisk-driver-update-module-cn-row-aosp-compatible.4739332/ , https://github.com/tryigit/AdrenoGpuDriver , https://github.com/olegos2/mobox/issues/299
- https://github.com/dyokism/SkiaVK
- Firmware dumps: https://dumps.tadiphone.dev (redmi/garnet, redmi/dizi, motorola/cusco, honor/parrot, xiaomi/dada, xiaomi/pudding, poco/peridot, nothing/pong, nothing/metroid)
- https://github.com/TheMuppets/proprietary_vendor_xiaomi_garnet ; LineageOS/crDroid/EvoX garnet trees above
- Pixel: https://android.googlesource.com/device/google/zumapro/+/refs/heads/main/device.mk
- Local: evox/frameworks/native/services/surfaceflinger/SurfaceFlinger.cpp (chooseRenderEngineType), libs/renderengine/skia/{VulkanInterface,SkiaVkRenderEngine,GaneshVkRenderEngine}.cpp, frameworks/base/libs/hwui/Properties.cpp, packages/SystemUI/.../SystemUIApplicationImpl.java

## Results on the device (b23, 2026-09-27)

QS pulldown, tools/ui-jank.sh QS_ONLY, 20 cycles, landscape; the first run after `stop; start` is the cold run.

| RenderEngine | cold | warm runs | p50 |
|---|---|---|---|
| GL (skiaglthreaded, default) | 8.6% (b22) | 5.07 / 5.59 / 5.33% | 9 ms |
| Vulkan Ganesh (skiavkthreaded) | 35.8% | 31.8% | 32-34 ms |
| Vulkan Graphite (b22, no patch) | 11.9% | 4.90 / 5.34% | 9 ms |
| Vulkan Graphite + priority patch (b23) | 5.81% | 5.27 / 5.48% | 8 ms |

- Graphite reaches GL parity warm. With the REALTIME/HIGH queue-priority fallback patch
  (evox/frameworks/native VulkanInterface.cpp), the cold run drops from 11.9% to 5.8%. The
  priority log line was not captured (SF's startup logs were lost), so which level was granted
  is unconfirmed.
- QS jank floors at ~5% on both backends, so the remaining cost is not RenderEngine (see
  performance.md section 11: HWC present ~7 ms).
- Under Vulkan, SurfaceFlinger (the Vulkan driver) enumerates all properties, which gives AVC
  denials. Graphite as default needs `dontaudit surfaceflinger property_type:file ...`.
- Decision: keep GL as the default. Graphite is a candidate once the newer V@0615.99 driver and
  the app sweep and video/protected-content checks are done under it.

### V@0615.99 (garnet OS3.0.5.0) live test, b29, 2026-09-28

User-mode driver bind-mounted over /vendor (30 files, stock a710 firmware kept). QS pulldown, warm runs:
GL 5.02% / 4.39% (stock V@0615.98: 4.84-5.06%). Graphite 4.69% / 4.68% (p95 18-19 ms vs GL 21-22 ms).
App sweep 0 crashes. The gain is within run-to-run noise, so it isn't shipped: we keep the stock driver
matched to the stock a710 firmware. Graphite keeps a slight p95 edge, still a candidate (needs the
surfaceflinger property dontaudit plus video/DRM checks).

### Driver sources survey (2026-10-05)

Driver versions read from `vendor/lib64/egl/libGLESv2_adreno.so` in the newest dumps.tadiphone.dev branch of each
device:

| Device (SoC, kernel) | Build | Driver |
|---|---|---|
| Redmi garnet (SM7435, 5.10) | OS3.0.2.0 (A16) | V@0615.99 (07/25/25) |
| Redmi dizi (SM7435, 5.10) | OS2.0.3.0 (A15) | V@0615.92 (11/26/24) |
| Redmi ruan (SM7435, 5.10) | OS2.0.2.0 | V@0615.91 |
| Motorola cusco (SM7435, 5.10) | V1UU35H (A15) | V@0615.88 |
| Honor parrot (SM7435, 5.10) | 2024-12 | V@0615.88 |
| Nothing pong (SM8475, 5.10) | 2026-06 (A16) | V@0615.98, the same as ours |
| POCO peridot (SM8635, 6.1) | OS3.0.6.0 | V@0762.36.1 (12/22/25), and it ships `com.qualcomm.qti.gpudrivers.pineapple.api34.apk` in vendor/app |
| Meta greatwhite (XR "neo", A740, 5.10) | UKQ1.241029.001 | V@0814.0 (01/29/25) |

- **OEMs on 5.10 kernels stop at the 0615 branch.** V@0615.99 (garnet, tested on b29: noise) is the newest from any
  phone maker. Newer branches come from 6.1 devices (0762) or Meta's XR line (0814, 0863).
- **Matrixx's V@0863.1** (vendor_xiaomi_garnet cd03ffe, 2026-05-25): "update GPU driver blobs from greatwhite
  V@0863.1".
  - greatwhite is a Meta XR device: platform `neo`, Adreno 740 (`a740v3_sqe.fw`), kernel 5.10.226, Android 14 on a
    vendor 12 base. The public dump is an older build with V@0814.0.
  - Its unified libgsl lists the Adreno 710. Being a Qualcomm build that runs on a 5.10 kgsl makes it the most
    plausible newer-branch candidate for our 5.10 kernel, more so than 0762 (built against 6.1).
- **Updatable driver package:** no SM7435 device ships one. Stock dizi and garnet have neither the prop nor the
  package.
  - The garnet ROM trees' `ro.gfx.driver.1` is copied from SM8650-class trees (`pineapple.api34`, 3 trees). Matrixx
    invented a `parrot.api34`. Both name packages that aren't installed, so the prop does nothing.
  - The only real package found is peridot's pineapple APK (V@0762.x, for 6.1 kernels).

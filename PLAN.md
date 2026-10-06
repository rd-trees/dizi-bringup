# dizi Evolution X: full bring-up and optimisation plan

Owner: Claude, working autonomously since 2026-09-27. **Never wait for input**: always have a build, a test
or an investigation running. Mark progress here (`[x]` done, `[~]` partly done), with the build that fixed each
item. Details and gotchas go in README.md, measurements in logs/, analysis in research/.

**Goals (from the user):**
- great performance, no lag on the quick settings pulldown
- no crashing stock apps
- full device functionality
- the pen features: pairing, a menu, button actions
- SELinux enforcing at the end
- then Stage C, the source kernel

## Current state (2026-09-28 17:00)

- **Tablet: release-1** (signed user build, slot a after the dirty-update test) with a **Magisk-patched boot_a**
  (for live A/B; the stock release boot.img restores it, and a sideload replaces it).
- **Release install path fully tested:**
  - clean install (fastboot flash the four images, recovery Format data, sideload, reboot);
  - dirty update (sideload again: same android_id, data and setup intact, slot b→a).
  - `flash-dizi.sh` is still untested.
- **Verified by the user:** pen buttons (all pen features now confirmed), double-tap to wake (by hand, then built in),
  the blur toggle in Settings → Display.
- **release-2 building:** release-1 + double-tap to wake (83fa9e8, off by default) + USB attach recovery on user
  builds (f32ec4b). Sign as a new name, then sideload as a dirty update.
- **Recents -> app jank (research/performance.md 16-16b):** about 16% of display frames; SF GPU composition runs long.
  - Ruled out, live: GPU clock, DDR clock, idle timer, SF phase offsets, GPU backpressure, blur, snapshot-scale config.
  - The Pixel Launcher prebuilt needs 9-16 ms of GPU per frame (p90-p95) in the transition.
  - The remaining lever is Launcher3 Quickstep from source (`evox/packages/apps/Launcher3`); the user hasn't decided.
- **Published:** the rd-trees org repos; Telegram not yet.

**Next up (in order):**
0. Sign release-2, stage it, and the user sideloads it (dirty). Check Tap to wake and USB after a reboot without a replug.
1. DT2W standby drain: overnight unplugged with Tap to wake on vs the ~6 mA baseline; then on-then-off without a reboot.
   Closed-cover taps (PhoneWindowManager lid check, if needed).
2. Test `flash-dizi.sh` once; then publish (release/TELEGRAM.md).
3. Launcher3 Quickstep experiment (Recents jank, desktop-windowing bugs), if the user wants it.
4. The user-build avc denials (74 on release-1), the `-dirty` kernel version string.
5. Phase 1 gaps: headphone/USB-C/BT audio, keyboard, OTG, 33 W charging, hotspot.

**Waiting on the user:**
- Unplug USB for the deep-sleep test.
- The Parts pressed colour.
- Allow the Mac mic prompt (audio loopback tests).

**Test rig:**
- adb root over USB through the Mac. adb-over-Wi-Fi for unplugged tests (`adb tcpip 5555` is set).
- `tools/deploy.sh <id>` stages a delta against the previous super.img (~1-2 min over the VPN; README gotcha 23)
  and flashes from the bootloader without wiping. Never use `fastboot -w` (gotcha 19).
- The Mac webcam watches the screen (`tools/cam.sh`, latest.jpg). The mic recorder waits for the macOS permission.
- Checks:
  - `tools/validate.sh`: hardware.
  - `tools/app-sweep.sh`: crashes.
  - `tools/exercise.sh`: camera, video, audio, Wi-Fi, BT, rotation, screen.
  - `tools/ui-jank.sh [QS_ONLY=1]`: frame stats. Discard the first run after a restart (gotcha 24).
  - `tools/avc-triples.py`: denials.
  - `tools/boot-kernel-test.sh`: RAM-boot a kernel.

## Phase 1: crash-free and functional

Crashes (all fixed):
- [x] Boot loop: userdata pre-formatted (b13)
- [x] adb root / debuggable: EvoX hides it (b14, `persist.sys.evox_debug_enabled`)
- [x] Pixel Launcher crash: tablet_core_hardware.xml (b14)
- [x] SIM prompt and com.qti.phone crash loop: telephony features and apps dropped (b14)
- [x] QTI codec2 HAL SIGSYS: seccomp uname/setsockopt (b15); store manifest (b16)
- [x] Speaker audio: sipa.bin amp firmware (b17b). All 4 amps on with a test tone; the user confirmed audio.
- [x] Camera app (Aperture) opens (b17b, aux cameras hidden)
- [x] Wallpaper & style opens (b17b, Flex clock overridden)
- [x] Pixel Launcher recents crash / overlays missing on the first boot after a flash (system/core c96203e, b19)
- [x] Device name 'Redmi Pad Pro' (b19)
- [x] Sweep: 19 launchable apps, 0 crashes/ANRs/tombstones (b18 onwards; every build through b29)

Functionality:
- [~] Audio: 4 speakers (tone OK). **Mic recording OK** (b32, tools/audio-rec, silent room-noise test as root: mic -56 dBFS,
      voice_recognition -59, camcorder -65, unprocessed -77, no denials). TODO: headphone jack, USB-C audio, VoIP, volume steps
- [x] Camera: rear and front 8 MP photos, video recorded and played back, no denials (b22-b29, tools/exercise.sh).
      Still to check: QR scanning, 4K/60
- [x] Video: **HW decode H.264, HEVC, VP9 at 1080p and 2160p** (c2.qti.*; tools/codec-test.sh, b36). AV1: no HW on
      SM7435; the software dav1d/gav1 decoders are present (the gallery doesn't play AV1-in-MP4; YouTube falls back to VP9)
- [x] **Widevine L1** (b18: systemId 32753, OEMCrypto 16, HDCP 2.3). Still to do: Netflix/Prime HD (needs an account)
- [~] Wi-Fi: connected to the user's 5 GHz AP and used for adb-over-Wi-Fi; scans 11-18 networks; BT off/on OK.
      TODO: hotspot, Wi-Fi Direct, BT audio
- [~] Sensors: accelerometer, light and hall inputs present (validate). TODO: auto-rotate, auto brightness, hall cover
- [~] Display: 120/90/60 Hz modes, dpi 249.5, backlight. TODO: refresh switching, night light, color modes
- [~] Charging: batterysecret runs (b22; 33 W PD auth). TODO: measure rate and fast charge, charge limit
- [x] Suspend: deep sleep works unplugged (b29 stock kernel: 1304 suspends in 25 min, **~6 mA idle**).
      Plugged in, the USB controller (a600000.ssusb) blocks suspend, as on stock.
      TODO: find the frequent (~1/s) timerfd/WLAN wakeups (partly the adb-over-Wi-Fi polling), overnight drain
- [~] USB: **MTP OK** (b36: gadget ffs.mtp+ffs.adb, the Mac enumerates an MTP interface; adb survives the switch).
      TODO: file transfer through a client, OTG (keyboard/mouse), tethering
- [ ] Keyboard (BT), mouse
- [x] Storage: FBE active (validate). TODO: lockscreen PIN + reboot unlock
- [ ] Recovery: our recovery (adb/fastbootd), OTA zip sideload; dirty flash keeps data (yes: every no-wipe deploy)
- [x] Thermal HAL reports temperatures under enforcing (b25)

## Phase 2: performance and smoothness

Done:
- [x] **Commit stall:** spec_fence=1 made every HWC commit wait an extra vsync. Settings 46% -> 0.06% (b19)
- [x] Stock libsdmcore under the source composer: dpi 249.5 (was 24.95), 0 video scaler errors, no SDM log spam (b23)
- [x] **Landscape was 100% GPU-composed:** the inline rotator failed on the rotated, zoomed wallpaper and dropped
      the whole frame to the GPU. enable_rotator_ui=0 (b26); made race-free as static props (541c516, b28).
      Settings 0.71% -> 0.09%, launcher 4.3% -> ~1.1%, client-composited frames 97% -> ~54%
- [x] GPU hints: INTERACTION 600 MHz, EXPENSIVE_RENDERING 940 MHz (b19, b394fce b29)
- [x] Dalvik heapgrowthlimit pinned at stock 256m (b22)

Quick settings pulldown (12.1% on b18 -> **4.8-5.1% on b29**, p90 16-17 ms):
- [~] The floor is SF's blur design: the layer requesting background blur and everything below it are
      GPU-composed every frame at 2560x1600@120 (research/performance.md s11-12)
- [x] Tried without gain:
  - blur algorithm and radius (20dp = 34dp)
  - SF latch/backpressure
  - SF layer caching (worse)
  - Vulkan Ganesh (much worse) and Graphite (parity)
  - the Vulkan priority patch (fixes cold start)
  - garnet GPU driver V@0615.99 (within noise, not shipped)
- [ ] Ideas left:
  - Graphite as default (slight p95 edge; needs an SF property dontaudit and video/DRM checks)
  - fewer layers under the shade

Boot-time panel timing (found 2026-09-28):
- [x] ~50% of boots left the panel at 60 Hz while SF ran 120 Hz (44 ms frames everywhere). Workaround: a 60->120
      round trip at boot from XiaomiParts (b32): **8/8 good boots** (QS 5.0-5.7%). Kernel fix in stage (b) (s14)

Recents / overview (user request, 2026-09-28):
- [~] b29 landscape 24% janky (p50 26 ms). Capping the 600dp landscape blur radius (b31) did NOT help (b32: 23%).
      Cause: SF rotates, scales and blurs the full-screen wallpaper every frame (landscape GPU 5.1 ms vs 3.3 ms portrait).
      Fix: ro.launcher.depth.overview=false (cf1fab7, b34; no depth behind overview, as stock HyperOS).
      **b34: recents 2.5-3.0% (was 23%), SF missed frames 22 (was ~2900), 0 client-composited frames**
      LauncherOverlayDizi caps it at 30dp (96fda0a, b31). Portrait was 7.3%, blur-off 3.0%.
      The b31 measurement (55%) ran on a bad 60 Hz boot: re-measure on b32
- [ ] Task-snapshot binder calls ~24 ms each (LauncherBgIO, background; stock uses the same snapshot config)
- [~] App drawer open/close (launcher fling test ~10% on b34): the drawer blur costs ~4 pts (blur off 5.9%).
      There's no launcher property for it (an aconfig flag). Only the global blur toggle, which the user decides

Still to do:
- [ ] Power HAL tuning, touch boost, ADPF (research/performance.md)
- [x] zram lz4 (5eebdf4, b35): within noise, kept. **ADPF on** (725a92f, b36): works under enforcing, jank within noise
- [x] Dalvik phone-6144 A/B: no gain (cold equal or worse), rejected (research/performance.md s15)
- [ ] Boot time and app start against stock; thermals under sustained load; battery drain

## Phase 3: pen

- [x] BLE auto-pairing (DiziPen PenPairer, b15)
- [x] Pen input enable (mode 20) on connect (b13)
- [~] Settings page: button actions (DeviceKeyHandler), battery, force-enable, forget pen. KeyHandler loads (b21+)
- [ ] Button actions work (**user test pending**: upper = Home, lower = New note)
- [ ] Pen battery and low-battery notification; reconnect after sleep
- [ ] Hover / palm rejection (palm rejection OK in a browser, per the user)
- [x] Split/desktop via the app handle works (b21 overlay; confirmed by the user on b39)
- [~] Desktop windowing rough edges (b39, logs/build-39/desktop): (a) a release near the top gives a maximized desktop
      window that looks like fullscreen ('nothing happens'); (b) opening a fullscreen app from Recents deactivates the
      desk (UNKNOWN_EXIT) but leaves desk windows on top; (c) Recents->home: the floating taskbar hangs ~1 s (the Pixel
      Launcher home spring ~967 ms, can't morph into a dock with an inline QSB). Pinned taskbar avoids (c): documented.
      Candidate fix for all three: AOSP Launcher3 Quickstep from source (same build as the framework) as a test variant

## Phase 4: SELinux enforcing

- [x] Denials collected and covered (b19-b25; tools/avc-triples.py)
- [x] Policy in device sepolicy, no permissive domains, no neverallow violations
- [x] **Enforcing by default since b24** (`DIZI_SELINUX_PERMISSIVE=true` to opt out). b25-b29: 0 denials on boot
- [ ] Re-collect after the remaining Phase 1 tests (audio, USB, recovery)
- [ ] Remove bring-up flags for release builds (keep a debug variant)

## Phase 5: release hygiene

- [x] garnet leftovers: vendor.prop, init.qcom.rc / init.target.rc (trimmed stock), modem daemons, batterysecret rc (b22)
- [x] GameBar RAM temp zone (b25)
- [ ] Dead garnet sepolicy (hal_fingerprint.te, rild.te, hal_mlipay.te) and genfs entries (goodix, fpc)
- [ ] Local patches listed and upstreamable:
  - system/core c96203e
  - frameworks/native 0771ce4
  - vendor/gms
  - kernel a67b949
- [ ] `installclean` build, OTA zip, sideload test
- [ ] Trees committed cleanly (device, vendor, dizi-kernel)

## Phase 6: kernel from source (Stage C)

- [x] Gap analysis: research/kernel-source.md
- [x] Stage (a): LineageOS sm7435 5.10.269, gki_defconfig, stock clang r416183b (kernel/build-gki.sh).
      Module.symvers matches all 27973 imports + module_layout of the 377 stock modules
- [x] RAM boot on b25 (tools/boot-kernel-test.sh):
  - 373 modules loaded
  - validate all PASS
  - enforcing, 0 denials
  - sweep 0 crashes
  - camera, Wi-Fi, BT OK
- [~] Shipped opt-in: dizi-kernel 585cb4b `Image-source`, BoardConfig `DIZI_SOURCE_KERNEL=true` (63662b3). b30 building
- [x] **b34-b37 run the source kernel flashed** (soak: 4 rounds of sweep + exercise + recents on b37 with 0 crashes/ANRs;
      the only tombstones are SurfaceFlinger aborts from my manual composer restarts): 0 denials, 373 modules, no errors, sweep 0 crashes, exercise and validate
      PASS, Settings 0.09-0.18%, QS 4.8-5.5% (parity with the stock kernel). Boot loop running. TODO: deep sleep unplugged,
      pen mode 20 (user), then make it the default
- [~] Stage (b): **source msm_drm.ko** (MiCode display-drivers, CRC-identical, research/kernel-stage-b-display.md).
      b38 (baseline driver): boots, validate PASS, brightness 146..4095 OK, jank at parity, same dmesg error profile
      as stock. **b39: kernel splash-timing fix (patches/0002) works**: with the Parts kick disabled, 8/8 good boots, 4 with the
      bootloader's 60 Hz timing (vtotal 5516 vs 2758) detected and reprogrammed. **Default since fa2e529**
- [ ] Other source modules, (c) source dtbo (research/kernel-source.md)
- [ ] First camera open after boot sometimes captures nothing (b25, b38; a re-run always works)

## Log

- 2026-09-27: build-13 first boot; b14–b16 fixes; b17b audio, camera and wallpaper fixed; b18 pen menu flashed.
- 2026-09-27 19:45: session paused; the Mac is going offline. **Detached build-21** running (tools/offline-builds.sh,
  log logs/build-21.log, summary logs/offline-builds.txt). Nothing was flashed after b19; the tablet runs b19
  (+ live bind-mounts gone after reboot). b21 = b19 + pen KeyHandler R8 keep, desktop windowing
  (canInternalDisplayHostDesktops), XiaomiParts magenta fix. **On resume:** `tools/deploy.sh build-21`
  (no wipe), then test the pen buttons (user set upper=Home, lower=New note), desktop and split via the app handle,
  and the Parts pressed colour. Then SELinux (logs/build-19/selinux/triples.txt: 53 real rules plus a camera prop dontaudit).
- 2026-09-27 21:00: resumed. Staging to the Mac is now a delta against the previous super.img
  (74 s instead of ~35 min over the ~4 MB/s VPN). b21 deployed (no wipe): overlays OK on the upgrade boot,
  KeyHandler loads, sweep 0 crashes, validate all PASS. Mac mic recorder blocked on the macOS permission prompt.
  b22 in progress: SELinux rules, garnet rc/prop cleanup, batterysecret, dalvik 256m.
- 2026-09-27 21:50: b22 deployed: boot < 1 min, batterysecret running, modem daemons gone, 0 crashes, validate PASS.
  Denials 131 -> 59 lines, 8 triples; tools/exercise.sh (camera, video, tone, wifi, BT, rotation, screen off)
  adds none. Remaining triples are covered by the b23 policy. Vulkan RE rejected for now (research/vulkan-adreno710.md
  has the leads: GPU priority patch, Graphite, garnet V@0615.99 driver).
- 2026-09-27 22:35: b23 (stock libsdmcore, last policy batch, Vulkan priority patch): dpi fixed, no SDM spam,
  0 crashes. Vulkan: Graphite RE = GL parity (research/vulkan-adreno710.md); GL stays default. Enforcing live-tested OK.
  b24 (enforcing) building.
- 2026-09-27 23:10: **b24 boots enforcing**: validate PASS, 0 crashes in the sweep, camera/Wi-Fi/BT OK.
  Found under enforcing: the thermal HAL read no temperatures (GameBar's chown of 2 zones plus my dontaudit
  hiding dac_read_search). Fixed in b25 (6ad1bae). The kernel: research/kernel-source.md; the stage (a) GKI Image
  build is running (kernel/build-gki.sh, stock clang r416183b).
- 2026-09-27 23:40: b25 enforcing, 0 boot denials. **Source-built kernel boots** with all stock modules (stage a).
  QS: SF GPU composition is the limit (frame timeline: SF stuffing/GPU deadline), GPU already ~875/940 MHz; blur
  algorithm no effect, blur off ~-1 pt; portrait 2.9% vs landscape 5.2%.
- 2026-09-28 00:30: rotator finding -> b26 building. GPU driver live test blocked pending a user permission rule.
- 2026-09-28 00:50: b26 deployed (enforcing): landscape fully DPU-composed; Settings 0.1%, launcher ~1.9%.
- 2026-09-28 01:40: display boot props made static (race found on b27), EXPENSIVE_RENDERING GPU floor 940 MHz
  (QS ~4.8%). Blur radius and SF layer caching: no gain / worse. b29 building.
- 2026-09-28 01:50: **b29 = current best** (enforcing). Clean reboot: 0 denials, sweep 0 crashes, exercise and validate PASS.
  Landscape: launcher/bars/decor on the DPU, only the wallpaper on the GPU. Settings 0.09-0.18% (p99 10 ms),
  launcher 1.1% (drawer runs noisy), QS 4.8-5.1% (p90 16-17 ms). Next: source-kernel soak, suspend/deep sleep,
  pen buttons (user), GPU driver test (user must run the bind step), stage (b) kernel modules.
- 2026-09-28 02:45: plan rewritten to the current state. The V@0615.99 driver test ran after the user approved:
  within noise, not shipped. Deep-sleep test running over Wi-Fi adb; b30 (source kernel) building.
- 2026-09-28 03:20: deep sleep OK (~6 mA). The user asked for a recents analysis and is asleep: **no sounds** (media
  muted, exercise.sh QUIET=1, dim screen). Recents 24% -> the 600dp landscape launcher blur. b31 building with the fix.
- 2026-09-28 04:40: found the intermittent 60 Hz panel boots (4/8). b32 = XiaomiParts round-trip workaround.
- 2026-09-28 05:30: b32 8/8 good boots; mic OK (silent test); recents radius cap no gain -> b34 = source kernel + overview depth off.
- 2026-09-28 05:50: b34 = source kernel + overview depth off: recents 23% -> 2.7%, kernel at parity. lz4 zram staged; ADPF research.
- 2026-09-28 06:40: b36 = source kernel + lz4 + ADPF, all verified under enforcing. Dalvik 6144 rejected by measurement.
- 2026-09-28 07:10: b37 verified (current best). Chrome is measured from SF layer stats. Kernel stage (b) msm_drm build delegated.
- 2026-09-28 07:30: b37 soak clean (0 crashes/ANRs; tombstones only from deliberate composer restarts).
- 2026-09-28 08:00: b38 = source display driver, OK. b39 = + kernel splash fix, testing without the Parts workaround.
- 2026-09-28 08:40: **kernel stage (b) display driver done**: the source msm_drm with the splash fix is the default (b39 verified).
- 2026-09-28 08:50: the user confirmed the app handle (split/desktop) works.
- 2026-09-28 10:10: tablet away. b40 and b41-tune archived. Release tooling and keys prepared; user build release-1 running.
- 2026-09-28 12:30: desktop/taskbar issues analysed from the user's recording; pinned taskbar tested then reverted; documented.

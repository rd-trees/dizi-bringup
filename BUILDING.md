# Building ROMs for the Redmi Pad Pro (dizi)

There are three ROM lines. All of them use the same device tree (different branches of
[device_xiaomi_dizi](https://github.com/rd-trees/device_xiaomi_dizi)), the HyperOS OS3.0.303.0 blobs from
[vendor_xiaomi_dizi](https://github.com/rd-trees/vendor_xiaomi_dizi), and the kernel artefacts from
[device_xiaomi_dizi-kernel](https://github.com/rd-trees/device_xiaomi_dizi-kernel).

| ROM | Android | Manifest | Device branch | Lunch | Target |
|---|---|---|---|---|---|
| Evolution X `bka` | 16 | `https://github.com/Evolution-X/manifest -b bka` | `bka` | `lineage_dizi-bp4a-user` | `m evolution` |
| Evolution X `cnb` | 17 | `https://github.com/Evolution-X/manifest -b cnb` | `cnb` | `lineage_dizi-cp2a-user` | `m evolution` |
| LineageOS 23.2 + MindTheGapps | 16 | `https://github.com/LineageOS/android.git -b lineage-23.2` | `lineage-23.2` | `lineage_dizi-bp4a-user` | `m bacon` |

The 5G model (ruan) is built on top of the dizi device tree: see
[ruan-bringup](https://github.com/rd-trees/ruan-bringup).

## 1. Sync

```sh
mkdir evox && cd evox
repo init -u https://github.com/Evolution-X/manifest -b bka --git-lfs   # or -b cnb, or the Lineage manifest
mkdir -p .repo/local_manifests
curl -o .repo/local_manifests/dizi.xml \
  https://raw.githubusercontent.com/rd-trees/dizi-bringup/main/release/manifest/dizi.xml   # bka
# cnb: release/manifest/dizi-cnb.xml, Lineage: release/manifest/dizi-lineage.xml
repo sync -c -j8 --no-tags
```

- Another tree already on disk saves most of the download: `repo init ... --reference=/path/to/other/tree`.
- googlesource rate-limits big syncs (HTTP 429), and a few projects then get no checkout even when
  `repo sync` "succeeds".
  - Check with `repo list -p | while read p; do [ -e $p/.git ] || echo $p; done`.
  - Re-sync what that prints with `-j2`.

## 2. Platform patches

The device tree carries the patches it needs in `device/xiaomi/dizi/patches/<project path>/`. Apply them with
`git am` in each project.

| Patch | bka | cnb | Lineage |
|---|---|---|---|
| `system/core`: keep `/data/resource-cache` on upgrade (EvoX's init wipes it and races the overlay manager) | yes | fixed upstream | not needed (no wipe) |
| `build/make`: releasetools accepts a target-files zip (signing crashes without it) | yes | fixed upstream | yes |
| `frameworks/native`: realtime Vulkan queue priority for RenderEngine | yes | yes | yes |
| `frameworks/native`: mark SystemUI's screen decoration as an RC mask (`ro.sf.screen_decor_mask`) | - | yes | - |
| `frameworks/native`: GPU floor for all client composition (`ro.sf.gpu_composition_boost`) | - | yes | - |
| `frameworks/base`: SystemUI draws the corners as a hardware RC mask | - | yes | - |
| `frameworks/base`: ImageWallpaper redraws when the transform hint changes | - | yes | - |
| `vendor/lineage`: kernel out dir for a relative `OUT_DIR` (release builds) | yes | yes | yes |
| `vendor/gms`: CrossDeviceAccessServicePrimary uses-library | yes | fixed upstream | n/a |
| `packages/apps/Launcher3` (Lineage branch only): the swipe-home crash fix, and the Visual effects toggles | - | - | yes |

The cnb frameworks patches go together with the device tree's `ro.sf.*` properties; without them the
properties do nothing.

**cnb, Wallpaper & style:** the DP11 GMS drop's picker needs framework code (`ClockManager`) this build
doesn't have yet and crashes, taking the launcher down with it at boot. Use the previous drop's picker:

```sh
cd vendor/gms
f=system_ext/packages/privileged_apps/WallpaperPickerGoogleRelease/WallpaperPickerGoogleRelease.apk
git fetch evo 0c718e01bf50172a8b87765d5bc3628b1e43341f   # gms: Update from mustang CP3A.260905.009
git checkout FETCH_HEAD -- $f && git lfs pull --include="$f"
```

## 3. Build

```sh
source build/envsetup.sh
lunch lineage_dizi-bp4a-user        # cnb: lineage_dizi-cp2a-user
m evolution                         # Lineage: m bacon
```

- The output is the flashable zip in `out/target/product/dizi/`. For the fastboot package, also run `m superimage`.
- `userdebug` builds work too. EvoX and Lineage hide adb root on them unless `WITH_ADB_INSECURE=true` is exported.

### Bench builds (this repo's tools)

`tools/build.sh` wraps this with a per-device out dir, a lock and ccache:

```sh
TREE=evox    tools/build.sh build-N                 # EvoX bka, target `evolution`
TREE=evox-cnb tools/build.sh cnb-N droid superimage # EvoX cnb (the release config is read from the tree)
TREE=lineage tools/build.sh lineage-N droid superimage
TREE=... tools/deploy.sh <id> [--wipe]              # stage on the USB host, flash from the bootloader, wait for boot
```

- Bench builds are userdebug, with adb root.
- `RELEASE=1` builds `user` into `out-release`, without insecure adb or the bench key.
- A new tree can reuse another tree's build output:
  1. `cp -a` the other tree's `out-dizi` into the new tree.
  2. Run `tools/match-mtimes.py <old-tree> <new-tree>`. Ninja then only rebuilds files that really differ
     (Lineage from EvoX: 1.64M files matched, first build 71 min instead of several hours).

### Signed releases

```sh
RELEASE=1 TREE=evox-cnb tools/build.sh cnb-release-N target-files-package otatools
TREE=evox-cnb tools/sign-release.sh            # the name defaults to the build's ro.evolution.build.version
```

`tools/sign-release.sh` writes `release/out/<name>/`:
- `<name>.zip`: the signed OTA, for recovery sideload.
- `<name>-fastboot.zip`: images, `flash-dizi.sh`, INSTALL.md, collect-logs.
- The recovery-side images.

Keys live in `keys/`: platform, shared, media, networkstack, releasekey, AVB and APEX keys.
- Never commit them.
- Updates only install over builds signed with the same keys.

## 4. Install

See [release/INSTALL.md](release/INSTALL.md): fastboot the recovery-side images, format data in recovery, sideload the zip.
- Going from one ROM line to another (or from test-keys to release-keys) needs a data wipe.
- Never relock the bootloader.

## Device-specific notes that matter when building

- **Blobs:** regenerate with `tools/gen-blobs.py`, then `extract-files.py`.
  - The blob fixups in `extract-files.py` matter, including the one that drops the Dolby Vision
    `IComponentStore/dolby` instance.
  - A declared Codec2 instance that never registers blocks mediaserver, then cameraserver, then system_server
    (an 80 s boot with a watchdog kill).
- **sepolicy:**
  - `devicesettings_app` and `settingslib_prop` need the compat ignore entries in
    `sepolicy/private/compat/202404` on Lineage, whose `treble_sepolicy_tests` EvoX's fork skips.
  - On Android 17, `vendor_poweroffalarm_app` no longer exists.
- **Android 17 (cnb) changes versus bka:** FCM level 7, 64-bit only, legacy libion, the power-libperfmgr
  namespaces, `TARGET_USES_VULKAN := true` (HWUI on Vulkan), and the notification shade blur off by default.
- **Performance defaults:**
  - SF/app work durations of 16.7 ms, and `max_frame_buffer_acquired_buffers=3`.
  - Blur toggles: Trebuchet Settings > Visual effects on Lineage; XiaomiParts > Display > Blur effects for the
    shade.
  - The measurements behind every default are in [research/performance-report.md](research/performance-report.md).

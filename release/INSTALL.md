# Evolution X 11.11 (Android 16) for the Redmi Pad Pro (dizi) – unofficial

**Device:** Redmi Pad Pro, Wi-Fi model, codename `dizi` (SM7435). Not for the 5G model (`ruan`).

## Before you start

- **Unlock the bootloader** with Xiaomi's official tool. This wipes the tablet.
- **Install Android platform-tools** (`adb` and `fastboot`) on a PC or Mac.
- **Update HyperOS first:** the tablet should run HyperOS **OS3.0.303.0 or newer** (Android 16 firmware).
  The ROM reuses the firmware partitions (modem, bootloader, TrustZone) already on the tablet.
- **Back up your data.** A first install wipes everything.
- **Never relock the bootloader** while this ROM is installed. That would brick the tablet.

## First install (recovery + sideload, the usual Evolution X way)

Downloads from the release page: `boot.img`, `dtbo.img`, `vendor_boot.img`, `recovery.img`
and the ROM zip `EvolutionX-…-dizi-11.11-Unofficial.zip`.

1. Reboot to the bootloader: power off, then hold **power + volume down**. Connect over USB.
2. Flash the recovery-side images:
   ```
   fastboot flash boot boot.img
   fastboot flash dtbo dtbo.img
   fastboot flash vendor_boot vendor_boot.img
   fastboot flash recovery recovery.img
   fastboot reboot recovery
   ```
3. In recovery, choose **Factory reset → Format data / factory reset** and confirm.
4. Go back and choose **Apply update → Apply from ADB**. On the computer run:
   ```
   adb sideload EvolutionX-…-dizi-11.11-Unofficial.zip
   ```
   The transfer may stop at about 47% on the computer; that's normal.
   Wait until recovery reports success.
5. **Reboot system now.** The first boot takes a few minutes. Google apps are included.

### Alternative: fastboot package

Unpack `EvolutionX-…-dizi-fastboot.zip`, boot to the bootloader, and run `./flash-dizi.sh`.
It flashes everything from fastboot and wipes data; type `yes` when asked.

## Updating

- **Recovery:** reboot to recovery, choose *Apply update → Apply from ADB*, and sideload the new zip.
  No format is needed. This keeps your data.
- **Fastboot package:** `./flash-dizi.sh --keep` keeps your data.

Updates only install over builds signed with the same keys, i.e. this ROM's own releases.

## What works

- **Display:** 2560x1600 at 120 Hz, with brightness and auto-brightness. Smooth scrolling, and animations
  composed by the display hardware.
- **Touch and pen:**
  - touch;
  - the Redmi Smart Pen: automatic pairing, pressure, hover, palm rejection;
  - pen settings in *Settings → Connected devices → Pen*, with configurable button actions.
  - double-tap to wake: *Settings → Display → Tap to wake* (off by default).
- **Audio:** all four speakers and the microphones.
- **Camera:** rear and front, photo and video.
- **Video:** hardware decode of H.264, HEVC and VP9 up to 4K. Widevine **L1** (HD streaming).
- **Connectivity:** Wi-Fi (2.4/5 GHz) and Bluetooth.
- **Sensors:** auto-rotate, the light sensor, and the hall sensor (cover).
- **Power:** charging, and deep sleep (about 6 mA idle).
- **Storage and USB:** file-based encryption, MTP.
- **Windows:** split screen and desktop windowing from the app handle.
- **Security:** SELinux is enforcing.
- **Kernel:** built from source (LineageOS sm7435 plus Xiaomi's display driver).

## Known issues

- The quick settings shade and the app drawer drop a few frames. This comes from the blur effect;
  turning off the window blurs switch in *Settings → Display* removes it.
- The first camera launch right after a boot sometimes takes no photo. Take it again.
- Going from Recents to the home screen, the floating taskbar hangs at the bottom for about a second before the
  dock appears (Pixel Launcher can't morph its floating taskbar into this dock layout). Pinning the taskbar
  avoids it: long-press the divider in the taskbar → *Always show taskbar*. The divider only appears once
  the taskbar shows recent apps that aren't in the dock.
- Desktop windowing: opening a fullscreen app from Recents while desktop windows are open can leave those
  windows floating on top. Releasing the app handle near the top gives a maximized desktop window that
  looks the same as fullscreen.
- Double-tap to wake: its battery cost in standby is not measured yet, and a tap through a closed
  magnetic cover can wake the tablet.
- Not tested yet: the headphone jack, USB-C audio, Bluetooth audio, the Redmi keyboard, OTG,
  33 W fast charging, and the Wi-Fi hotspot. Reports are welcome.

## Getting back to HyperOS

Flash Xiaomi's fastboot ROM for dizi with its `flash_all.sh` (**not** `flash_all_lock.sh`).

## Source

- Device tree: https://github.com/rd-trees/device_xiaomi_dizi
- Kernel artefacts: https://github.com/rd-trees/device_xiaomi_dizi-kernel
- Vendor blobs: https://github.com/rd-trees/vendor_xiaomi_dizi
- Kernel: https://github.com/rd-trees/kernel_xiaomi_sm7435 (branch `lineage-23.2-dizi`)
- Display driver: https://github.com/rd-trees/dizi-display-drivers
- Bring-up tooling and notes: https://github.com/rd-trees/dizi-bringup

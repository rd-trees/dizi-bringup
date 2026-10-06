#EvolutionX #dizi #ROM #A16 #Unofficial

**Evolution X 11.11 | Android 16**
**Redmi Pad Pro (dizi) – Unofficial**
Updated: <DATE>

▪️ **Download:** <LINK>
▪️ **Install guide:** <LINK to INSTALL.md>
▪️ **Source:** https://github.com/rd-trees/device_xiaomi_dizi
▪️ **SHA256:**
`<sha256>  EvolutionX-16.0-<DATE>-dizi-11.11-Unofficial-fastboot.zip`
`<sha256>  EvolutionX-16.0-<DATE>-dizi-11.11-Unofficial.zip`

**Highlights**
• First Evolution X build for dizi, on OS3.0.303.0 (Android 16) firmware
• Kernel built from source (LineageOS sm7435 5.10.269, Xiaomi display driver)
• SELinux enforcing · Widevine L1 · Google apps included
• Smooth 120 Hz: animations composed by the display hardware, as on stock
• Fixed the random "60 Hz after boot" stutter at the kernel level
• Recents/overview reworked: 23% → 3% dropped frames
• **Redmi Smart Pen:** auto-pairing, pressure, hover, palm rejection, button actions
  (Settings → Connected devices → Pen)
• Split screen and desktop windowing, tablet taskbar
• Double-tap to wake (Settings → Display → Tap to wake)
• 4K hardware decode for H.264/HEVC/VP9, all four speakers, deep sleep at ~6 mA

**Install (clean flash)**
1. Unlocked bootloader, HyperOS OS3.0.303.0 or newer
2. In the bootloader, flash `boot`, `dtbo`, `vendor_boot`, `recovery`, then `fastboot reboot recovery`
3. Recovery: Factory reset → **Format data**
4. Apply update → Apply from ADB → `adb sideload EvolutionX-*.zip`
5. Reboot. The first boot takes a few minutes
Alternative: the fastboot package with `./flash-dizi.sh` (see the guide)

**Notes**
• Wi-Fi model (dizi) only. Not for the 5G model (ruan)
• Updates: dirty-flash the new zip via recovery sideload, no format needed
• Blur in QS and the app drawer costs a few frames: Settings → Display → turn off window blurs
• Not yet verified: the headphone jack, USB-C audio, Bluetooth audio, the keyboard,
  and 33 W charging. Please report
• Never relock the bootloader on a custom ROM
• Back to stock: Xiaomi fastboot ROM, `flash_all.sh` (**not** `flash_all_lock.sh`)

**Bugs:** send logs (`adb logcat -b all -d > log.txt`) in <GROUP>

Credits: Evolution X, LineageOS, the garnet maintainers, Xiaomi (ruan-u-oss sources)

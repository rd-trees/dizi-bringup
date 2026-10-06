# Evolution X 12.2 (Android 17) – Redmi Pad Pro (dizi) – second unofficial release

An update to the first Android 17 release (2026-09-29): an Evolution X sync with the October security
patch, smoother transitions, and a pen that now does pressure and hover properly.

## New in this release

- **Evolution X sync, Android security patch 2026-10-01.** The Google apps come from the new DP11 drop.
  The *Wallpaper & style* app stays at the previous version: the new one needs framework code this
  build doesn't have yet, and crashed (taking the home screen down with it during boot).
- **Smoother Recents and app transitions.**
  - The rounded screen corners are now drawn by the display hardware instead of the GPU.
  - The GPU clocks up while the compositor has to use it.
  - The CPU scheduler uses the stock HyperOS settings.
  - Opening an app from Recents in landscape: the launcher drops about 3–3.5% of frames, the display
    about 8%.
- **Wallpaper keeps the right orientation** after rotating, after a restart and when booting in
  landscape.
- **Video inside apps looks right.** Instagram Reels and other in-app players that decode video in
  software (all AV1 on this tablet, and some VP8/VP9) showed coloured stripes and garbled frames. The
  GPU driver is updated to Adreno V@0863.1, which draws these frames correctly.
- **Smooth playback with "Hey Google" on.** With Voice Match enabled, any video or music made the
  audio service restart every few seconds, so video stuttered. "Hey Google" now keeps listening on the
  low-power microphone path while media plays, and the audio service stays up.
- **Redmi Smart Pen:**
  - **Pressure sensitivity** works. The pen sends its pressure over Bluetooth, and the ROM now feeds
    it to the touch driver as HyperOS does.
  - **Hover works.** Hovering shows labels and tooltips and no longer counts as a tap.
  - **Pairing is reliable.** The pen pairs automatically after boot, and no longer unpairs itself
    when it goes idle.
  - **POCO Smart Pen** is supported too.
  - The pen no longer floods apps with stray key presses.
  - The "Always enable pen input" switch in Settings no longer crashes.

## Install

See INSTALL.md.
- **Updating from the first Android 17 release:** sideload the zip in recovery, or run
  `./flash-dizi.sh --keep` from the fastboot package. Your data stays.
- **Coming from Android 16 builds, a different ROM, or HyperOS:** this is a clean install. Format data in
  recovery.
- **Never relock the bootloader.**

## Known issues

- **A "Select USB mode" chooser can appear after boot** when a cable is connected. Close it, or pick a mode.
- **The dock row moves up a few pixels** at the end of the animation when going home. This comes from the
  Pixel Launcher's own animation.
- **Recents still drops some frames while zooming into an app.** Rounded, scaled app windows have to be
  composed by the GPU.
- Please report anything odd with `collect-logs`.

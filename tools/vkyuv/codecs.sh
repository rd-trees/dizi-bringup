#!/system/bin/sh
# Every decoder against every clip it can play, frame 10 of each.
d=/data/local/tmp/vkyuv
c=$d/clips
t() { for f in "$@"; do $d/vkyuv codec $c/$f $dec 10 | grep -v '^# Adreno'; done; }
dec=c2.android.avc.decoder;       t h264-540x960.mp4 h264-720x1280.mp4 h264-854x480.mp4 h264-1080x1920.mp4
dec=c2.android.hevc.decoder;      t hevc-540x960.mp4 hevc-720x1280.mp4 hevc-854x480.mp4 hevc-1080x1920.mp4 hevc10-540x960.mp4
dec=c2.android.vp8.decoder;       t vp8-540x960.webm vp8-720x1280.webm vp8-854x480.webm vp8-1080x1920.webm
dec=c2.android.vp9.decoder;       t vp9-540x960.webm vp9-720x1280.webm vp9-854x480.webm vp9-1080x1920.webm vp9p2-540x960.webm
dec=c2.android.av1-dav1d.decoder; t av1-540x960.mp4 av1-720x1280.mp4 av1-854x480.mp4 av1-1080x1920.mp4 av1p10-720x1280.mp4
dec=c2.android.av1.decoder;       t av1-540x960.mp4 av1-854x480.mp4 av1p10-720x1280.mp4
dec=c2.android.mpeg4.decoder;     t mpeg4-352x288.mp4 mpeg4-540x960.mp4
dec=c2.android.h263.decoder;      t h263-352x288.3gp h263-704x576.3gp
dec=c2.qti.avc.decoder;           t h264-540x960.mp4 h264-854x480.mp4 h264-1080x1920.mp4
dec=c2.qti.hevc.decoder;          t hevc-540x960.mp4 hevc-1080x1920.mp4 hevc10-540x960.mp4
dec=c2.qti.vp9.decoder;           t vp9-540x960.webm vp9-854x480.webm vp9p2-540x960.webm

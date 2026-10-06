#!/bin/bash
# Make the vkyuv test clips on the Mac: 30 frames of testsrc2 per codec and size.
set -e
export PATH=/opt/homebrew/bin:$PATH
d=~/dizi/vkyuv-clips; mkdir -p $d; cd $d
src() { echo "-f lavfi -i testsrc2=size=$1:rate=30:duration=1"; }
enc() { # name size args...
	local n=$1 s=$2; shift 2
	[ -f "$n" ] || ffmpeg -nostdin -hide_banner -loglevel error -y $(src $s) "$@" "$n"
}
for s in 540x960 720x1280 854x480 1080x1920; do
	enc h264-$s.mp4 $s -c:v libx264 -pix_fmt yuv420p -profile:v high -g 30
	enc vp8-$s.webm $s -c:v libvpx -pix_fmt yuv420p -b:v 4M
	enc vp9-$s.webm $s -c:v libvpx-vp9 -pix_fmt yuv420p -b:v 4M -row-mt 1
	enc av1-$s.mp4 $s -c:v libsvtav1 -pix_fmt yuv420p -preset 10
	enc hevc-$s.mp4 $s -c:v libx265 -pix_fmt yuv420p -tag:v hvc1 -x265-params log-level=error
done
enc mpeg4-352x288.mp4 352x288 -c:v mpeg4 -q:v 3
enc mpeg4-540x960.mp4 540x960 -c:v mpeg4 -q:v 3
enc h263-352x288.3gp 352x288 -c:v h263 -q:v 3
enc h263-704x576.3gp 704x576 -c:v h263 -q:v 3
enc hevc10-540x960.mp4 540x960 -c:v libx265 -pix_fmt yuv420p10le -profile:v main10 -tag:v hvc1 -x265-params log-level=error
enc vp9p2-540x960.webm 540x960 -c:v libvpx-vp9 -pix_fmt yuv420p10le -profile:v 2 -b:v 4M
enc av1p10-720x1280.mp4 720x1280 -c:v libsvtav1 -pix_fmt yuv420p10le -preset 10
ls $d

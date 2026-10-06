#!/system/bin/sh
# run.sh stock|new <command...>: "new" runs with V@0863.1 as /vendor/lib64 for this process only:
# a private mount namespace binds a tmpfs copy of /vendor/lib64 with the new driver on top
# (overlayfs over /vendor/lib64 isn't supported here). Busybox unshare, with private
# propagation: toybox unshare keeps it shared, and the mounts landed in init's namespace.
d=/data/local/tmp/vkyuv
mode=$1; shift
if [ "$mode" = new ]; then
	exec /data/adb/ksu/bin/busybox unshare -m --propagation private sh -c "mount -t tmpfs tmpfs /mnt && cp -a /vendor/lib64 /mnt/ && cp -a $d/drv/lib64/. /mnt/lib64/ &&
		mount --bind /mnt/lib64 /vendor/lib64 && exec $*"
fi
exec "$@"

# Device-side helpers (POSIX sh), embedded by knobs.sh and gpu-driver.sh. Run as root.
#
# init switches between its bootstrap mount namespace (early HALs such as power, vold) and the
# default one (surfaceflinger, the composer; zygote copies it). /vendor is a shared mount, so a bind
# mount made in one usually propagates to the other, but not always to every copy. So check each
# namespace: bind where the target isn't already the source, and unmount until nothing is left.

# The distinct mount namespaces of init, surfaceflinger and vold, as one pid each.
ns_pids() {
	seen=
	for p in 1 $(pidof surfaceflinger) $(pidof vold); do
		n=$(readlink /proc/$p/ns/mnt)
		case " $seen " in *" $n "*) continue ;; esac
		seen="$seen $n"
		echo $p
	done
}

# nsbind <src> <dst>: <dst> shows <src> in every namespace; fails if one doesn't.
nsbind() {
	want=$(stat -c %d:%i "$1")
	rc=0
	for p in $(ns_pids); do
		[ "$(nsenter -t $p -m -- stat -c %d:%i "$2")" = "$want" ] && continue
		nsenter -t $p -m -- mount -o bind "$1" "$2"
		[ "$(nsenter -t $p -m -- stat -c %d:%i "$2")" = "$want" ] || rc=1
	done
	return $rc
}

# nsunbind <dst>: remove every bind mount on <dst>, stacked ones included. Lazy, since a library
# that running processes have mapped is busy; they keep it until they restart.
nsunbind() {
	for p in $(ns_pids); do
		i=0
		while [ $i -lt 8 ] && nsenter -t $p -m -- umount -l "$1" 2>/dev/null; do i=$((i + 1)); done
	done
}

# nsmounted <dst>: <dst> has a bind mount in some namespace.
nsmounted() {
	for p in $(ns_pids); do
		awk -v d="$1" '$5 == d {f = 1} END {exit !f}' /proc/$p/mountinfo && return 0
	done
	return 1
}

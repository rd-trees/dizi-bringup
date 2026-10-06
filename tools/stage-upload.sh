#!/bin/bash
# Copy a signed release to the Mac for uploading: $DIZI_REMOTE_DIR/upload/<release name>/ with the
# recovery zip, the fastboot zip, their .sha256, boot/dtbo/recovery/vendor_boot, INSTALL.md and, for
# dizi, RELEASE_NOTES.md. Our working prefix (e.g. "cnb-release-16-") is dropped from the file names,
# so they carry the build's own release name, and the .sha256 is rewritten to match.
# Usage: [DEVICE=dizi|ruan] tools/stage-upload.sh <release/out dir name>
set -euo pipefail
. "$(dirname "$0")/env"
dir=${1:?release/out dir name}
src=$DIZI_ROOT/release/out/$dir
[[ -d $src ]] || { echo "no $src" >&2; exit 1; }
# The release name: EvolutionX-<android>-<date>-<device>-<evo>-Unofficial.
name=$(grep -oE 'EvolutionX-[^ ]+-Unofficial' <<<"$dir" | head -1)
[[ -n $name ]] || { echo "no release name in $dir" >&2; exit 1; }
dst=$DIZI_REMOTE_DIR/upload/$name

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
for f in boot.img dtbo.img recovery.img vendor_boot.img; do
	ln -s "$src/$f" "$stage/$f"
done
ln -s "$src/$dir.zip" "$stage/$name.zip"
ln -s "$src/$dir-fastboot.zip" "$stage/$name-fastboot.zip"
sed "s/$dir/$name/g" "$src/$dir.sha256" >"$stage/$name.sha256"
cp "$src/images/INSTALL.md" "$stage/INSTALL.md"
if [[ $DIZI_DEVICE == dizi ]]; then
	notes=$DIZI_ROOT/release/RELEASE_NOTES.md
	[[ $dir == *-17.0-* ]] && notes=$DIZI_ROOT/release/RELEASE_NOTES-cnb.md
	cp "$notes" "$stage/RELEASE_NOTES.md"
fi

ssh -i "$DIZI_SSH_KEY" "$DIZI_HOST" "mkdir -p '$dst'"
rsync -e "ssh -i $DIZI_SSH_KEY" -rLt --partial --info=progress2 "$stage"/ "$DIZI_HOST:$dst/"
# Verify against the checksums of the originals.
(cd "$stage" && sha256sum -- *.img *.zip) | sort -k2 >"$stage/local.sum"
ssh -i "$DIZI_SSH_KEY" "$DIZI_HOST" "cd '$dst' && shasum -a 256 *.img *.zip" | sort -k2 >"$stage/remote.sum"
if diff -q "$stage/local.sum" "$stage/remote.sum" >/dev/null; then
	echo "staged and verified: $dst"
	ssh -i "$DIZI_SSH_KEY" "$DIZI_HOST" "ls -la '$dst'"
else
	echo "FAILED: checksums differ in $dst" >&2
	diff "$stage/local.sum" "$stage/remote.sum" >&2 || true
	exit 1
fi

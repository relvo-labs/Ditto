#!/usr/bin/env bash
# Install fallback EFI and read back the pristine image. Run in a disposable builder.
set -euo pipefail
[[ $# -ge 1 ]] || { echo 'usage: finish-image.sh BUILD_DIRECTORY [--forbid LITERAL ...]' >&2; exit 2; }
[[ "$EUID" == 0 ]] || { echo 'root in the disposable image builder is required' >&2; exit 1; }
here="$(cd "$(dirname "$0")" && pwd)"
build_dir="$(realpath "$1")"
shift
image="$build_dir/out/ditto.raw"
[[ -f "$image" ]]
mount_dir="$(mktemp -d)"
loop_device="$(losetup --find --show --partscan "$image")"
cleanup() {
    local failed=0
    for path in "$mount_dir/boot" "$mount_dir/usr" "$mount_dir"; do
        if mountpoint -q "$path"; then umount "$path" || failed=1; fi
    done
    losetup -d "$loop_device" || failed=1
    rmdir "$mount_dir" || failed=1
    return "$failed"
}
trap cleanup EXIT
# Fail before writing if the fixed repart order/labels do not match.
[[ "$(blkid -s PARTLABEL -o value "${loop_device}p1")" == ditto-esp ]]
[[ "$(blkid -s PARTLABEL -o value "${loop_device}p2")" == ditto-state ]]
[[ "$(blkid -s PARTLABEL -o value "${loop_device}p3")" == ditto-usr-* ]]
[[ "$(blkid -s PARTLABEL -o value "${loop_device}p4")" == _empty ]]
mount "${loop_device}p2" "$mount_dir"
mount -o ro "${loop_device}p3" "$mount_dir/usr"
mount "${loop_device}p1" "$mount_dir/boot"
# tty conflict and bounded DRM readiness live in the generator, before splitting.
# No post-build /usr patch: split payloads must match the disk.
python3 "$here/apply-runtime.py" --root "$mount_dir" --runtime-lock "$mount_dir/usr/share/ditto/runtime-lock.json"
bootctl --root="$mount_dir" --esp-path=/boot --no-variables install
test -s "$mount_dir/boot/EFI/BOOT/BOOTX64.EFI"
find "$mount_dir/boot/EFI/Linux" -maxdepth 1 -name '*.efi' -type f -print -quit | grep -q .
dpkg-query --admindir="$mount_dir/var/lib/dpkg" -W > "$build_dir/out/packages.tsv"
python3 "$here/scan-pristine-rootfs.py" "$mount_dir" --forbid "$build_dir" "$@" > "$build_dir/out/pristine-scan.json"
sync
cleanup
trap - EXIT
sha256sum "$image" > "$build_dir/out/disk.sha256"

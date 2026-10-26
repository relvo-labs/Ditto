#!/usr/bin/env bash
# mkosi FinalizeScripts hook for the #221 installer image. Only the build root
# is changed. The image runs from RAM as the initrd of its own UKI.
set -euo pipefail
root="${BUILDROOT:?mkosi BUILDROOT is required}"
[[ "$root" == /* && "$root" != / ]]
# A full OS inside the UKI initrd: with initrd-release systemd would try to
# switch root and find none. Fail the build rather than ship that.
if [[ -e "$root/etc/initrd-release" || -L "$root/etc/initrd-release" ]]; then
    echo 'installer image must not contain etc/initrd-release' >&2
    exit 1
fi
commit="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source_commit"])' "$root/usr/share/ditto/image-inputs.json")"
printf '\nDITTO_SOURCE_COMMIT=%s\nDITTO_IMAGE_ROLE=installer\n' "$commit" >> "$root/usr/lib/os-release"
printf 'ditto-installer\n' > "$root/etc/hostname"
printf 'LANG=C.UTF-8\n' > "$root/etc/locale.conf"
# No machine identity, keys or seed; no accounts besides locked system users.
rm -f "$root"/etc/ssh/ssh_host_*key* "$root/var/lib/systemd/random-seed"
truncate -s 0 "$root/etc/machine-id"
chroot "$root" usermod --lock root
chroot "$root" systemctl enable ditto-installer-backend.service ditto-installer-text.service
chroot "$root" systemctl mask getty@tty1.service systemd-firstboot.service
chroot "$root" systemctl set-default multi-user.target

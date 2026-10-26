#!/usr/bin/env bash
# mkosi FinalizeScripts hook. Only the build root is changed.
set -euo pipefail
root="${BUILDROOT:?mkosi BUILDROOT is required}"
[[ "$root" == /* && "$root" != / ]]
source_dir="${SRCDIR:?mkosi SRCDIR is required}"
# ExtraTrees contains only source/config. Preflight target ownership before payload copy.
python3 "$source_dir/apply-runtime.py" --root "$root" \
    --runtime-tree "$source_dir/runtime" --runtime-lock "$root/usr/share/ditto/runtime-lock.json"
commit="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source_commit"])' "$root/usr/share/ditto/image-inputs.json")"
printf '\nDITTO_SOURCE_COMMIT=%s\n' "$commit" >> "$root/usr/lib/os-release"
printf 'ditto\n' > "$root/etc/hostname"
printf 'LANG=C.UTF-8\n' > "$root/etc/locale.conf"
# The #221 installer sizes ditto-state to fill the disk; growfs then extends
# ext4 online. systemd 259 only hooks systemd-growfs-root.service from a host
# fstab "/" entry (the initrd ignores rootflags=x-systemd.growfs). No-op when
# the partition already matches the file system, e.g. a directly copied image.
printf '/dev/disk/by-partlabel/ditto-state / ext4 rw,x-systemd.growfs 0 0\n' > "$root/etc/fstab"
printf '/dev/disk/by-partlabel/ditto-esp /boot vfat umask=0077 0 2\n' >> "$root/etc/fstab"
ln -sfn /run/systemd/resolve/stub-resolv.conf "$root/etc/resolv.conf"
# python3-psutil (a Depends of orca) ships test modules; its postinst runs
# py3compile, which writes their bytecode. That bytecode is generated, not a
# package file, so the #205 exact-bytes fixtures cannot cover its upstream
# test paths, and nothing imports it. Drop only that generated directory (the
# package's own files stay) and fail the build if any test bytecode remains.
psutil_tests="$root/usr/lib/python3/dist-packages/psutil/tests"
rm -rf -- "$psutil_tests/__pycache__"
if [[ -e "$psutil_tests/__pycache__" || -L "$psutil_tests/__pycache__" ]] ||
        { [[ -d "$psutil_tests" ]] && [[ -n "$(find "$psutil_tests" -name '*.pyc' -print -quit)" ]]; }; then
    echo 'psutil test bytecode is still in the image' >&2
    exit 1
fi
# Package postinst may generate these. Ship no machine-specific host keys/seed.
rm -f "$root"/etc/ssh/ssh_host_*key* "$root/var/lib/systemd/random-seed"
truncate -s 0 "$root/etc/machine-id"
rm -f "$root/var/lib/dbus/machine-id"
ln -s /etc/machine-id "$root/var/lib/dbus/machine-id"
chroot "$root" usermod --lock root
# Provisioning belongs to D06: no installed user, password, SSH client key,
# passwordless sudo or autologin is created here. SSH is opt-in after setup.
chroot "$root" systemctl disable ssh.service ssh.socket
chroot "$root" systemctl disable systemd-sysupdate.timer systemd-sysupdate-reboot.timer
chroot "$root" systemctl enable ditto-ssh-keygen.service systemd-networkd systemd-resolved greetd
# TODO_FIRSTBOOT_ACCOUNT_PR_A: generator activates this only with all artifacts.
if [[ -f "$root/usr/lib/systemd/system/ditto-firstboot-account.socket" ]]; then
    test -x "$root/usr/lib/ditto/ditto-firstboot-account"
    test -x "$root/usr/lib/ditto/ditto-firstboot-tty"
    # Remove the obsolete hard dependency only inside the new image root.
    rm -f "$root/etc/systemd/system/greetd.service.requires/ditto-firstboot-account-recover.service"
    chroot "$root" systemctl enable ditto-firstboot-account.socket ditto-firstboot-account-recover.service ditto-firstboot-tty-dispatch.socket
fi
ln -sfn /dev/null "$root/etc/systemd/system/systemd-firstboot.service"
chroot "$root" systemctl mask getty@tty1.service
if ! grep -q 'type=wayland' "$root/etc/pam.d/greetd"; then
    sed -i '1a session optional pam_systemd.so type=wayland desktop=Wayfire' "$root/etc/pam.d/greetd"
fi
chroot "$root" systemctl set-default graphical.target

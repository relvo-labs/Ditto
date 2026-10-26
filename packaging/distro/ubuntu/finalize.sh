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
# This runs on the builder, not in a chroot: every component from the image
# root down must be a real directory (no symlink anywhere), and the result must
# resolve inside the root, or nothing is deleted and the build fails.
psutil_rel=usr/lib/python3/dist-packages/psutil/tests/__pycache__
psutil_fail() { echo "psutil test bytecode: $1" >&2; exit 1; }
real_root="$(realpath -e -- "$root")" || psutil_fail 'cannot resolve the build root'
psutil_path="$root"
psutil_tests=
IFS=/ read -r -a psutil_parts <<< "$psutil_rel"
for part in "${psutil_parts[@]}"; do
    psutil_path="$psutil_path/$part"
    if [[ -L "$psutil_path" ]]; then
        psutil_fail "refusing to follow a symlink at ${psutil_path#"$root"/}"
    fi
    if [[ ! -e "$psutil_path" ]]; then
        psutil_path=
        break
    fi
    [[ -d "$psutil_path" ]] || psutil_fail "not a directory: ${psutil_path#"$root"/}"
    if [[ "$part" == tests ]]; then psutil_tests="$psutil_path"; fi
done
if [[ -n "$psutil_path" ]]; then
    [[ "$(realpath -e -- "$psutil_path")" == "$real_root/$psutil_rel" ]] ||
        psutil_fail 'path resolves outside the image root'
    rm -rf --one-file-system -- "$psutil_path"
    [[ ! -e "$psutil_path" && ! -L "$psutil_path" ]] || psutil_fail 'still in the image after removal'
fi
if [[ -n "$psutil_tests" ]]; then
    # A failed search is not a clean result.
    psutil_left="$(find "$psutil_tests" -name '*.pyc' -print -quit)" ||
        psutil_fail 'cannot check for leftovers (find failed)'
    [[ -z "$psutil_left" ]] || psutil_fail "still in the image: ${psutil_left#"$root"/}"
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

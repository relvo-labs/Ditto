#!/usr/bin/env bash
# Create the Ditto G0 development VM on this host's libvirt, then provision it.
# Everything it needs lives in the VM or under ~/.config/ditto-vm; the host's
# own session and packages are not touched. Results from this VM are
# development evidence only (plan/02/01, D-01).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

image_url=https://cloud-images.ubuntu.com/releases/noble/release
cache="$HOME/.cache/ditto-vm"
image="$cache/noble-server-cloudimg-amd64.img"

if virsh_vm dominfo "$VM_NAME" >/dev/null 2>&1; then
  echo "$VM_NAME already exists; remove it with virsh undefine --remove-all-storage --snapshots-metadata first" >&2
  exit 1
fi

mkdir -p "$cache" "$VM_STATE"
chmod 700 "$VM_STATE"
curl -fsSL -o "$cache/SHA256SUMS" "$image_url/SHA256SUMS"
[[ -f "$image" ]] || curl -fsSL -o "$image" "$image_url/ubuntu-24.04-server-cloudimg-amd64.img"
expected="$(awk '/\*ubuntu-24.04-server-cloudimg-amd64.img$/{print $1}' "$cache/SHA256SUMS")"
echo "$expected  $image" | sha256sum -c --quiet

[[ -f "$VM_KEY" ]] || ssh-keygen -q -t ed25519 -N '' -C "$VM_NAME" -f "$VM_KEY"
[[ -f "$VM_STATE/password" ]] || { head -c 18 /dev/urandom | base64 | tr -d '/+=' >"$VM_STATE/password"; }
chmod 600 "$VM_STATE/password"

packages="$(grep -vE '^\s*(#|$)' "$WORKSPACE/packaging/reference-image/apt-packages.txt" | tr '\n' ' ')"
sed -e "s|@PASSWORD_HASH@|$(openssl passwd -6 -stdin <"$VM_STATE/password")|" \
  -e "s|@SSH_KEY@|$(cat "$VM_KEY.pub")|" -e "s|@PACKAGES@|$packages|" \
  "$DEV_VM_DIR/user-data.in" >"$VM_STATE/user-data"
printf 'instance-id: %s-1\nlocal-hostname: %s\n' "$VM_NAME" "$VM_NAME" >"$VM_STATE/meta-data"

virsh_vm pool-info default >/dev/null 2>&1 || {
  virsh_vm pool-define-as default dir --target /var/lib/libvirt/images >/dev/null
  virsh_vm pool-build default >/dev/null 2>&1 || true
  virsh_vm pool-start default >/dev/null
  virsh_vm pool-autostart default >/dev/null
}
virsh_vm vol-info --pool default noble-base.qcow2 >/dev/null 2>&1 || {
  virsh_vm vol-create-as default noble-base.qcow2 "$(stat -c %s "$image")" --format qcow2 >/dev/null
  virsh_vm vol-upload --pool default noble-base.qcow2 "$image"
}
virsh_vm vol-create-as default "$VM_NAME.qcow2" 60G --format qcow2 \
  --backing-vol /var/lib/libvirt/images/noble-base.qcow2 --backing-vol-format qcow2 >/dev/null

virt-install --connect "$VM_CONNECT" --name "$VM_NAME" --memory 8192 --vcpus 4 --cpu host-passthrough \
  --osinfo ubuntu24.04 --disk vol="default/$VM_NAME.qcow2",bus=virtio --import \
  --network network=default,model=virtio --graphics vnc,listen=127.0.0.1 --video virtio \
  --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 \
  --cloud-init user-data="$VM_STATE/user-data",meta-data="$VM_STATE/meta-data" --noautoconsole

vm_wait_ssh
echo 'waiting for cloud-init to finish installing packages'
vm_ssh 'cloud-init status --wait >/dev/null; test -f /var/log/ditto-apt.done'
exec bash "$DEV_VM_DIR/provision.sh"

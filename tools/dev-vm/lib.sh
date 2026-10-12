#!/usr/bin/env bash
# Shared helpers for the Ditto G0 development VM (libvirt domain ditto-g0-vm).

VM_NAME="${DITTO_VM_NAME:-ditto-g0-vm}"
VM_CONNECT="qemu:///system"
VM_STATE="${DITTO_VM_STATE:-$HOME/.config/ditto-vm}"
VM_KEY="$HOME/.ssh/ditto-vm_ed25519"
VM_SNAPSHOT="${DITTO_VM_SNAPSHOT:-ditto-base}"
DEV_VM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$DEV_VM_DIR/../.." && pwd)"
# The frozen toolchain on PATH inside the VM, the same prefixes as the host.
VM_ENV='export PATH=$HOME/.cargo/bin:$HOME/.nvm/versions/node/v22.23.2/bin:$HOME/Qt/6.10.2/gcc_64/bin:$HOME/wayfire/bin:$PATH LD_LIBRARY_PATH=$HOME/wayfire/lib XDG_RUNTIME_DIR=/run/user/1000; cd ~/funlab/Ditto;'

virsh_vm() { virsh -c "$VM_CONNECT" "$@"; }

# A reverted snapshot keeps the DHCP lease it was taken with, which the host's
# dnsmasq forgets once it expires: the lease table then has no address while
# the guest still uses it. ARP and the guest agent see it either way.
vm_ip() {
  local source ip
  for source in lease arp agent; do
    ip="$(virsh_vm domifaddr "$VM_NAME" --source "$source" 2>/dev/null |
      awk '$3 == "ipv4" && $4 !~ /^127\./ {print $4}' | cut -d/ -f1 | head -1)"
    [[ -n "$ip" ]] && { echo "$ip"; return 0; }
  done
  return 1
}

vm_ssh() {
  ssh -i "$VM_KEY" -o UserKnownHostsFile="$VM_STATE/known_hosts" -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=5 -o BatchMode=yes neil@"$(vm_ip)" "$@"
}

vm_rsync() {
  rsync -a -e "ssh -i $VM_KEY -o UserKnownHostsFile=$VM_STATE/known_hosts -o StrictHostKeyChecking=accept-new -o BatchMode=yes" "$@"
}

vm_wait_ssh() {
  local _
  for _ in $(seq 1 120); do
    [[ -n "$(vm_ip)" ]] && vm_ssh true 2>/dev/null && return 0
    sleep 3
  done
  echo "the VM did not accept SSH" >&2
  return 1
}

# Wait for a login started by the Ditto session script: all four layer scopes.
vm_wait_desktop() {
  local _
  for _ in $(seq 1 60); do
    vm_ssh 'XDG_RUNTIME_DIR=/run/user/1000 systemctl --user is-active --quiet ditto-g0-wayfire.scope ditto-g0-core.scope ditto-g0-quickshell.scope ditto-g0-fcitx.scope' 2>/dev/null && return 0
    sleep 3
  done
  echo "no Ditto G0 login appeared in the VM" >&2
  return 1
}

# Snapshots older than the package list lack its newer build packages;
# install its build section (everything after the "Build" header).
vm_build_packages() {
  local packages
  packages="$(sed -n '/^# Build and diagnostic tools/,$p' "$WORKSPACE/packaging/reference-image/apt-packages.txt" | grep -vE '^[[:space:]]*(#|$)' | tr '\n' ' ')"
  vm_ssh "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q $packages"
}

vm_sync_workspace() {
  vm_rsync --delete --exclude target --exclude artifacts --exclude node_modules \
    "$WORKSPACE/" neil@"$(vm_ip)":funlab/Ditto/
}

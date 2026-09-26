#!/usr/bin/env bash
# Put the frozen G0 toolchain and the Ditto session into the VM, turn on GDM
# autologin into "Ditto G0 (Wayfire)", and save the result as the snapshot
# every test run starts from.
#
# Wayfire, Qt/Quickshell and Node are copied from this host's frozen prefixes
# rather than rebuilt, so the VM runs the same binaries. Rebuilding from
# source-builds.lock is the second-person rebuild, which stays a separate task.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

vm_wait_ssh
ip="$(vm_ip)"
vm_ssh 'mkdir -p ~/Qt/6.10.2 ~/.nvm/versions/node ~/funlab'
vm_rsync "$HOME/wayfire" neil@"$ip":
vm_rsync "$HOME/Qt/6.10.2/gcc_64" neil@"$ip":Qt/6.10.2/
vm_rsync "$HOME/.nvm/versions/node/v22.23.2" neil@"$ip":.nvm/versions/node/
vm_rsync /usr/local/lib/libcpptrace.so* neil@"$ip":/tmp/
vm_sync_workspace

vm_ssh bash -s <<'EOF'
set -euo pipefail
sudo cp -a /tmp/libcpptrace.so* /usr/local/lib/ && sudo ldconfig
sudo snap refresh --hold firefox >/dev/null
[[ -x ~/.cargo/bin/rustc ]] ||
  curl -fsSL https://sh.rustup.rs | sh -s -- -y -q --profile minimal --default-toolchain 1.98.1
export PATH=$HOME/.cargo/bin:$HOME/.nvm/versions/node/v22.23.2/bin:$HOME/Qt/6.10.2/gcc_64/bin:$HOME/wayfire/bin:$PATH
export LD_LIBRARY_PATH=$HOME/wayfire/lib
cd ~/funlab/Ditto
missing="$( (ldd ~/wayfire/bin/wayfire; ldd ~/Qt/6.10.2/gcc_64/bin/quickshell) | grep 'not found' || true)"
[[ -z "$missing" ]] || { echo "libraries missing from apt-packages.txt: $missing" >&2; exit 1; }
cargo build -q --locked --workspace --bins
bash packaging/reference-image/install-session.sh --development
sudo python3 - <<'PY'
import configparser
path = "/etc/gdm3/custom.conf"
config = configparser.ConfigParser(strict=False)
config.optionxform = str
config.read(path)
if "daemon" not in config:
    config.add_section("daemon")
config["daemon"].update({"AutomaticLoginEnable": "True", "AutomaticLogin": "neil", "WaylandEnable": "true"})
with open(path, "w") as handle:
    config.write(handle)
PY
sudo install -d /var/lib/AccountsService/users
printf '[User]\nSession=ditto-g0\nSystemAccount=false\n' | sudo tee /var/lib/AccountsService/users/neil >/dev/null
sudo systemctl restart accounts-daemon
sudo systemctl restart gdm
EOF

vm_wait_desktop
# virt-install deletes the cloud-init ISO after the first boot; a snapshot that
# still names it cannot be reverted.
virsh_vm change-media "$VM_NAME" sda --eject --live --config --force >/dev/null 2>&1 || true
virsh_vm snapshot-delete "$VM_NAME" "$VM_SNAPSHOT" >/dev/null 2>&1 || true
virsh_vm snapshot-create-as "$VM_NAME" "$VM_SNAPSHOT" \
  --description "frozen G0 prefixes, Ditto session installed, GDM autologin to ditto-g0" --atomic >/dev/null
echo "$VM_NAME provisioned; snapshot $VM_SNAPSHOT saved"

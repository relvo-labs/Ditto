#!/usr/bin/env bash
# Reject evidence from a machine whose frozen identity or toolchain drifted.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
lock="$here/reference-machine.lock.json"
current="$(mktemp /tmp/ditto-reference-current.XXXXXX)"
trap 'rm -f -- "$current"' EXIT

for command in jq nvidia-smi qmake6 quickshell wayfire rustc node pnpm fcitx5; do
  command -v "$command" >/dev/null || {
    echo "reference-machine preflight: missing $command" >&2
    exit 1
  }
done

bash "$here/capture-fingerprint.sh" "$current" >/dev/null

compare() {
  local locked_path="$1" current_path="$2" label="$3"
  local expected actual
  expected="$(jq -r "$locked_path" "$lock")"
  actual="$(jq -r "$current_path" "$current")"
  if [[ "$expected" != "$actual" ]]; then
    echo "reference-machine preflight: $label drifted: expected '$expected', got '$actual'" >&2
    return 1
  fi
}

compare '.platform.os' '.platform.os' os
compare '.platform.kernel' '.platform.kernel' kernel
compare '.platform.architecture' '.platform.architecture' architecture
compare '.platform.systemd' '.platform.systemd' systemd
compare '.platform.landlock_abi' '.platform.landlock_abi' landlock-abi
compare '.platform.cgroup_controllers' '.platform.cgroup_controllers' cgroup-controllers
compare '.platform.bubblewrap' '.platform.bubblewrap' bubblewrap
compare '.hardware.cpu' '.hardware.cpu' cpu
compare '.hardware.physical_cores' '.hardware.physical_cores' physical-core-count
compare '.hardware.logical_cpus' '.hardware.logical_cpus' logical-cpu-count
compare '.hardware.memory_kib' '.hardware.memory_kib' memory
compare '.hardware.storage' '.hardware.storage' storage
compare '.hardware.gpu' '.hardware.gpu' gpu
compare '.hardware.gpu_memory_mib' '.hardware.gpu_memory_mib' gpu-memory
compare '.hardware.gpu_driver' '.hardware.gpu_driver' gpu-driver
compare '.desktop.wayfire' '.desktop.wayfire' wayfire
compare '.desktop.qt' '.desktop.qt' qt
compare '.desktop.quickshell' '.desktop.quickshell' quickshell
compare '.desktop.fcitx' '.desktop.fcitx' fcitx
compare '.toolchain.rust' '.toolchain.rust' rust
compare '.toolchain.node' '.toolchain.node' node
compare '.toolchain.pnpm' '.toolchain.pnpm' pnpm
compare '.reference_applications.browser | sub("^firefox-snap-"; "")' '.reference_applications.browser' firefox
compare '.reference_applications.terminal | sub("^foot-"; "")' '.reference_applications.terminal' foot
compare '.reference_applications.editor | sub("^kate-"; "")' '.reference_applications.editor' kate

echo "reference-machine preflight passed: $(jq -r .reference_machine_id "$lock")"

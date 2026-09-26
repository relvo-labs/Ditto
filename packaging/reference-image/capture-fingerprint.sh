#!/usr/bin/env bash
# Emit the non-secret platform fingerprint used to accept or reject G0 exit
# evidence. The output path defaults to stdout; pass a path to save an artifact.
set -euo pipefail

destination="${1:--}"
temporary="$(mktemp /tmp/ditto-reference-fingerprint.XXXXXX)"
trap 'rm -f -- "$temporary"' EXIT

version_line() {
  "$@" 2>&1 | head -1
}

os="$(. /etc/os-release; echo "$PRETTY_NAME")"
cpu="$(lscpu -J | jq -r '.lscpu[] | select(.field == "Model name:") | .data')"
physical_cores="$(lscpu -J | jq -r '[.lscpu[] | select(.field == "Core(s) per socket:") | .data][0]')"
logical_cpus="$(getconf _NPROCESSORS_ONLN)"
memory_kib="$(awk '/MemTotal:/{print $2}' /proc/meminfo)"
storage="$(lsblk -dn -o MODEL,TYPE | awk '$NF == "disk" {$NF=""; sub(/[[:space:]]+$/, ""); print; exit}')"
gpu_line="$(nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || true)"
gpu="$(cut -d, -f1 <<<"$gpu_line" | xargs)"
gpu_driver="$(cut -d, -f2 <<<"$gpu_line" | xargs)"
gpu_memory="$(cut -d, -f3 <<<"$gpu_line" | xargs)"
wayfire_version="$(version_line wayfire --version | awk '{print $1}')"
quickshell_version="$(version_line quickshell --version)"
qt_version="$(qmake6 -query QT_VERSION 2>/dev/null || true)"
firefox_version="$(snap list firefox 2>/dev/null | awk 'NR==2 {print $2 "-rev" $3}')"
landlock_abi="$(python3 -c "
import ctypes
libc = ctypes.CDLL('libc.so.6', use_errno=True)
value = libc.syscall(444, None, 0, 1)
print(value if value > 0 else 0)
")"
cgroup_controllers="$(tr '\n' ' ' </sys/fs/cgroup/cgroup.controllers | xargs)"

jq -n \
  --arg captured_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg os "$os" \
  --arg kernel "$(uname -r)" \
  --arg architecture "$(uname -m)" \
  --arg systemd "$(systemctl --version | awk 'NR==1 {gsub(/[()]/, "", $3); split($3, parts, "-"); print parts[1]}')" \
  --argjson landlock_abi "$landlock_abi" \
  --arg cgroup_controllers "$cgroup_controllers" \
  --arg bubblewrap "$(bwrap --version | awk '{print $2}')" \
  --arg cpu "$cpu" \
  --argjson physical_cores "$physical_cores" \
  --argjson logical_cpus "$logical_cpus" \
  --argjson memory_kib "$memory_kib" \
  --arg storage "$storage" \
  --arg gpu "$gpu" \
  --arg gpu_driver "$gpu_driver" \
  --argjson gpu_memory_mib "${gpu_memory:-0}" \
  --arg wayfire "$wayfire_version" \
  --arg qt "$qt_version" \
  --arg quickshell "$(sed -n 's/^Quickshell \([^ ]*\) (revision \([^,)]*\).*/\1-\2/p' <<<"$quickshell_version")" \
  --arg fcitx "$(fcitx5 --version 2>&1 | head -1)" \
  --arg rust "$(rustc --version | awk '{print $2}')" \
  --arg node "$(node --version | sed 's/^v//')" \
  --arg pnpm "$(pnpm --version)" \
  --arg firefox "$firefox_version" \
  --arg foot "$(dpkg-query -W -f='${Version}' foot)" \
  --arg kate "$(dpkg-query -W -f='${Version}' kate)" \
  '{
    captured_at: $captured_at,
    platform: {
      os: $os, kernel: $kernel, architecture: $architecture, systemd: $systemd,
      landlock_abi: $landlock_abi, cgroup_controllers: $cgroup_controllers,
      bubblewrap: $bubblewrap
    },
    hardware: {
      cpu: $cpu, physical_cores: $physical_cores, logical_cpus: $logical_cpus,
      memory_kib: $memory_kib, storage: $storage,
      gpu: $gpu, gpu_memory_mib: $gpu_memory_mib, gpu_driver: $gpu_driver
    },
    desktop: {wayfire: $wayfire, qt: $qt, quickshell: $quickshell, fcitx: $fcitx},
    toolchain: {rust: $rust, node: $node, pnpm: $pnpm},
    reference_applications: {browser: $firefox, terminal: $foot, editor: $kate}
  }' >"$temporary"

if [[ "$destination" == "-" ]]; then
  cat "$temporary"
else
  cp "$temporary" "$destination"
  echo "fingerprint -> $destination"
fi

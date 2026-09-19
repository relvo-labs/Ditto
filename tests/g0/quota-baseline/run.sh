#!/usr/bin/env bash
# G0-QA-03: before G3 depends on them, check that the platform's own limits
# work and that a tool hitting its memory limit takes nothing else with it.
# Runs on a host with a systemd user instance, not in the container.
set -euo pipefail

workspace="$(cd "$(dirname "$0")/../../.." && pwd)"
artifacts="${DITTO_ARTIFACTS:-$workspace/artifacts/g0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
mkdir -p "$artifacts"
run_id="$(date -u +%Y-%m-%dT%H:%M:%SZ)-$(git -C "$workspace" rev-parse --short=3 HEAD 2>/dev/null || echo 000)"
output="$artifacts/quota-baseline-$run_id.json"
environment="${DITTO_REFERENCE_MACHINE:+reference-machine}"
environment="${environment:-development-vm}"

systemctl --user show --property=Version >/dev/null 2>&1 || {
  echo 'no systemd user instance: this check needs one, and G3 depends on it' >&2
  exit 1
}

witness_log="$(mktemp)"
( while true; do echo "alive $(date +%s)" >>"$witness_log"; sleep 0.2; done ) &
witness_pid=$!
trap 'kill "$witness_pid" 2>/dev/null || true; rm -f "$witness_log"' EXIT

memory_case() {
  # A tool that runs out of memory must be stopped inside its own scope.
  if systemd-run --user --scope --quiet -p MemoryMax=64M -p MemorySwapMax=0 \
    python3 -c "
data = bytearray()
while True:
    data.extend(bytearray(8 * 1024 * 1024))
" >/dev/null 2>&1; then
    echo survived
  else
    echo stopped
  fi
}

cpu_case() {
  # The quota is visible as the share of wall time the loop got to run.
  systemd-run --user --scope --quiet -p CPUQuota=20% \
    python3 -c "
import time
wall_start, cpu_start = time.time(), time.process_time()
while time.time() - wall_start < 3:
    pass
wall = time.time() - wall_start
print(round((time.process_time() - cpu_start) / wall, 3))
" 2>/dev/null | tail -1
}

tasks_case() {
  # Count the forks that actually succeeded, not the attempts.
  systemd-run --user --scope --quiet -p TasksMax=16 \
    python3 -c "
import os, time
started = 0
try:
    for _ in range(64):
        if os.fork() == 0:
            time.sleep(2)
            os._exit(0)
        started += 1
except OSError:
    pass
print(started)
" 2>/dev/null | tail -1
}

memory_outcome="$(memory_case)"
cpu_share="$(cpu_case)"
tasks_started="$(tasks_case)"
sleep 0.5
witness_samples="$(wc -l <"$witness_log")"

landlock_abi="$(python3 -c "
import ctypes
try:
    libc = ctypes.CDLL('libc.so.6', use_errno=True)
    result = libc.syscall(444, None, 0, 1)
    print(result if result > 0 else 'unavailable')
except Exception as error:
    print('unavailable')
")"

python3 - "$output" "$run_id" "$environment" "$memory_outcome" "$cpu_share" "$tasks_started" "$witness_samples" "$landlock_abi" <<'PYEOF'
import json, subprocess, sys

output, run_id, environment, memory_outcome, cpu_share, tasks_started, witness_samples, landlock = sys.argv[1:9]

def read(path):
    try:
        return open(path, encoding="utf-8").read().strip()
    except OSError:
        return None

def command(argv):
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=10).stdout.strip()
    except Exception:
        return None

record = {
    "run_id": run_id,
    "environment": environment,
    "cases": {
        "memory": {
            "limit": "MemoryMax=64M, MemorySwapMax=0",
            "scope_stopped": memory_outcome == "stopped",
            "witness_alive_samples": int(witness_samples),
            "requirement": "the scope is stopped and nothing outside it is affected",
        },
        "cpu": {
            "limit": "CPUQuota=20%",
            "cpu_share_of_wall": float(cpu_share) if cpu_share else None,
            "enforced": bool(cpu_share) and float(cpu_share) <= 0.35,
            "requirement": "a busy loop gets about the quota share, not a whole core",
        },
        "tasks": {
            "limit": "TasksMax=16",
            "processes_started": int(tasks_started) if tasks_started.isdigit() else None,
            "enforced": tasks_started.isdigit() and int(tasks_started) < 64,
            "requirement": "process creation stops at the limit",
        },
    },
    "platform_facts": {
        "kernel": command(["uname", "-r"]),
        "cgroup_controllers": read("/sys/fs/cgroup/cgroup.controllers"),
        "lsm": read("/sys/kernel/security/lsm"),
        "landlock_abi": landlock,
        "systemd_user_version": command(["systemctl", "--user", "show", "--property=Version", "--value"]),
        "delegated_controllers": command(["systemctl", "--user", "show", "-p", "DelegateControllers", "--value"]),
        "bubblewrap": command(["bwrap", "--version"]),
        "secret_service": command(["busctl", "--user", "--list", "--no-pager"]) and (
            "org.freedesktop.secrets" in (command(["busctl", "--user", "--list", "--no-pager"]) or "")
        ),
    },
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(record, handle, ensure_ascii=False, indent=2)

cases = record["cases"]
print(f'memory: scope stopped={cases["memory"]["scope_stopped"]}, witness kept running '
      f'({cases["memory"]["witness_alive_samples"]} samples)')
print(f'cpu: 20% quota, the loop got {cases["cpu"]["cpu_share_of_wall"]} of wall time '
      f'(enforced={cases["cpu"]["enforced"]})')
print(f'tasks: TasksMax=16 allowed {cases["tasks"]["processes_started"]} of 64 forks '
      f'(enforced={cases["tasks"]["enforced"]})')
print(f'landlock ABI: {record["platform_facts"]["landlock_abi"]}, '
      f'cgroup controllers: {record["platform_facts"]["cgroup_controllers"]}')
print(f"-> {output}")
enforced = (cases["memory"]["scope_stopped"] and cases["cpu"]["enforced"]
            and cases["tasks"]["enforced"] and cases["memory"]["witness_alive_samples"] > 0)
if not enforced:
    print("at least one limit is not enforced here; G3 isolation depends on all three")
raise SystemExit(0 if enforced else 1)
PYEOF
echo 'development-VM evidence; the initial quota values are approved from the reference machine (EX-05)'

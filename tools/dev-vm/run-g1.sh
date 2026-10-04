#!/usr/bin/env bash
# Run G1's non-graphical development checks in the disposable VM. A result
# here never substitutes for the physical reference machine's exit evidence.
#
#   tools/dev-vm/run-g1.sh [rust-workspace] [node-workspace]
#       [contract-vectors] [preflight-negative] [rollback]
#       [persistence-faults] [cordis-independent] [cleanup-stress] [latency]
#       [rescue-no-node]
set -euo pipefail
source "$(dirname "$0")/lib.sh"

suites=("$@")
(( ${#suites[@]} )) || suites=(rust-workspace node-workspace contract-vectors preflight-negative rollback persistence-faults cordis-independent cleanup-stress latency rescue-no-node manual-switch)
for suite in "${suites[@]}"; do
  case "$suite" in
    rust-workspace | node-workspace | contract-vectors | preflight-negative | rollback | persistence-faults | cordis-independent | cleanup-stress | latency | rescue-no-node | manual-switch) ;;
    *) echo "unknown G1 suite: $suite" >&2; exit 2 ;;
  esac
done
if [[ "$(virsh_vm domstate "$VM_NAME" 2>/dev/null)" != "shut off" ]]; then
  echo "$VM_NAME is already running; stop the other VM run before restoring its snapshot" >&2
  exit 2
fi

run_id="$(date -u +%Y-%m-%dT%H:%M:%SZ)-$(git -C "$WORKSPACE" rev-parse --short=4 HEAD)"
out="$WORKSPACE/artifacts/g1-vm/$run_id"
mkdir -p "$out"
summary="$out/summary.jsonl"
failures=0
started=0

finish() {
  if (( started )); then
    vm_ssh 'sudo umount /mnt/ditto-g1-small 2>/dev/null || true' >/dev/null 2>&1 || true
    vm_rsync neil@"$(vm_ip)":funlab/Ditto/artifacts/g1/ "$out/vm-artifacts/" >/dev/null 2>&1 || true
    virsh_vm shutdown "$VM_NAME" >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
      [[ "$(virsh_vm domstate "$VM_NAME" 2>/dev/null)" == "shut off" ]] && break
      sleep 2
    done
    virsh_vm destroy "$VM_NAME" >/dev/null 2>&1 || true
  fi
  echo "G1 VM summary -> $summary ($failures checks without a full pass)"
}
trap finish EXIT

record() {
  local name="$1" status="$2"
  jq -cn --arg name "$name" --arg status "$status" '{check: $name, status: $status, evidence_class: "development-vm"}' >>"$summary"
  printf '%-34s %s\n' "$name" "$status"
  [[ "$status" == pass ]] || failures=$((failures + 1))
}

if ! virsh_vm snapshot-revert "$VM_NAME" "$VM_SNAPSHOT" --running --force >"$out/restore.log" 2>&1; then
  record restore fail
  exit 1
fi
started=1
if ! vm_wait_ssh >>"$out/restore.log" 2>&1; then
  record ssh fail
  exit 1
fi
record restore pass
vm_ssh 'sudo systemctl restart systemd-timesyncd >/dev/null 2>&1; sudo date -s "@'"$(date +%s)"'" >/dev/null' || true
if ! vm_sync_workspace >"$out/sync.log" 2>&1; then
  record sync fail
  exit 1
fi
record sync pass

if vm_ssh "$VM_ENV"' pnpm install --frozen-lockfile && cargo build --locked --workspace --bins && pnpm --filter @ditto/host-runtime build && bash scripts/build-builtin-packages.sh' >"$out/build.log" 2>&1; then
  record build pass
else
  record build fail
  exit 1
fi

for suite in "${suites[@]}"; do
  log="$out/$suite.log"
  if [[ "$suite" == rust-workspace ]]; then
    if vm_ssh "$VM_ENV"' cargo test --locked --workspace' >"$log" 2>&1; then record "$suite" pass; else record "$suite" fail; fi
    continue
  fi
  if [[ "$suite" == node-workspace ]]; then
    if vm_ssh "$VM_ENV"' pnpm -r test && pnpm -r typecheck' >"$log" 2>&1; then record "$suite" pass; else record "$suite" fail; fi
    continue
  fi
  small_fs=''
  if [[ "$suite" == persistence-faults ]]; then
    if vm_ssh 'sudo mkdir -p /mnt/ditto-g1-small && sudo mount -t tmpfs -o size=80m,uid=1000 tmpfs /mnt/ditto-g1-small' >"$out/tmpfs.log" 2>&1; then
      small_fs='DITTO_G1_SMALL_FS=/mnt/ditto-g1-small '
    fi
  fi
  # Keep the suite name on the host side: only names from the case above reach this command.
  if vm_ssh "$VM_ENV""export DITTO_ENVIRONMENT_LABEL=development-vm DITTO_COMPOSITOR=wayfire DITTO_ARTIFACTS=\$PWD/artifacts/g1; ${small_fs}timeout -k 15 900 bash tests/g1/$suite/run.sh" >"$log" 2>&1; then
    record "$suite" pass
  else
    code=$?
    [[ "$code" == 3 ]] && record "$suite" incomplete || record "$suite" fail
  fi
  if [[ "$suite" == persistence-faults ]]; then
    vm_ssh 'sudo umount /mnt/ditto-g1-small 2>/dev/null || true' >/dev/null 2>&1 || true
  fi
done

# A literal VM screenshot supplements the machine-readable JSON and logs.
# The terminal only displays their statuses; it is not the test oracle.
vm_rsync "$summary" neil@"$(vm_ip)":funlab/Ditto/artifacts/g1-vm-summary.jsonl >/dev/null 2>&1 || true
vm_ssh "nohup env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1 foot --title='G1 VM test evidence' bash -lc 'while true; do clear; python3 ~/funlab/Ditto/tools/dev-vm/g1-status-screen.py; sleep 2; done' >/tmp/ditto-g1-status-screen.log 2>&1 </dev/null &" >/dev/null 2>&1 || true
sleep 3
vm_ssh 'cat /tmp/ditto-g1-status-screen.log 2>/dev/null || true' >"$out/status-screen.log" 2>&1 || true
virsh_vm screenshot "$VM_NAME" "$out/vm-test-status.png" >"$out/screenshot.log" 2>&1 || true

exit $(( failures > 0 ))

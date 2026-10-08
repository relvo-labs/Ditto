#!/usr/bin/env bash
# Disposable VM verification of the G2 foundation. These results are
# development evidence, never reference-machine resource/desktop exit data.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
[[ "$(virsh_vm domstate "$VM_NAME" 2>/dev/null)" == "shut off" ]] || { echo 'VM is already in use' >&2; exit 2; }
run_id="$(date -u +%Y-%m-%dT%H:%M:%SZ)-$(git -C "$WORKSPACE" rev-parse --short=4 HEAD)"
out="$WORKSPACE/artifacts/g2-vm/$run_id"
mkdir -p "$out"
started=0
finish() {
  if (( started )); then
    virsh_vm shutdown "$VM_NAME" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      [[ "$(virsh_vm domstate "$VM_NAME" 2>/dev/null)" == "shut off" ]] && break
      sleep 1
    done
    virsh_vm destroy "$VM_NAME" >/dev/null 2>&1 || true
  fi
  echo "G2 VM evidence: $out"
}
trap finish EXIT
record() { jq -cn --arg check "$1" --arg status "$2" '{check:$check,status:$status,evidence_class:"development-vm"}' >>"$out/summary.jsonl"; }
step() {
  local name="$1" command="$2"
  if vm_ssh "$VM_ENV"" $command" >"$out/$name.log" 2>&1; then record "$name" pass; else record "$name" fail; return 1; fi
}
virsh_vm snapshot-revert "$VM_NAME" "$VM_SNAPSHOT" --running --force >"$out/restore.log" 2>&1
started=1
vm_wait_ssh >>"$out/restore.log" 2>&1
record restore pass
vm_ssh 'sudo systemctl restart systemd-timesyncd >/dev/null 2>&1' || true
vm_sync_workspace >"$out/sync.log" 2>&1
record sync pass
step build 'pnpm install --frozen-lockfile && cargo build --locked --workspace --bins && pnpm -r build && bash scripts/build-builtin-packages.sh'
step rust 'cargo test --locked --workspace'
step node 'pnpm -r typecheck && pnpm -r test && pnpm --filter @ditto/agent-runtime check:upstream'
step foundation 'DITTO_ENVIRONMENT_LABEL=development-vm node tests/g2/foundation/run.mjs'

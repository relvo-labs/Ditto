#!/usr/bin/env bash
# Independent G3 foundation on a disposable G2-capable snapshot (D-25).
# Never reverts a VM that is already in use and never logs out the host seat.
set -euo pipefail
export DITTO_VM_SNAPSHOT="${DITTO_VM_SNAPSHOT:-ditto-g2}"
source "$(dirname "$0")/lib.sh"
[[ "$(virsh_vm domstate "$VM_NAME" 2>/dev/null)" == "shut off" ]] || { echo 'VM is already in use' >&2; exit 2; }
run_id="$(date -u +%Y-%m-%dT%H-%M-%SZ)-$(git -C "$WORKSPACE" rev-parse --short=7 HEAD)"
out="$WORKSPACE/artifacts/g3-vm/$run_id"
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
  echo "G3 VM evidence: $out"
}
trap finish EXIT
record() { jq -cn --arg check "$1" --arg status "$2" '{check:$check,status:$status,evidence_class:"development-vm"}' >>"$out/summary.jsonl"; }
step() {
  local name="$1" command="$2" code=0
  vm_ssh "$VM_ENV $command" >"$out/$name.log" 2>&1 || code=$?
  if (( code == 0 )); then record "$name" pass
  elif (( code == 2 )); then record "$name" not_run
  else record "$name" fail; fi
}
virsh_vm snapshot-revert "$VM_NAME" "$VM_SNAPSHOT" --running --force >"$out/restore.log" 2>&1
started=1
vm_wait_ssh >>"$out/restore.log" 2>&1
vm_ssh 'uname -r' >>"$out/restore.log" 2>&1
record restore pass
vm_sync_workspace >"$out/sync.log" 2>&1
record sync pass
step foundation 'bash tests/g3/run.sh'
if [[ "${DITTO_G3_EXPECT_OLD_ABI:-0}" == 1 ]]; then
  step rejection 'python3 tests/g3/host/rejection.py --old-abi'
  record candidate-execution not_run
else
  step rejection 'python3 tests/g3/host/rejection.py'
  step host 'DITTO_ENVIRONMENT_LABEL=development-vm timeout -k 5 180 bash tests/g3/host/run.sh'
fi
vm_rsync "neil@$(vm_ip):funlab/Ditto/artifacts/g3/" "$out/suite-records/" >"$out/collect.log" 2>&1 || record collect fail
if jq -e 'select(.status == "fail")' "$out/summary.jsonl" >/dev/null; then exit 1; fi
if jq -e 'select(.status == "not_run")' "$out/summary.jsonl" >/dev/null; then exit 2; fi

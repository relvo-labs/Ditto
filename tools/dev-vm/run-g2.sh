#!/usr/bin/env bash
# Disposable VM verification of the G2 foundation. These results are
# development evidence, never reference-machine resource/desktop exit data.
set -euo pipefail
# ditto-g2 = ditto-base plus the HWE kernel (Landlock ABI >= 6, which Core
# requires before it starts the Codex backend) and GLib development files.
export DITTO_VM_SNAPSHOT="${DITTO_VM_SNAPSHOT:-ditto-g2}"
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
  local name="$1" command="$2" code=0
  vm_ssh "$VM_ENV"" $command" >"$out/$name.log" 2>&1 || code=$?
  # Exit 2: the suite could not run here (environment), not a failure.
  if (( code == 0 )); then record "$name" pass; elif (( code == 2 )); then record "$name" not_run; else record "$name" fail; return 1; fi
}
virsh_vm snapshot-revert "$VM_NAME" "$VM_SNAPSHOT" --running --force >"$out/restore.log" 2>&1
started=1
vm_wait_ssh >>"$out/restore.log" 2>&1
vm_ssh "uname -r" >>"$out/restore.log" 2>&1
record restore pass
vm_ssh 'sudo systemctl restart systemd-timesyncd >/dev/null 2>&1' || true
vm_sync_workspace >"$out/sync.log" 2>&1
record sync pass
vm_build_packages >"$out/packages.log" 2>&1 && record packages pass || record packages fail
step build 'pnpm install --frozen-lockfile && cargo build --locked --workspace --bins && pnpm -r build && bash scripts/build-builtin-packages.sh'
step rust 'cargo test --locked --workspace' || true
step node 'pnpm -r typecheck && pnpm -r test && pnpm --filter @ditto/agent-runtime check:upstream' || true
step foundation 'DITTO_ENVIRONMENT_LABEL=development-vm node tests/g2/foundation/run.mjs' || true
# G2 suites from a clean checkout. The pinned Codex binary is copied in (it is
# not part of the repository); the session-bus proxy is built from its pin.
codex="$(readlink -f "${DITTO_CODEX_BINARY:-$HOME/.local/bin/codex}" 2>/dev/null || true)"
if [[ -n "$codex" && -f "$codex" ]]; then
  vm_ssh "mkdir -p '$(dirname "$codex")'" && vm_rsync "$codex" "neil@$(vm_ip):$codex" && vm_ssh "mkdir -p ~/.local/bin && ln -sf '$codex' ~/.local/bin/codex" && record codex-binary pass || record codex-binary fail
else
  record codex-binary not_run
fi
step dbus-proxy 'bash tools/dbus-proxy/build.sh debug' || true
label='DITTO_ENVIRONMENT_LABEL=development-vm'
step confine "cargo test --locked -p ditto-confine" || true
step fault-build 'cargo build --locked -p ditto-core -p ditto-confine --features ditto-core/fault-injection --target-dir target/fault-injection' || true
for suite in codex/run codex/faults codex/crash codex/races codex/injection jobs/run lifecycle/run; do
  name="$(echo "$suite" | tr / -)"
  args=""; [[ "$suite" == lifecycle/run ]] && args="quick"
  step "$name" "$label node tests/g2/$suite.mjs $args" || true
done
for suite in layout codex/desktop shell; do
  name="$(echo "$suite" | tr / -)"
  script="tests/g2/$suite/run.sh"; [[ "$suite" == codex/desktop ]] && script="tests/g2/codex/desktop.sh"
  step "$name" "$label DITTO_COMPOSITOR=wayfire DITTO_ARTIFACTS=\$PWD/artifacts/g2 timeout -k 15 1800 bash $script" || true
done
vm_collect_artifacts "neil@$(vm_ip):funlab/Ditto/artifacts/g2/" "$out/suite-records/" >/dev/null 2>&1 || true
# The run fails when any step failed; not_run (environment) does not.
! jq -e 'select(.status == "fail")' "$out/summary.jsonl" >/dev/null

#!/usr/bin/env bash
# Run G1's non-graphical development checks in the disposable VM. A result
# here never substitutes for the physical reference machine's exit evidence.
#
#   tools/dev-vm/run-g1.sh [rust-workspace] [node-workspace]
#       [contract-vectors] [preflight-negative] [rollback]
#       [persistence-faults] [lifecycle] [cordis-independent] [cleanup-stress]
#       [latency] [rescue-no-node] [manual-switch]
#       [session-rescue-supervision] [session-lock]
#
# The session-* suites run inside a logged-in "Ditto (Wayfire)" session: the
# VM installs the G1 session from the synced tree with
# `install-session.sh --development --verification-relay`, GDM logs in to it
# automatically, and the runners read Core back through the verification
# relay. session-rescue-supervision kills Core on purpose
# (DITTO_ALLOW_CORE_STORM=1); session-lock leaves the session locked, so it
# runs last. Neither is in the default list.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

suites=("$@")
(( ${#suites[@]} )) || suites=(rust-workspace node-workspace contract-vectors preflight-negative rollback persistence-faults lifecycle cordis-independent cleanup-stress latency rescue-no-node manual-switch)
for suite in "${suites[@]}"; do
  case "$suite" in
    rust-workspace | node-workspace | contract-vectors | preflight-negative | rollback | persistence-faults | lifecycle | cordis-independent | cleanup-stress | latency | rescue-no-node | manual-switch) ;;
    session-rescue-supervision | session-lock) ;;
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
    vm_collect_artifacts neil@"$(vm_ip)":funlab/Ditto/artifacts/g1/ "$out/vm-artifacts/" >/dev/null 2>&1 || true
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
if ! vm_build_packages >"$out/packages.log" 2>&1; then
  record packages fail
  exit 1
fi
record packages pass

if vm_ssh "$VM_ENV"' pnpm install --frozen-lockfile && cargo build --locked --workspace --bins && pnpm -r build && bash scripts/build-builtin-packages.sh' >"$out/build.log" 2>&1; then
  record build pass
else
  record build fail
  exit 1
fi

# The session suites need the G1 session logged in, not the snapshot's G0 one.
session_ready=""
start_session() {
  [[ -n "$session_ready" ]] && return 0
  vm_ssh "$VM_ENV"' bash packaging/reference-image/install-session.sh --development --verification-relay' >"$out/session-install.log" 2>&1 || return 1
  vm_ssh 'printf "[User]\nSession=ditto\nSystemAccount=false\n" | sudo tee /var/lib/AccountsService/users/neil >/dev/null && sudo systemctl restart accounts-daemon && sudo systemctl restart gdm' >>"$out/session-install.log" 2>&1 || return 1
  local _
  for _ in $(seq 1 100); do
    if vm_ssh 'XDG_RUNTIME_DIR=/run/user/1000 systemctl --user is-active --quiet ditto-session.target && test -S /run/user/1000/ditto/verify-relay.sock' 2>/dev/null; then
      session_ready=1
      # Let the Shell, hostd and the boot sync settle before anything is killed.
      sleep 20
      return 0
    fi
    sleep 3
  done
  vm_ssh 'XDG_RUNTIME_DIR=/run/user/1000 journalctl --user -u ditto-core -n 200 --no-pager' >>"$out/session-install.log" 2>&1 || true
  return 1
}

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
  if [[ "$suite" == session-* ]]; then
    if ! start_session; then
      record "$suite" fail
      echo "the G1 session did not come up; see $out/session-install.log" >&2
      continue
    fi
    runner="${suite#session-}"
    extra=''
    [[ "$runner" == rescue-supervision ]] && extra='DITTO_ALLOW_CORE_STORM=1 '
    if vm_ssh "$VM_ENV""export DITTO_ENVIRONMENT_LABEL=development-vm DITTO_COMPOSITOR=wayfire DITTO_ARTIFACTS=\$PWD/artifacts/g1; ${extra}timeout -k 15 1800 bash tests/g1/$runner/run.sh" >"$log" 2>&1; then
      record "$suite" pass
    else
      code=$?
      [[ "$code" == 3 ]] && record "$suite" incomplete || record "$suite" fail
    fi
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

#!/usr/bin/env bash
# The first-line automated G0 test run (D-25): restore the VM snapshot, install
# the current tree, run the G0 fixtures and the login-level checks, copy the
# artifacts back, and shut the VM down.
#
#   tools/dev-vm/run.sh [fixtures] [login] [cold-login]   (default: all three)
#
# fixtures    headless G0 fixtures in development mode
# login       a clean relogin through GDM, and an orphaned session after GDM
#             is killed, must both end in a new login with all four scopes
# cold-login  three logins through GDM autologin sampled with a short
#             cold-login format check, plus one login in each other state
#
# Everything here is development evidence. Exit measurements (EX-01/03/04/05)
# stay on the physical reference machine; this VM must not run while one is
# being taken, so it is always shut down at the end.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

suites=("$@")
(( ${#suites[@]} )) || suites=(fixtures login cold-login)
run_id="$(date -u +%Y-%m-%dT%H:%M:%SZ)-$(git -C "$WORKSPACE" rev-parse --short=4 HEAD)"
out="$WORKSPACE/artifacts/g0-vm/$run_id"
mkdir -p "$out"
summary="$out/summary.jsonl"
failures=0

record() {
  local name="$1" status="$2"
  jq -cn --arg name "$name" --arg status "$status" '{check: $name, status: $status}' >>"$summary"
  printf '%-34s %s\n' "$name" "$status"
  [[ "$status" == pass ]] || failures=$((failures + 1))
}

check() {
  local name="$1"
  shift
  if "$@" >"$out/$name.log" 2>&1; then record "$name" pass; else record "$name" fail; fi
}

finish() {
  vm_rsync neil@"$(vm_ip)":funlab/Ditto/artifacts/ "$out/vm-artifacts/" >/dev/null 2>&1 || true
  virsh_vm shutdown "$VM_NAME" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    [[ "$(virsh_vm domstate "$VM_NAME" 2>/dev/null)" == "shut off" ]] && break
    sleep 2
  done
  virsh_vm destroy "$VM_NAME" >/dev/null 2>&1 || true
  echo "summary -> $summary ($failures failed)"
}
trap finish EXIT

restore() {
  virsh_vm snapshot-revert "$VM_NAME" "$VM_SNAPSHOT" --running --force && vm_wait_ssh
}
check restore-snapshot restore
(( failures == 0 )) || { echo "cannot restore $VM_NAME snapshot $VM_SNAPSHOT; see $out/restore-snapshot.log" >&2; exit 1; }
# A restored snapshot keeps the clock it was taken with.
vm_ssh 'sudo systemctl restart systemd-timesyncd >/dev/null 2>&1; sudo date -s "@'"$(date +%s)"'" >/dev/null' || true
vm_sync_workspace || exit 1

install_tree() {
  vm_ssh "$VM_ENV"' cargo build -q --locked --workspace --bins &&
    cargo build -q --locked --release -p ditto-core -p ditto-measure &&
    bash packaging/reference-image/install-session.sh --development &&
    sudo /usr/local/libexec/ditto-g0-relogin' && vm_wait_desktop
}
check install-and-login install_tree
(( failures == 0 )) || exit 1

fixture() {
  vm_ssh "$VM_ENV"' export DITTO_ENVIRONMENT_LABEL=development-vm DITTO_COMPOSITOR=wayfire
    DITTO_WORKSPACE=$PWD DITTO_BINARIES=$PWD/target/debug DITTO_ARTIFACTS=$PWD/artifacts/g0-vm;
    unset WAYLAND_DISPLAY DISPLAY; timeout 900 bash tests/g0/'"$1"'/run.sh'
}

scopes_of_new_login() {
  local before="$1" now
  vm_wait_desktop || return 1
  now="$(vm_ssh 'loginctl list-sessions --no-legend | awk "\$4==\"seat0\"{print \$1}"')"
  [[ -n "$now" && "$now" != "$before" ]]
}

seat_session() { vm_ssh 'loginctl list-sessions --no-legend | awk "\$4==\"seat0\"{print \$1}"'; }

relogin_clean() {
  local before; before="$(seat_session)"
  vm_ssh 'sudo /usr/local/libexec/ditto-g0-relogin' && scopes_of_new_login "$before"
}

orphaned_session() {
  local before; before="$(seat_session)"
  # GDM dies without ending its session: the reference machine's 2026-09-26
  # failure. The drop-in must end the orphan before the next login.
  vm_ssh 'sudo systemctl kill --kill-whom=main -s KILL gdm' &&
    scopes_of_new_login "$before" &&
    vm_ssh "journalctl -b --no-pager --since '-2min' | grep -q 'ending orphaned Ditto G0 session $before'"
}

cold_login_sample() {
  local state="$1" before
  vm_ssh "$VM_ENV bash tests/g0/measure/cold-login.sh prepare $state" || return 1
  before="$(seat_session)"
  vm_ssh 'sudo /usr/local/libexec/ditto-g0-relogin' && scopes_of_new_login "$before" || return 1
  vm_ssh "$VM_ENV"' export DITTO_FORMAT_CHECK=1 DITTO_WARMUP_SECONDS=20 DITTO_SAMPLE_SECONDS=30;
    timeout 600 bash tests/g0/measure/cold-login.sh sample'
}

cold_login_report() {
  vm_ssh "$VM_ENV DITTO_FORMAT_CHECK=1 bash tests/g0/measure/cold-login.sh report standard"
}

for suite in "${suites[@]}"; do
  case "$suite" in
    fixtures)
      for name in window-matrix identity-negative shell-session shell-restart-survival hotpath avatar-hit-region compositor-probe; do
        check "fixture-$name" fixture "$name"
      done
      ;;
    login)
      check login-relogin-clean relogin_clean
      check login-orphaned-session orphaned_session
      ;;
    cold-login)
      vm_ssh 'rm -f ~/funlab/Ditto/artifacts/g0/cold-login-series-format-check-*.jsonl'
      for n in 1 2 3; do check "cold-login-standard-$n" cold_login_sample standard; done
      check cold-login-report-standard cold_login_report
      check cold-login-avatar-off cold_login_sample avatar-off
      check cold-login-reduced-motion cold_login_sample reduced-motion
      vm_ssh "$VM_ENV bash tests/g0/measure/cold-login.sh prepare standard" >/dev/null
      ;;
    *) echo "unknown suite: $suite" >&2; failures=$((failures + 1)) ;;
  esac
done

exit $(( failures > 0 ))

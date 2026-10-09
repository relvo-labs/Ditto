#!/usr/bin/env bash
# G2 measurement flow in the disposable VM (snapshot ditto-g2), unattended:
# EX2-14's four states through real GDM autologins (three per state, warm-up
# 300 s, sampling 600 s), then EX2-12 (30 cold Agent starts) and EX2-13 (200
# warm chat and launcher opens) in a fresh login.
#
#   tools/dev-vm/run-g2-measure.sh [state ...]
#       (default: rescue_no_node desktop_full_no_agent desktop_full_agent_warm
#        desktop_full_agent_active)
#
# The VM has no Codex subscription: its session's Core talks to a loopback
# model (measure-model.mjs, ~130 characters streamed over ~2.6 s per answer)
# through --agent-backend-test-provider, which Core accepts only with
# DITTO_TEST_FIXTURE=1. Everything else is the installed session
# (install-session.sh --development --verification-relay). The VM has no GPU,
# a different kernel and 8 GiB: every number here is development-vm evidence,
# runs as a cold-login format check (DITTO_FORMAT_CHECK=1, full durations)
# and never counts for EX2-12/13/14, which need the reference machine.
set -euo pipefail
export DITTO_VM_SNAPSHOT="${DITTO_VM_SNAPSHOT:-ditto-g2}"
source "$(dirname "$0")/lib.sh"
states=("$@")
(( ${#states[@]} )) || states=(rescue_no_node desktop_full_no_agent desktop_full_agent_warm desktop_full_agent_active)
[[ "$(virsh_vm domstate "$VM_NAME" 2>/dev/null)" == "shut off" ]] || { echo 'VM is already in use' >&2; exit 2; }
run_id="$(date -u +%Y-%m-%dT%H:%M:%SZ)-$(git -C "$WORKSPACE" rev-parse --short=4 HEAD)"
out="$WORKSPACE/artifacts/g2-vm-measure/$run_id"
mkdir -p "$out"
started=0
finish() {
  if (( started )) && [[ -z "${DITTO_VM_KEEP:-}" ]]; then
    vm_rsync neil@"$(vm_ip)":funlab/Ditto/artifacts/g2/ "$out/vm-artifacts/" >/dev/null 2>&1 || true
    virsh_vm shutdown "$VM_NAME" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      [[ "$(virsh_vm domstate "$VM_NAME" 2>/dev/null)" == "shut off" ]] && break
      sleep 1
    done
    virsh_vm destroy "$VM_NAME" >/dev/null 2>&1 || true
  fi
  echo "G2 VM measurement: $out"
}
trap finish EXIT
log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$out/progress.log" >&2; }
record() { jq -cn --arg check "$1" --arg status "$2" '{check:$check,status:$status,evidence_class:"development-vm"}' >>"$out/summary.jsonl"; }
step() { # <name> <command in the VM>
  local code=0
  log "$1"
  vm_ssh "$VM_ENV $2" >"$out/$1.log" 2>&1 || code=$?
  (( code == 0 )) && record "$1" pass || { record "$1" fail; return 1; }
}

virsh_vm snapshot-revert "$VM_NAME" "$VM_SNAPSHOT" --running --force >"$out/restore.log" 2>&1
started=1
vm_wait_ssh >>"$out/restore.log" 2>&1
vm_ssh 'sudo systemctl restart systemd-timesyncd >/dev/null 2>&1' || true
vm_sync_workspace >"$out/sync.log" 2>&1
codex="$(readlink -f "${DITTO_CODEX_BINARY:-$HOME/.local/bin/codex}")"
vm_ssh "mkdir -p '$(dirname "$codex")' ~/.local/bin" && vm_rsync "$codex" "neil@$(vm_ip):$codex" && vm_ssh "ln -sf '$codex' ~/.local/bin/codex"
record setup pass

# xdg-desktop-portal-wlr is built from its pin by install-session.sh.
step packages 'sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q meson ninja-build pkg-config libpipewire-0.3-dev libwayland-dev wayland-protocols libgbm-dev libdrm-dev libinih-dev libsystemd-dev'
step install 'pnpm install --frozen-lockfile && bash scripts/build-builtin-packages.sh >/dev/null && cargo build --locked --workspace --bins && cargo build --locked --release -p ditto-measure && bash packaging/reference-image/install-session.sh --development --verification-relay'
# The loopback model as a user service (not a ditto-* unit, so the sampler
# leaves it out), and Core pointed at it.
step model 'cat >/tmp/measure-model.service <<EOF
[Unit]
Description=Loopback model for G2 VM measurement
[Service]
ExecStart=$(command -v node) $HOME/funlab/Ditto/tools/dev-vm/measure-model.mjs 18080
Restart=always
[Install]
WantedBy=default.target
EOF
sudo install -D -m 0644 /tmp/measure-model.service /etc/systemd/user/measure-model.service
sed -e "s|^\(    --agent-backend .*\) \\\\$|\1 \\\\\n    --agent-backend-test-provider http://127.0.0.1:18080/v1 \\\\|" \
  -e "s|^\[Service\]$|[Service]\nEnvironment=DITTO_TEST_FIXTURE=1|" \
  /etc/systemd/user/ditto-core.service.d/verification-relay.conf >/tmp/zz-measure-model.conf
grep -q -- "--agent-backend-test-provider" /tmp/zz-measure-model.conf
sudo install -m 0644 /tmp/zz-measure-model.conf /etc/systemd/user/ditto-core.service.d/zz-measure-model.conf
sudo systemctl daemon-reload; systemctl --user daemon-reload; systemctl --user enable --now measure-model.service
printf "[User]\nSession=ditto\nSystemAccount=false\n" | sudo tee /var/lib/AccountsService/users/neil >/dev/null
sudo systemctl restart accounts-daemon'

# DITTO_VM_SETUP_ONLY=1 (with DITTO_VM_KEEP=1): stop here, VM left running.
[[ -n "${DITTO_VM_SETUP_ONLY:-}" ]] && exit 0

# The series runs inside the VM as a user service, outside the logins it
# restarts; the host only watches it.
step series-start "rm -f artifacts/g2/cold-login-series-format-check-*.jsonl; systemd-run --user --unit=g2-measure-series --collect --same-dir \
  -E PATH=\"\$PATH\" -E LD_LIBRARY_PATH=\"\$LD_LIBRARY_PATH\" -E DITTO_ARTIFACTS=\$PWD/artifacts/g2 -E DITTO_FORMAT_CHECK=1 \
  -E DITTO_LOGIN_TIMEOUT_SECONDS=600 -E DITTO_SERIES_FINAL_RELOGIN=1 \
  bash tests/g1/measure/series.sh ${states[*]}"
# A relogin briefly drops SSH; only a definite answer that the unit is gone
# (inactive, failed, unknown) ends the wait.
while :; do
  sleep 60
  unit_state="$(vm_ssh 'XDG_RUNTIME_DIR=/run/user/1000 systemctl --user is-active g2-measure-series.service' 2>/dev/null || true)"
  case "$unit_state" in active|activating|deactivating|reloading|'') continue ;; *) break ;; esac
done
log "series ended ($unit_state)"
vm_ssh 'cat ~/funlab/Ditto/artifacts/g2/cold-login-progress-format-check.log' >"$out/series-progress.log" 2>&1 || true
for state in "${states[@]}"; do
  if vm_ssh "$VM_ENV DITTO_ARTIFACTS=\$PWD/artifacts/g2 DITTO_FORMAT_CHECK=1 bash tests/g1/measure/cold-login.sh report $state" >"$out/report-$state.log" 2>&1; then
    record "report-$state" pass
  else
    record "report-$state" fail
  fi
done

# EX2-12 and EX2-13 in the fresh login the series ended with: first the
# surfaces (the first open of each is cold in this login), then the Agent.
for _ in $(seq 1 60); do
  vm_ssh "$VM_ENV bash tests/g1/measure/cold-login.sh ready desktop_full_no_agent" >/dev/null 2>&1 && break
  sleep 5
done
vm_env="DITTO_MEASURE_ENVIRONMENT='development VM ditto-g0-vm (no GPU), loopback model; not reference evidence'"
step first-frame-chat "$vm_env python3 tests/g2/measure/first-frame-session.py 200 chat" || true
step first-frame-launcher "$vm_env python3 tests/g2/measure/first-frame-session.py 200 launcher" || true
step cold-start "$vm_env DITTO_MEASURE_ENABLE_AGENT=1 node tests/g2/measure/cold-start-session.mjs 30 5" || true
log done

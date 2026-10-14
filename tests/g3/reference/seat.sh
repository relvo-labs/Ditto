#!/usr/bin/env bash
# Explicitly authorized, disruptive reference-seat acceptance. Launch through
# a user service outside the graphical session so logout cannot kill recovery.
set -euo pipefail
cd "$(dirname "$0")/../../.."
export PATH="$HOME/.nvm/versions/node/v22.23.2/bin:$HOME/Qt/6.10.2/gcc_64/bin:$HOME/wayfire/bin:$HOME/.local/bin:$PATH"
export LD_LIBRARY_PATH="$HOME/wayfire/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export XDG_RUNTIME_DIR="/run/user/$(id -u)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
: "${DITTO_ARTIFACTS:?private evidence directory required}"
: "${DITTO_G3_SUBSCRIPTION_STORE:?existing signed-in private test store required}"
[[ "${DITTO_G3_ALLOW_REAL_MODEL:-0}" == 1 && "${DITTO_G3_ALLOW_PHYSICAL_LOGIN:-0}" == 1 ]] || exit 64
mkdir -p -m 0700 "$DITTO_ARTIFACTS"
export DITTO_BINARIES="${DITTO_BINARIES:-$PWD/target/release}"
export DITTO_RUNTIME_DIR="$XDG_RUNTIME_DIR/ditto" DITTO_G1_RELAY="$XDG_RUNTIME_DIR/ditto/verify-relay.sock"
export WAYFIRE_SOCKET="$XDG_RUNTIME_DIR/ditto-wayfire-ipc.sock" _WAYFIRE_SOCKET="$XDG_RUNTIME_DIR/ditto-wayfire-ipc.sock"
export DITTO_G3_RUN_SUFFIX="r$(date -u +%s)"
export DITTO_G3_PHYSICAL_CONTEXT="$DITTO_ARTIFACTS/physical-context.json"
export DITTO_G3_DESKTOP_OUT="$DITTO_ARTIFACTS/desktop.json" DITTO_G3_AGENT_OUT="$DITTO_ARTIFACTS/real-model.json" DITTO_G3_TEST_OUT="$DITTO_ARTIFACTS/summary.json"
dropin="$XDG_RUNTIME_DIR/systemd/user/ditto-core.service.d/zz-g3-reference-test.conf"
backup="$DITTO_ARTIFACTS/gdm-original.conf"
[[ ! -e "$dropin" && ! -e "$backup" ]] || { echo 'Refusing to overwrite recovery state'; exit 1; }
python3 tests/g1/lib/gui.py relay desktop.profiles.get | python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]; print(json.dumps({"profile_id":r["profile"]["profile_id"],"sha256":r["revision"]["document_sha256"]}))' > "$DITTO_ARTIFACTS/normal-before.json"
runner_was_active="$(systemctl --user is-active github-actions-ditto-ref.service || true)"
[[ -z "$(pgrep -f '/bin/Runner.Worker spawnclient' || true)" ]] || { echo 'CI worker is still running'; exit 1; }
systemctl --user stop github-actions-ditto-ref.service
sudo -n cp -p /etc/gdm3/custom.conf "$backup"
wait_login() {
    local old="$1" session=""
    for _ in $(seq 1 600); do
        session="$(systemctl --user show-environment | sed -n 's/^XDG_SESSION_ID=//p')"
        if [[ -n "$session" && "$session" != "$old" && -S "$DITTO_G1_RELAY" ]] && [[ "$(loginctl show-session "$session" -p Active --value 2>/dev/null)" == yes ]]; then
            if python3 tests/g1/lib/gui.py relay desktop.profiles.get 2>/dev/null | python3 -c 'import json,sys; assert "result" in json.load(sys.stdin)' 2>/dev/null; then
                export XDG_SESSION_ID="$session"
                export WAYLAND_DISPLAY="$(systemctl --user show-environment | sed -n 's/^WAYLAND_DISPLAY=//p')"
                sleep 3
                return 0
            fi
        fi
        sleep .2
    done
    echo 'Physical login did not become ready' >&2
    return 1
}
restore() {
    local result=$?
    trap - EXIT INT TERM
    set +e
    [[ -z "${app_pid:-}" ]] || kill "$app_pid" 2>/dev/null
    journalctl --user -u ditto-core.service --since "$started" --no-pager > "$DITTO_ARTIFACTS/core.journal.log"
    rm -f "$dropin"
    systemctl --user daemon-reload
    old="${XDG_SESSION_ID:-}"
    sudo -n /usr/local/libexec/ditto-relogin
    wait_login "$old"
    local restored=$?
    if [[ "$restored" == 0 ]]; then
        python3 tests/g1/lib/gui.py relay desktop.profiles.get | python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]; print(json.dumps({"profile_id":r["profile"]["profile_id"],"sha256":r["revision"]["document_sha256"]}))' > "$DITTO_ARTIFACTS/normal-after.json"
        cmp "$DITTO_ARTIFACTS/normal-before.json" "$DITTO_ARTIFACTS/normal-after.json" || restored=1
    fi
    sudo -n cp -p "$backup" /etc/gdm3/custom.conf
    cmp "$backup" /etc/gdm3/custom.conf || restored=1
    if [[ "$runner_was_active" == active ]]; then systemctl --user start github-actions-ditto-ref.service || restored=1; fi
    printf '{"test_exit":%s,"restore_exit":%s,"session":"%s"}\n' "$result" "$restored" "${XDG_SESSION_ID:-}" > "$DITTO_ARTIFACTS/recovery.json"
    [[ "$result" == 0 && "$restored" == 0 ]]
}
started="$(date --iso-8601=seconds)"
trap restore EXIT INT TERM
python3 - "$backup" "$DITTO_ARTIFACTS/gdm-test.conf" <<'PY'
import pathlib,sys
text=pathlib.Path(sys.argv[1]).read_text()
assert 'AutomaticLoginEnable=true' not in text
pathlib.Path(sys.argv[2]).write_text(text.replace('[daemon]','[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=neil',1))
PY
sudo -n install -m 0644 "$DITTO_ARTIFACTS/gdm-test.conf" /etc/gdm3/custom.conf
mkdir -p "$(dirname "$dropin")"
printf '[Service]\nEnvironment=DITTO_DATA_DIR=%s\n' "$DITTO_G3_SUBSCRIPTION_STORE" > "$dropin"
if [[ "$DITTO_BINARIES" != "$PWD/target/release" ]]; then
    python3 - "$dropin" "$PWD" "$DITTO_BINARIES" <<'PY'
import pathlib,sys
drop,root,binaries=sys.argv[1:]
unit=pathlib.Path('/etc/systemd/user/ditto-core.service.d/verification-relay.conf').read_text()
start=unit.index('ExecStart=\n')
with open(drop,'a') as f: f.write(unit[start:].replace(root+'/target/release/ditto-core',binaries+'/ditto-core'))
PY
fi
systemctl --user daemon-reload
old="$(systemctl --user show-environment | sed -n 's/^XDG_SESSION_ID=//p')"
sudo -n /usr/local/libexec/ditto-relogin
wait_login "$old"
foot --app-id=ditto-g3-survival sh -c 'sleep 1800' > "$DITTO_ARTIFACTS/application.log" 2>&1 &
app_pid=$!
export DITTO_G3_APP_PID="$app_pid"
sleep 2
python3 tests/g3/reference/observe.py guard
result=0
if [[ "${DITTO_G3_REFERENCE_MODE:-full}" == full || "${DITTO_G3_REFERENCE_MODE:-full}" == desktop ]]; then
    timeout 900s node tests/g3/reference/driver.mjs || result=1
    if [[ "${DITTO_G3_REFERENCE_MODE:-full}" == full ]]; then
        timeout 180s python3 tests/g3/native-failures/driver.py || result=1
        timeout 180s python3 tests/g3/host/driver.py || result=1
    fi
else
    timeout 240s node tests/g3/reference/contexts.mjs || result=1
fi
exit "$result"

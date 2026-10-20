#!/usr/bin/env bash
# Self-test of session.sh and run.sh with a stub user manager (#124): no
# systemd, no compositor, no Core. The stubs record every systemctl and
# systemd-run call and keep each unit's state in a directory. Checked:
#   ① with a Ditto login running (ditto-session.target, ditto-core.service
#     and the login's scopes active), `start` refuses before it touches any
#     unit, and `stop` leaves the login alone;
#   ② the same for a login whose Core is already down (the state #124 left
#     the reference machine in: target and scopes up, Core inactive);
#   ③ without a login, start/stop create and stop only ditto-measure-* units,
#     and never stop or reset an installed but inactive ditto-core.service;
#   ④ a start that fails half way, then stop, touches only ditto-measure-*;
#   ⑤ run.sh interrupted during warm-up, and run.sh refused by a login, both
#     end with every non-measurement unit in the state it started in.
# "Touches" means any systemctl verb that changes a unit, or a systemd-run
# unit name. The stubs never run anything, so this is development evidence
# about what the scripts ask systemd to do, not about systemd itself.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# Short names: the measurement runtime holds Unix sockets (108-byte limit).
work="$(mktemp -d "${TMPDIR:-/tmp}/dmt.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin"

cat >"$work/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
# Stub user manager: state per unit in $STUB_STATE/<unit>, calls in $STUB_CALLS.
echo "systemctl $*" >>"$STUB_CALLS"
quiet=""
args=()
for arg in "$@"; do
  case "$arg" in
    --quiet|-q) quiet=1 ;;
    --*) ;;
    *) args+=("$arg") ;;
  esac
done
verb="${args[0]:-}"
units=("${args[@]:1}")
state_of() { cat "$STUB_STATE/$1" 2>/dev/null || echo inactive; }
case "$verb" in
  show-environment) exit 0 ;;
  is-active)
    s="$(state_of "${units[0]}")"
    [[ -n "$quiet" ]] || echo "$s"
    [[ "$s" == active ]]
    ;;
  list-units)
    for file in "$STUB_STATE"/*; do
      [[ -e "$file" ]] || continue
      unit="${file##*/}" s="$(cat "$file")"
      [[ "$s" == inactive ]] && continue
      match=""
      if (( ${#units[@]} == 0 )); then match=1; fi
      for pattern in "${units[@]}"; do
        # shellcheck disable=SC2053
        [[ "$unit" == $pattern ]] && match=1
      done
      [[ -n "$match" ]] && echo "$unit loaded $s running stub"
    done
    exit 0
    ;;
  stop|kill) for unit in "${units[@]}"; do [[ -e "$STUB_STATE/$unit" ]] && echo inactive >"$STUB_STATE/$unit"; done; exit 0 ;;
  start|restart) for unit in "${units[@]}"; do echo active >"$STUB_STATE/$unit"; done; exit 0 ;;
  reset-failed)
    for unit in "${units[@]}"; do
      [[ "$(state_of "$unit")" == failed ]] && echo inactive >"$STUB_STATE/$unit"
    done
    exit 0
    ;;
  show) exit 0 ;;
  *) exit 0 ;;
esac
STUB

cat >"$work/bin/systemd-run" <<'STUB'
#!/usr/bin/env bash
# Stub transient unit: records the call, marks the unit active and creates
# the sockets the real program would, decided by the program's name.
echo "systemd-run $*" >>"$STUB_CALLS"
unit="" runtime="" program=""
for arg in "$@"; do
  case "$arg" in
    --unit=*) unit="${arg#--unit=}" ;;
    --setenv=XDG_RUNTIME_DIR=*) runtime="${arg#--setenv=XDG_RUNTIME_DIR=}" ;;
    -*) ;;
    *) [[ -z "$program" ]] && program="$arg" ;;
  esac
done
[[ "$unit" == *.* ]] || unit="$unit.service"
socket() { python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$1"; }
case "${program##*/}" in
  wayfire) socket "$runtime/wayfire-ipc.sock"; socket "$runtime/wayland-1" ;;
  ditto-core)
    if [[ -n "${STUB_CORE_FAILS:-}" ]]; then echo failed >"$STUB_STATE/$unit"; exit 0; fi
    mkdir -p "$runtime/ditto"; socket "$runtime/ditto/core.sock" ;;
esac
echo active >"$STUB_STATE/$unit"
STUB

cat >"$work/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
echo 'ditto-shell started'
STUB
printf '#!/bin/sh\nexit 0\n' >"$work/bin/wayfire"
printf '#!/bin/sh\nexit 0\n' >"$work/bin/quickshell"
chmod +x "$work/bin"/*

export PATH="$work/bin:$PATH"
export DITTO_BINARIES="$work/bin"

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok: $*"; }

# A fresh user manager for one case. Arguments: unit=state pairs.
fresh() {
  case_dir="$work/$1"
  shift
  mkdir -p "$case_dir/state" "$case_dir/rt"
  export STUB_STATE="$case_dir/state" STUB_CALLS="$case_dir/calls"
  export XDG_RUNTIME_DIR="$case_dir/rt" DITTO_SYSTEMD_RUNTIME_DIR="$case_dir/rt"
  export DBUS_SESSION_BUS_ADDRESS="unix:path=$case_dir/rt/bus"
  : >"$STUB_CALLS"
  local pair
  for pair in "$@"; do echo "${pair#*=}" >"$STUB_STATE/${pair%%=*}"; done
  snapshot_official >"$case_dir/before"
}

# Every unit that is not the measurement's own, with its state.
snapshot_official() {
  local file
  for file in "$STUB_STATE"/*; do
    [[ -e "$file" ]] || continue
    [[ "${file##*/}" == ditto-measure-* ]] && continue
    echo "${file##*/}=$(cat "$file")"
  done
}

# Every unit a call changed or created; must all be ditto-measure-*.
touched_units() {
  python3 - "$STUB_CALLS" <<'PYEOF'
import sys
mutating = {"stop", "start", "restart", "try-restart", "reload", "reload-or-restart",
            "kill", "reset-failed", "enable", "disable", "mask", "unmask", "isolate", "clean", "freeze", "thaw"}
for line in open(sys.argv[1], encoding="utf-8"):
    words = line.split()
    if not words:
        continue
    if words[0] == "systemctl":
        args = [w for w in words[1:] if not w.startswith("-")]
        if args and args[0] in mutating:
            for unit in args[1:]:
                print(unit)
    elif words[0] == "systemd-run":
        for w in words[1:]:
            if w.startswith("--unit="):
                print(w[len("--unit="):])
PYEOF
}

check_only_measurement_touched() {
  local label="$1" bad
  bad="$(touched_units | grep -v '^ditto-measure-' | sort -u | tr '\n' ' ' || true)"
  if [[ -n "$bad" ]]; then fail "$label: touched non-measurement units: $bad"; else pass "$label: only ditto-measure-* units touched"; fi
}

check_official_unchanged() {
  local label="$1"
  if diff -u "$case_dir/before" <(snapshot_official) >"$case_dir/diff"; then
    pass "$label: every other unit kept its state"
  else
    fail "$label: other units changed state:"; cat "$case_dir/diff" >&2
  fi
}

login_units=(ditto-session.target=active ditto-core.service=active ditto-supervisor.service=active
  ditto-wayfire.scope=active ditto-fcitx.scope=active ditto-quickshell.scope=active
  ditto-hostd.scope=active ditto-lock.scope=active)

# ① logged in
fresh c1 "${login_units[@]}"
if bash "$here/session.sh" start >"$case_dir/out" 2>&1; then
  fail "① start succeeded beside a running login"
else
  grep -q 'refusing to start the measurement session' "$case_dir/out" && grep -q 'ditto-session.target' "$case_dir/out" &&
    pass "① start refused and named the login's units" ||
    { fail "① refusal does not name the running units"; cat "$case_dir/out" >&2; }
fi
grep -q '^systemd-run' "$STUB_CALLS" && fail "① start launched a unit beside the login"
bash "$here/session.sh" stop >>"$case_dir/out" 2>&1 || fail "① stop failed"
check_only_measurement_touched ①
check_official_unchanged ①

# ② logged in, Core already down (the reference machine after #124)
fresh c2 ditto-session.target=active ditto-core.service=inactive ditto-supervisor.service=active \
  ditto-wayfire.scope=active ditto-quickshell.scope=active ditto-lock.scope=active
if bash "$here/session.sh" start >"$case_dir/out" 2>&1; then
  fail "② start succeeded beside a login whose Core is down"
elif grep -q 'refusing to start the measurement session' "$case_dir/out"; then
  pass "② start refused"
else
  fail "② start failed without refusing"; cat "$case_dir/out" >&2
fi
bash "$here/session.sh" stop >>"$case_dir/out" 2>&1 || fail "② stop failed"
check_only_measurement_touched ②
check_official_unchanged ②

# ③ no login; the session units are installed, Core failed earlier
fresh c3 ditto-session.target=inactive ditto-core.service=failed ditto-supervisor.service=inactive
if bash "$here/session.sh" start >"$case_dir/out" 2>&1; then
  pass "③ start succeeded without a login"
  started="$(grep '^systemd-run' "$STUB_CALLS" | grep -o -- '--unit=[^ ]*' | sort | tr '\n' ' ')"
  [[ "$started" == "--unit=ditto-measure-core.service --unit=ditto-measure-shell.service --unit=ditto-measure-wayfire.service " ]] &&
    pass "③ started ditto-measure-{wayfire,core,shell}.service" || fail "③ started: $started"
else
  fail "③ start failed without a login"; cat "$case_dir/out" >&2
fi
bash "$here/session.sh" stop >>"$case_dir/out" 2>&1 || fail "③ stop failed"
for unit in ditto-measure-wayfire.service ditto-measure-core.service ditto-measure-shell.service; do
  [[ "$(cat "$STUB_STATE/$unit" 2>/dev/null || echo inactive)" == inactive ]] || fail "③ $unit still running after stop"
done
check_only_measurement_touched ③
check_official_unchanged ③

# The sampler finds the processes through the manifests' unit names: they
# must be exactly the units session.sh starts.
for manifest in "$here/manifest.template.json" "$here/../../../packaging/reference-image/measure-manifest.json"; do
  names="$(python3 -c 'import json, sys; print(" ".join(sorted(u["name"] for u in json.load(open(sys.argv[1]))["units"])))' "$manifest")"
  [[ "$names" == "ditto-measure-core.service ditto-measure-shell.service ditto-measure-wayfire.service" ]] &&
    pass "③ ${manifest##*/} samples the units session.sh starts" || fail "③ ${manifest##*/} samples: $names"
done

# ④ start fails half way (the measurement Core does not come up)
fresh c4 ditto-core.service=inactive
if STUB_CORE_FAILS=1 bash "$here/session.sh" start >"$case_dir/out" 2>&1; then
  fail "④ start succeeded although Core failed"
else
  pass "④ start failed"
fi
bash "$here/session.sh" stop >>"$case_dir/out" 2>&1 || fail "④ stop failed"
check_only_measurement_touched ④
check_official_unchanged ④

# ⑤a run.sh interrupted during warm-up
fresh c5 ditto-core.service=inactive ditto-session.target=inactive
mkdir -p "$case_dir/artifacts"
DITTO_REFERENCE_MACHINE=1 DITTO_WARMUP_SECONDS=60 DITTO_ARTIFACTS="$case_dir/artifacts" \
  setsid bash "$here/run.sh" "$here/manifest.template.json" "$here/conditions.template.json" >"$case_dir/out" 2>&1 &
runner=$!
for _ in $(seq 1 100); do grep -q 'warming up' "$case_dir/out" && break; sleep 0.1; done
if grep -q 'warming up' "$case_dir/out"; then
  kill -TERM -- "-$runner" 2>/dev/null || true
  wait "$runner" 2>/dev/null || true
  for unit in ditto-measure-wayfire.service ditto-measure-core.service ditto-measure-shell.service; do
    [[ "$(cat "$STUB_STATE/$unit" 2>/dev/null || echo inactive)" == inactive ]] || fail "⑤a $unit left running after the interruption"
  done
  pass "⑤a run.sh interrupted during warm-up"
else
  kill -TERM -- "-$runner" 2>/dev/null || true
  wait "$runner" 2>/dev/null || true
  fail "⑤a run.sh never reached warm-up"; cat "$case_dir/out" >&2
fi
check_only_measurement_touched ⑤a
check_official_unchanged ⑤a

# ⑤b run.sh beside a login
fresh c6 "${login_units[@]}"
# A short warm-up so a run.sh that does not refuse ends quickly (its sampler
# is missing here); only the refusal message counts as refusing.
DITTO_REFERENCE_MACHINE=1 DITTO_WARMUP_SECONDS=1 DITTO_ARTIFACTS="$case_dir/artifacts" \
  bash "$here/run.sh" "$here/manifest.template.json" "$here/conditions.template.json" >"$case_dir/out" 2>&1 || true
if grep -q 'refusing to start the measurement session' "$case_dir/out"; then
  pass "⑤b run.sh refused"
else
  fail "⑤b run.sh did not refuse beside a login"
fi
check_only_measurement_touched ⑤b
check_official_unchanged ⑤b

if (( failures )); then
  echo "test-session: $failures failure(s)" >&2
  exit 1
fi
echo 'test-session: all checks passed'

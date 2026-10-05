#!/usr/bin/env bash
# Development only: a dry run of cold-login.sh against the headless fixture.
# Nothing here is EX1-10 evidence, and nothing here logs anyone in or out.
#
#   dry-run.sh [state...]     default: all four states, three "logins" each
#
# Each "login" is a fresh headless desktop: Wayfire on a headless output and
# its own session bus (tests/g0/lib/session.sh), Core in a user scope with the
# Shell, hostd and the verification relay launched by Core into scopes of
# their own (DITTO_LAUNCH_SCOPE_PREFIX, as the login session does), and the
# real ditto-supervisor watching that Shell. Unit names carry a prefix of
# their own (dmfx<pid>-*), so nothing collides with a logged-in Ditto session.
# The state comes from the same measure-conditions.json `prepare` writes,
# read the way packaging/reference-image/session/ditto-session reads it.
#
# Short durations (DITTO_FORMAT_CHECK=1): warm-up 2 s, 3 s of samples every
# 1 s unless set otherwise; foot is the only reference application.
# Reports land in artifacts/g1/measure-dry-run-<run_id>/.
set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

states=("$@")
(( ${#states[@]} )) || states=(rescue_no_node desktop_full_no_agent desktop_full_plus10 desktop_full_no_avatar)
user_runtime="/run/user/$(id -u)"
[[ -S "$user_runtime/systemd/private" ]] || { echo "the systemd user manager is not reachable at $user_runtime" >&2; exit 3; }
out="${DITTO_DRY_RUN_DIR:-$WORKSPACE/artifacts/g1/measure-dry-run-$(run_id)}"
mkdir -p "$out"
prefix="dmfx$$"
packages="$out/packages"
cold_login="$WORKSPACE/tests/g1/measure/cold-login.sh"

export DITTO_FORMAT_CHECK=1 DITTO_MEASURE_FIXTURE=1 DITTO_MEASURE_UNIT_PREFIX="$prefix"
export DITTO_ARTIFACTS="$out" DITTO_BINARIES="${DITTO_BINARIES:-$WORKSPACE/target/debug}"
export DITTO_MEASURE_CONDITIONS="$out/measure-conditions.json"
export DITTO_WARMUP_SECONDS="${DITTO_WARMUP_SECONDS:-2}" DITTO_SAMPLE_SECONDS="${DITTO_SAMPLE_SECONDS:-3}"
export DITTO_SAMPLE_INTERVAL_MS="${DITTO_SAMPLE_INTERVAL_MS:-1000}" DITTO_MEASURE_APPS="${DITTO_MEASURE_APPS:-terminal}"

# The verification built-ins, as install-session.sh --verification-relay
# builds them: the product's plus the D-34 set.
mkdir -p "$packages"
cp "$WORKSPACE"/target/ditto-packages/*.dittopkg "$packages/"
(cd "$WORKSPACE" && pnpm --filter @ditto/plugin-fixtures build >/dev/null)
node "$WORKSPACE/packages/host-sdk/scripts/pack-each.mjs" \
  "$WORKSPACE"/packages/plugin-fixtures/qml/* "$WORKSPACE"/packages/plugin-fixtures/cordis/* --out "$packages" >/dev/null

stop_units() {
  XDG_RUNTIME_DIR="$user_runtime" systemctl --user stop "$prefix-*.scope" >/dev/null 2>&1 || true
}
trap stop_units EXIT INT TERM

# Run cold-login.sh as the series would: against the user manager, with the
# fixture's display, compositor socket and relay.
cold() {
  env XDG_RUNTIME_DIR="$user_runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=$user_runtime/bus" bash "$cold_login" "$@"
}

# One "login": bring a desktop up in the prepared state, sample it, tear down.
one_login() {
  local state="$1" index="$2" variant
  variant="$(python3 -c 'import json, sys
try: print(json.load(open(sys.argv[1])).get("desktop_variant", "standard"))
except (OSError, ValueError): print("standard")' "$DITTO_MEASURE_CONDITIONS")"
  start_compositor
  # shellcheck disable=SC2064 # the directory is fixed once the compositor is up
  # Installed packages are read-only by design (the store's integrity rule).
  trap "stop_units; stop_all; rm -f '$RUNTIME_DIR/systemd'; chmod -R u+w '$RUNTIME_DIR' 2>/dev/null; rm -rf '$RUNTIME_DIR'" EXIT
  # Core's launcher and the scopes below reach the user manager through the
  # runtime directory; the fixture's points there for systemd only.
  ln -s "$user_runtime/systemd" "$RUNTIME_DIR/systemd"
  # Adopt the running compositor into a scope, as the login script's
  # `systemd-run --scope` does.
  DBUS_SESSION_BUS_ADDRESS="unix:path=$user_runtime/bus" busctl --user call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
    org.freedesktop.systemd1.Manager StartTransientUnit 'ssa(sv)a(sa(sv))' \
    "$prefix-wayfire.scope" fail 1 PIDs au 1 "$COMPOSITOR_PID" 0 >/dev/null

  local node quickshell relay
  node="$(readlink -f "$(command -v node)")"
  quickshell="$(readlink -f "$(command -v quickshell)")"
  relay="$DITTO_RUNTIME_DIR/verify-relay.sock"
  local serve=(serve --compositor wayfire --builtin-packages "$packages"
    --shell "quickshell 0.2.0 $quickshell -p $WORKSPACE/shell/shell.qml"
    --hostd "$(g1_hostd_spec "$node" "$WORKSPACE/packages/host-runtime/dist/ditto-hostd.mjs")")
  local core_env=(DITTO_LAUNCH_SCOPE_PREFIX="$prefix" DITTO_SYSTEM=no-logind XDG_CACHE_HOME="$RUNTIME_DIR/cache"
    QT_QPA_PLATFORM=wayland QT_QUICK_BACKEND=software)
  case "$variant" in
    rescue-no-node) serve+=(--mode rescue) ;;
    *) serve+=(--launch "dittoctl 0.2.0 $node $WORKSPACE/tests/g1/lib/relay.mjs $relay") ;;
  esac
  [[ "$variant" == avatar-off ]] && core_env+=(DITTO_AVATAR=off)
  unset DITTO_DEV_TOKEN
  systemd-run --user --scope --quiet --collect --unit="$prefix-core" -- \
    env "${core_env[@]}" "$BINARIES/ditto-core" "${serve[@]}" >"$RUNTIME_DIR/core.log" 2>&1 &
  CORE_PID=$!
  local _ ready=""
  for _ in $(seq 1 300); do
    if grep -aq '"role":"shell"' "$RUNTIME_DIR/core.log" && [[ -S "$DITTO_RUNTIME_DIR/shell.sock" ]]; then ready=1; break; fi
    kill -0 "$CORE_PID" 2>/dev/null || break
    sleep 0.1
  done
  [[ -n "$ready" ]] || { cat "$RUNTIME_DIR/core.log" >&2; echo 'fixture Core or Shell did not come up' >&2; return 1; }
  systemd-run --user --scope --quiet --collect --unit="$prefix-supervisor" -- \
    env DITTO_RUNTIME_DIR="$DITTO_RUNTIME_DIR" "$BINARIES/ditto-supervisor" \
    --shell-scope "$prefix-quickshell.scope" --no-rescue >"$RUNTIME_DIR/supervisor.log" 2>&1 &

  export DITTO_G1_RELAY="$relay" DITTO_MEASURE_LOGIN_ID="fixture-$$-$state-$index" DITTO_MEASURE_LOGIN_EPOCH="$(date +%s)"
  export WAYLAND_DISPLAY="$RUNTIME_DIR/$WAYLAND_DISPLAY"
  local why
  for _ in $(seq 1 300); do
    why="$(cold ready "$state")" && break
    sleep 0.2
  done
  cold ready "$state" >/dev/null || { echo "fixture never became ready for $state: $why" >&2; cat "$RUNTIME_DIR/core.log" >&2; return 1; }
  cold sample "$state"
}

summary=()
for state in "${states[@]}"; do
  for index in 1 2 3; do
    cold prepare "$state"
    status=0
    ( one_login "$state" "$index" ) || status=$?
    stop_units
    (( status == 0 )) || { echo "$state run $index failed ($status)" >&2; exit 1; }
  done
  cold report "$state" | tee "$out/report-$state.txt"
  summary+=("$state: $(grep -o '[^ ]*\.md$' "$out/report-$state.txt" | xargs)")
done
cold reset >/dev/null
printf '%s\n' "development dry run only (not EX1-10 evidence); reports:" "${summary[@]}"

#!/usr/bin/env bash
# Private-bus QML integration. No shared desktop services or VM access.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
evidence="${1:?evidence directory required}"
mkdir -p "$evidence"
export DITTO_NETWORK_TEST_ROOT="$root" DITTO_NETWORK_TEST_EVIDENCE="$evidence"
export QT_PREFIX="${QT_PREFIX:-$HOME/Qt/6.10.2/gcc_64}"
: "${TMPDIR:?set TMPDIR to the task scratch directory}"
bus_config=$(mktemp "$TMPDIR/ditto-network-bus.XXXXXX.conf")
trap 'rm -f "$bus_config"' EXIT
python3 - "$root/tests/g4/network/bus.conf" "$bus_config" "$TMPDIR" <<'PY'
import pathlib, sys, urllib.parse
template = pathlib.Path(sys.argv[1]).read_text()
pathlib.Path(sys.argv[2]).write_text(template.replace('@TMPDIR@', urllib.parse.quote(sys.argv[3], safe='/')))
PY
node "$root/tests/g4/visual/stage-providers.mjs" > "$evidence/staging.log"
dbus-run-session --config-file="$bus_config" -- bash -euo pipefail -c '
    export DBUS_SYSTEM_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS"
    export QT_QPA_PLATFORM=offscreen
    /usr/bin/python3 "$DITTO_NETWORK_TEST_ROOT/tests/g4/network/networkd-fixture.py" \
        "$QT_PREFIX/bin/qmltestrunner" \
        -import "$DITTO_NETWORK_TEST_ROOT/tests/g4/visual/stubs" \
        -input "$DITTO_NETWORK_TEST_ROOT/tests/g4/network/tst_mixed_manager.qml" \
        2>&1 | tee "$DITTO_NETWORK_TEST_EVIDENCE/qml.log"
'

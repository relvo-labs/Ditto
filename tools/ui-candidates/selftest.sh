#!/usr/bin/env bash
# Development self-test of the style files and apply.sh without a session.
# First check-styles.py (the installed session is J1, one title bar, contrast,
# three distinct styles). Then a fake Wayfire IPC server (get/set-config-
# options over the real framing), a fake runtime directory with the
# session.env ditto-session writes (XDG_CONFIG_DIRS with the session's xdg
# directory), a fake systemctl and foot. Checks that j1 → j3 → off ends
# byte-identical (session.env), with Wayfire's values back to what they were
# and the state directory gone, that the preview never sets the Shell's style
# (no DITTO_UI_STYLE: the Profile's choice is the only one), and that nothing
# is written outside the fake runtime directory. This does NOT show that a
# real Wayfire 0.11 accepts the values or redraws; that is the VM run.
#
#   tools/ui-candidates/selftest.sh <scratch-dir>
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch="${1:?scratch directory required}"
work="$scratch/ui-candidates-selftest"
python3 "$here/check-styles.py" --json "$scratch/check-styles.json"
rm -rf -- "$work"
mkdir -p "$work/run/ditto" "$work/bin" "$work/home/.config"
export XDG_RUNTIME_DIR="$work/run" HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config"
export WAYFIRE_SOCKET="$work/run/wayfire.sock"
unset XDG_CONFIG_DIRS || true
session_xdg="$(cd "$here/../.." && pwd)/packaging/reference-image/session/xdg"
printf 'WAYFIRE_SOCKET=%s\n_WAYFIRE_SOCKET=%s\nXDG_CONFIG_DIRS=%s\n' "$WAYFIRE_SOCKET" "$WAYFIRE_SOCKET" "$session_xdg:/etc/xdg" > "$work/run/ditto/session.env"
chmod 0600 "$work/run/ditto/session.env"
cp -p "$work/run/ditto/session.env" "$work/session.env.before"

cat > "$work/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$XDG_RUNTIME_DIR/../systemctl.log"
EOF
cat > "$work/bin/foot" <<'EOF'
#!/usr/bin/env bash
echo "foot $*" >> "$XDG_RUNTIME_DIR/../foot.log"
EOF
chmod +x "$work/bin/systemctl" "$work/bin/foot"
export PATH="$work/bin:$PATH"

# Fake Wayfire: the decoration defaults of the frozen 0.11 metadata.
python3 - "$WAYFIRE_SOCKET" "$work/wayfire-state.json" <<'PYEOF' &
import json, os, socket, struct, sys
path, dump = sys.argv[1:]
options = {"decoration/font": "sans-serif", "decoration/font_color": "#ffffffff", "decoration/font_scale": 0.8,
           "decoration/title_height": 30, "decoration/border_size": 4, "decoration/button_order": "minimize maximize close",
           "decoration/button_scale": 0.7, "decoration/button_padding": 4,
           "decoration/active_color": "#222222aa", "decoration/inactive_color": "#333333dd"}
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen(4)
while True:
    conn, _ = server.accept()
    n = struct.unpack("=I", conn.recv(4))[0]
    data = b""
    while len(data) < n:
        data += conn.recv(n - len(data))
    request = json.loads(data)
    method, body = request["method"], request["data"]
    if method == "wayfire/get-config-option":
        reply = {"value": options[body["option"]], "default": options[body["option"]]} if body["option"] in options else {"error": "no such option"}
    elif method == "wayfire/set-config-options":
        bad = [k for k, v in body.items() if k not in options or not isinstance(v, str)]
        if bad:
            reply = {"error": "rejected " + ",".join(bad)}
        else:
            for key, value in body.items():
                old = options[key]
                options[key] = type(old)(value) if isinstance(old, (int, float)) else value
            reply = {"result": "ok"}
    elif method == "quit":
        conn.close()
        break
    else:
        reply = {"error": "unknown method"}
    json.dump(options, open(dump, "w"), indent=2, sort_keys=True)
    out = json.dumps(reply).encode()
    conn.sendall(struct.pack("=I", len(out)) + out)
    conn.close()
PYEOF
server=$!
trap 'kill $server 2>/dev/null || true' EXIT
for _ in $(seq 50); do [[ -S "$WAYFIRE_SOCKET" ]] && break; sleep 0.1; done
python3 - "$WAYFIRE_SOCKET" <<'PYEOF' > "$work/wayfire-before.json"
import json, socket, struct, sys
keys = ["font", "font_color", "font_scale", "title_height", "border_size", "button_order", "button_scale", "button_padding", "active_color", "inactive_color"]
values = {}
for key in keys:
    s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
    body = json.dumps({"method": "wayfire/get-config-option", "data": {"option": "decoration/" + key}}).encode()
    s.sendall(struct.pack("=I", len(body)) + body)
    n = struct.unpack("=I", s.recv(4))[0]; data = b""
    while len(data) < n: data += s.recv(n - len(data))
    values["decoration/" + key] = json.loads(data)["value"]
print(json.dumps(values, indent=2, sort_keys=True))
PYEOF

fail() { echo "FAIL: $*"; exit 1; }
find "$work" -path "$work/run" -prune -o -type f -print | sort > "$work/files-before.txt"

bash "$here/apply.sh" j1 --restart-core
! grep -q 'DITTO_UI_STYLE' "$XDG_RUNTIME_DIR/ditto/session.env" || fail "the preview must not set the Shell's style"
grep -qx "XDG_CONFIG_DIRS=$XDG_RUNTIME_DIR/ditto/ui-candidate/xdg:$session_xdg:/etc/xdg" "$XDG_RUNTIME_DIR/ditto/session.env" || fail "XDG_CONFIG_DIRS"
[[ -f "$XDG_RUNTIME_DIR/ditto/ui-candidate/xdg/foot/foot.ini" ]] || fail "foot.ini"
grep -q '^\[decoration\]' "$XDG_RUNTIME_DIR/ditto/ui-candidate/wayfire.ini" || fail "merged ini"
grep -q '^title_height = 34' "$XDG_RUNTIME_DIR/ditto/ui-candidate/wayfire.ini" || fail "merged values"
[[ "$(grep -c '^\[decoration\]' "$XDG_RUNTIME_DIR/ditto/ui-candidate/wayfire.ini")" == 1 ]] || fail "one decoration section"
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); assert s["decoration/title_height"]==34 and s["decoration/active_color"]=="#e9e4fbff", s' "$work/wayfire-state.json" || fail "live j1"

bash "$here/apply.sh" j3
[[ "$(grep -c '^# >>> ditto-ui-candidate' "$XDG_RUNTIME_DIR/ditto/session.env")" == 1 ]] || fail "one managed block after switching"
[[ "$(grep -c '^XDG_CONFIG_DIRS=' "$XDG_RUNTIME_DIR/ditto/session.env")" == 2 ]] || fail "the session's line and one preview line"
cmp "$XDG_RUNTIME_DIR/ditto/ui-candidate/xdg/foot/foot.ini" "$here/../../packaging/reference-image/session/styles/j3/foot.ini" || fail "j3 foot.ini"
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); assert s["decoration/active_color"]=="#dfecf8ff", s' "$work/wayfire-state.json" || fail "live j3"
bash "$here/apply.sh" status > "$work/status.txt"; grep -q 'preview: j3' "$work/status.txt" || fail "status"

bash "$here/apply.sh" off --restart-core
cmp "$work/session.env.before" "$XDG_RUNTIME_DIR/ditto/session.env" || fail "session.env not restored byte for byte"
[[ "$(stat -c %a "$XDG_RUNTIME_DIR/ditto/session.env")" == 600 ]] || fail "session.env mode"
[[ ! -e "$XDG_RUNTIME_DIR/ditto/ui-candidate" ]] || fail "state directory left behind"
python3 - "$work/wayfire-before.json" "$work/wayfire-state.json" <<'PYEOF' || fail "Wayfire values not restored"
import json, sys
before, after = (json.load(open(p)) for p in sys.argv[1:])
assert before == after, (before, after)
PYEOF
bash "$here/apply.sh" off > "$work/off2.txt"; grep -q 'no style preview applied' "$work/off2.txt" || fail "second off is a no-op"
bash "$here/apply.sh" status > "$work/status.txt"; grep -q 'preview: none' "$work/status.txt" || fail "status none"
# Outside the fake runtime directory only this test's own records may change.
ignore='/(systemctl|foot)\.log$|/wayfire-state\.json$|/(status|off2)\.txt$|/files-(before|after)\.txt$'
find "$work" -path "$work/run" -prune -o -type f -print | sort | grep -v -E "$ignore" > "$work/files-after.txt"
diff <(grep -v -E "$ignore" "$work/files-before.txt") "$work/files-after.txt" || fail "files written outside the runtime directory"
[[ -z "$(ls -A "$XDG_CONFIG_HOME")" ]] || fail "XDG_CONFIG_HOME touched"
grep -c 'restart ditto-core.service' "$work/systemctl.log" | grep -qx 2 || fail "core restarts"
grep -q -- '--check-config' "$work/foot.log" || fail "foot --check-config"
python3 - "$WAYFIRE_SOCKET" <<'PYEOF'
import json, socket, struct, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
body = json.dumps({"method": "quit", "data": {}}).encode(); s.sendall(struct.pack("=I", len(body)) + body)
PYEOF
echo "PASS: j1 → j3 → off restores session.env byte for byte and Wayfire's values; no Shell style set; nothing outside \$XDG_RUNTIME_DIR"

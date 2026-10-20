#!/usr/bin/env bash
# #116 style preview for what the Shell does not draw: Wayfire's server-side
# title bars and foot, on a logged-in development machine or VM ("Ditto
# (Wayfire)" session). Development tool.
#
#   tools/ui-candidates/apply.sh j1|j2|j3 [--restart-core]
#   tools/ui-candidates/apply.sh off [--restart-core]
#   tools/ui-candidates/apply.sh status
#
# The Shell's own windows follow the style chosen in personalization (the
# Profile token appearance.tokens.ui_style, J1 by default; also
# `dittoctl appearance set token.ui_style=j2`). This tool does not touch the
# Profile or the Shell, so it cannot override that choice. The installed
# session already uses J1 for title bars and foot (session/wayfire.ini
# [decoration], session/xdg/foot/foot.ini); `j2`/`j3` preview the others until
# the session follows the chosen style itself (component-sheet §8, follow-up).
#
# What `j1|j2|j3` does (and the only places it writes):
#   1. $XDG_RUNTIME_DIR/ditto/ui-candidate/  (session-only; gone at logout)
#        wayfire.ini            the session wayfire.ini with this style's
#                               [decoration] in place (for inspection or a
#                               manual `wayfire --config` run; the running
#                               session keeps its own --config file)
#        xdg/foot/foot.ini      the style's foot config
#        saved-decoration.json  Wayfire's decoration values before the first apply
#        session.env.orig       the session.env before the first apply
#        style                  the applied style
#   2. Wayfire, live: the [decoration] options through its IPC socket
#      (`wayfire/set-config-options`). They last until Wayfire restarts or
#      reloads its config file. A title bar already drawn may keep its old
#      text colour until its title changes or the window is opened again
#      (seen on the VM, 2026-10-20).
#   3. $XDG_RUNTIME_DIR/ditto/session.env (written by ditto-session at every
#      login; ditto-core.service reads it at start): a marked block with
#      XDG_CONFIG_DIRS=<state>/xdg:<the session's own>. Core passes its
#      environment to applications it launches, so a foot started from the
#      Dock or launcher sees the style after Core restarts (`--restart-core`,
#      or `systemctl --user restart ditto-core.service`; open windows stay).
# Nothing is written to XDG_CONFIG_HOME, the repository, /etc, the Profile or
# the installed session. A person's own ~/.config/foot/foot.ini still wins
# (foot reads XDG_CONFIG_HOME before XDG_CONFIG_DIRS).
#
# `off` undoes exactly that: Wayfire's saved values are set back, session.env
# is restored byte for byte from session.env.orig, and the state directory is
# removed. Logging out also ends everything except a still-running Wayfire's
# live values, which end with it.
#
# Limits: foot started by Wayfire's Super+Enter binding keeps Wayfire's
# environment (the session's J1), so it does not see a preview; start foot
# from the Dock or launcher, or run
#   foot -c "$XDG_RUNTIME_DIR/ditto/ui-candidate/xdg/foot/foot.ini".
# Wayfire 0.11's decoration buttons keep their compiled-in hover colours.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
styles="$root/packaging/reference-image/session/styles"
session_ini="${DITTO_UI_SESSION_INI:-$root/packaging/reference-image/session/wayfire.ini}"
runtime="${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is not set: run this inside the logged-in session}"
state="$runtime/ditto/ui-candidate"
session_env="$runtime/ditto/session.env"
socket="${WAYFIRE_SOCKET:-${_WAYFIRE_SOCKET:-$runtime/ditto-wayfire-ipc.sock}}"
python="${DITTO_UI_PYTHON:-python3}"
begin='# >>> ditto-ui-candidate (tools/ui-candidates/apply.sh; remove with `apply.sh off`)'
end='# <<< ditto-ui-candidate'

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[[ $# -ge 1 ]] || usage
action="$1"; shift
restart_core=""
for arg in "$@"; do
  case "$arg" in
    --restart-core) restart_core=1 ;;
    *) usage ;;
  esac
done

# Wayfire IPC (4-byte native length + JSON, both ways), as tools/compositor-probe.
ipc() { # ipc get <option>... | ipc set <json-object>
  "$python" - "$socket" "$@" <<'PYEOF'
import json, socket, struct, sys
path, verb, *args = sys.argv[1:]
def call(method, data):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect(path)
    body = json.dumps({"method": method, "data": data}).encode()
    s.sendall(struct.pack("=I", len(body)) + body)
    head = b""
    while len(head) < 4:
        chunk = s.recv(4 - len(head))
        if not chunk:
            raise SystemExit(f"{method}: connection closed")
        head += chunk
    n = struct.unpack("=I", head)[0]
    data = b""
    while len(data) < n:
        chunk = s.recv(n - len(data))
        if not chunk:
            raise SystemExit(f"{method}: connection closed")
        data += chunk
    reply = json.loads(data)
    if reply.get("result") not in (None, "ok") or "error" in reply:
        raise SystemExit(f"{method}: {json.dumps(reply)}")
    return reply
def text(value):
    # Options are set as their config-file text.
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, list):
        return " ".join(text(v) for v in value)
    return str(value)
if verb == "get":
    saved = {}
    for option in args:
        reply = call("wayfire/get-config-option", {"option": option})
        if "value" not in reply:
            raise SystemExit(f"get-config-option {option}: no value in {json.dumps(reply)}")
        saved[option] = text(reply["value"])
    print(json.dumps(saved, indent=2))
elif verb == "set":
    values = json.loads(args[0])
    call("wayfire/set-config-options", values)
    print(f"set {len(values)} Wayfire option(s)")
PYEOF
}

# The [decoration] section of a candidate as {"decoration/<key>": "<value>"}.
decoration_json() {
  "$python" - "$1" <<'PYEOF'
import configparser, json, sys
parser = configparser.ConfigParser(interpolation=None, inline_comment_prefixes=None)
parser.optionxform = str
parser.read(sys.argv[1], encoding="utf-8")
print(json.dumps({f"decoration/{k}": v for k, v in parser["decoration"].items()}))
PYEOF
}

# The session wayfire.ini with the candidate's [decoration] in place of any
# existing one; every other line is kept as it is.
merge_ini() { # <session.ini> <candidate.ini> <out>
  "$python" - "$@" <<'PYEOF'
import re, sys
session, candidate, out = sys.argv[1:]
def section(lines, name):
    start = next((i for i, l in enumerate(lines) if l.strip() == f"[{name}]"), None)
    if start is None:
        return None, None
    stop = next((i for i in range(start + 1, len(lines)) if re.match(r"\s*\[", lines[i])), len(lines))
    return start, stop
base = open(session, encoding="utf-8").read().splitlines()
cand = open(candidate, encoding="utf-8").read().splitlines()
c0, c1 = section(cand, "decoration")
block = ["# merged by tools/ui-candidates/apply.sh from " + candidate] + [l for l in cand[c0:c1] if l.strip() and not l.lstrip().startswith("#")]
s0, s1 = section(base, "decoration")
merged = base[:s0] + block + base[s1:] if s0 is not None else base + [""] + block
open(out, "w", encoding="utf-8").write("\n".join(merged) + "\n")
PYEOF
}

restart() {
  if [[ -n "$restart_core" ]]; then
    systemctl --user restart ditto-core.service
    echo "restarted ditto-core.service (Shell relaunched; open windows stay)"
  else
    echo "next: systemctl --user restart ditto-core.service   (or rerun with --restart-core)"
  fi
}

case "$action" in
  j1|j2|j3)
    deco="$styles/$action/wayfire-decoration.ini"
    foot_ini="$styles/$action/foot.ini"
    [[ -r "$deco" && -r "$foot_ini" ]] || { echo "missing style files under $styles/$action" >&2; exit 1; }
    [[ -S "$socket" ]] || { echo "no Wayfire IPC socket at $socket (WAYFIRE_SOCKET)" >&2; exit 1; }
    [[ -f "$session_env" ]] || { echo "no $session_env: is this a Ditto (Wayfire) login?" >&2; exit 1; }
    if command -v foot >/dev/null 2>&1; then
      foot --check-config --config="$foot_ini" || { echo "foot rejects $foot_ini" >&2; exit 1; }
    else
      echo "foot not found: foot.ini installed without --check-config" >&2
    fi
    values="$(decoration_json "$deco")"
    install -d -m 0700 "$state" "$state/xdg/foot"
    # The originals are taken once, before the first preview; switching
    # styles keeps them, so `off` always returns to the session's own.
    if [[ ! -f "$state/saved-decoration.json" ]]; then
      mapfile -t keys < <("$python" -c 'import json,sys; print("\n".join(json.loads(sys.argv[1])))' "$values")
      ipc get "${keys[@]}" > "$state/saved-decoration.json.tmp"
      mv "$state/saved-decoration.json.tmp" "$state/saved-decoration.json"
      cp -p "$session_env" "$state/session.env.orig"
    fi
    merge_ini "$session_ini" "$deco" "$state/wayfire.ini"
    install -m 0600 "$foot_ini" "$state/xdg/foot/foot.ini"
    ipc set "$values"
    previous_dirs="$(sed -n 's/^XDG_CONFIG_DIRS=//p' "$state/session.env.orig" | tail -n 1)"
    [[ -n "$previous_dirs" ]] || previous_dirs="${XDG_CONFIG_DIRS:-/etc/xdg}"
    {
      cat "$state/session.env.orig"
      echo "$begin"
      echo "XDG_CONFIG_DIRS=$state/xdg:$previous_dirs"
      echo "$end"
    } > "$session_env.tmp"
    chmod 0600 "$session_env.tmp"
    mv "$session_env.tmp" "$session_env"
    echo "$action" > "$state/style"
    echo "previewing $action: Wayfire decoration (live), foot.ini at $state/xdg/foot/foot.ini (XDG_CONFIG_DIRS in $session_env)"
    echo "the Shell's windows follow personalization: dittoctl appearance set token.ui_style=$action"
    restart
    ;;
  off)
    if [[ ! -d "$state" ]]; then
      echo "no style preview applied (no $state)"
      exit 0
    fi
    if [[ -f "$state/saved-decoration.json" ]]; then
      if [[ -S "$socket" ]]; then
        ipc set "$(cat "$state/saved-decoration.json")"
      else
        echo "no Wayfire IPC socket: the decoration ends with this Wayfire anyway" >&2
      fi
    fi
    if [[ -f "$state/session.env.orig" ]]; then
      cp -p "$state/session.env.orig" "$session_env"
    fi
    rm -rf -- "$state"
    echo "restored: Wayfire decoration values, $session_env; removed $state"
    restart
    ;;
  status)
    if [[ -f "$state/style" ]]; then
      echo "preview: $(cat "$state/style")"
      awk -v b="$begin" -v e="$end" '$0 == b { p = 1 } p { print } $0 == e { p = 0 }' "$session_env"
    else
      echo "preview: none (the session's own: J1)"
    fi
    ;;
  *)
    usage
    ;;
esac

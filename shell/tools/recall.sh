#!/usr/bin/env bash
# Send one control line to the running shell. `recall` brings the character
# back when an application covers it; `workspace <id>` switches workspaces
# through the shell's own capability path. Bind these to keys in the compositor
# configuration; G0 only needs the path to exist.
set -euo pipefail
socket="${DITTO_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/tmp}/ditto}/shell.sock"
command="${*:-recall}"
python3 -c "
import socket, sys
connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
connection.connect(sys.argv[1])
connection.sendall((sys.argv[2] + '\n').encode())
" "$socket" "$command"

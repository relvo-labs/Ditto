#!/usr/bin/env python3
"""An application with unsaved work, for the shell-restart check.

The reference machine uses the frozen editor from the support matrix. This
stand-in exists so the check can run where that editor is not installed: it
holds its content only in memory and answers with the content hash, so a lost
or restarted process is visible as a changed or missing answer.
"""

import hashlib
import os
import socket
import sys

path = sys.argv[1]
content = sys.argv[2].encode("utf-8")
digest = hashlib.sha256(content).hexdigest()

if os.path.exists(path):
    os.unlink(path)
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen(8)
print(f"unsaved buffer ready {digest}", flush=True)
while True:
    connection, _ = server.accept()
    with connection:
        connection.sendall(digest.encode("ascii") + b"\n")

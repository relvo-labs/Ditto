#!/usr/bin/env python3
"""Minimal Wayfire IPC client for the functional probe.

Wayfire has no sway-compatible IPC. Its `ipc` plugin speaks a 4-byte native
endian length header followed by one JSON object, in both directions, so the
probe needs this where it would otherwise call `swaymsg`. The client prints the
raw response and picks nothing: the caller decides which fields it needs, and a
field this compositor does not report stays missing rather than being filled in
with a guess.
"""

import argparse
import json
import os
import socket
import struct
import sys

HEADER = struct.Struct("=I")


def socket_path() -> str:
    path = os.environ.get("WAYFIRE_SOCKET") or os.environ.get("_WAYFIRE_SOCKET")
    if not path:
        raise SystemExit("WAYFIRE_SOCKET is not set; the ipc plugin must be loaded")
    return path


def receive_exactly(client: socket.socket, size: int) -> bytes:
    chunks = []
    remaining = size
    while remaining:
        chunk = client.recv(remaining)
        if not chunk:
            raise SystemExit("the compositor closed the IPC connection")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def call(method: str, data: dict) -> object:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.connect(socket_path())
        payload = json.dumps({"method": method, "data": data}).encode("utf-8")
        client.sendall(HEADER.pack(len(payload)) + payload)
        length = HEADER.unpack(receive_exactly(client, HEADER.size))[0]
        return json.loads(receive_exactly(client, length))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("method", help="IPC method, for example window-rules/list-views")
    parser.add_argument("data", nargs="?", default="{}", help="JSON object sent as the method data")
    arguments = parser.parse_args()
    response = call(arguments.method, json.loads(arguments.data))
    json.dump(response, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

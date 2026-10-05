"""Persistent-connection Wayfire IPC client for the G1 probes.

The G0 client (`functional/wayfire-ipc.py`) opens one connection per request,
which cannot observe what only a live connection sees: IPC events after
`window-rules/events/watch`, and `command-binding` events for bindings whose
lifetime is the registering client. Framing is the same: a 4-byte native
endian length header followed by one JSON object, in both directions.
"""

import json
import os
import select
import socket
import struct
import time

HEADER = struct.Struct("=I")


def socket_path() -> str:
    path = os.environ.get("WAYFIRE_SOCKET") or os.environ.get("_WAYFIRE_SOCKET")
    if not path:
        raise SystemExit("WAYFIRE_SOCKET is not set; the ipc plugin must be loaded")
    return path


class Client:
    def __init__(self, path: str | None = None):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path or socket_path())
        self.buffer = b""
        # Events that arrived while a call waited for its reply, in order.
        self.pending: list[dict] = []

    def close(self) -> None:
        self.sock.close()

    def _read_message(self, timeout: float | None) -> dict | None:
        deadline = None if timeout is None else time.monotonic() + timeout
        while True:
            if len(self.buffer) >= HEADER.size:
                length = HEADER.unpack(self.buffer[: HEADER.size])[0]
                if len(self.buffer) >= HEADER.size + length:
                    body = self.buffer[HEADER.size : HEADER.size + length]
                    self.buffer = self.buffer[HEADER.size + length :]
                    return json.loads(body)
            remaining = None if deadline is None else max(0.0, deadline - time.monotonic())
            if remaining == 0.0:
                return None
            ready, _, _ = select.select([self.sock], [], [], remaining)
            if not ready:
                return None
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("the compositor closed the IPC connection")
            self.buffer += chunk

    def call(self, method: str, data: dict | None = None, timeout: float = 5.0) -> dict:
        payload = json.dumps({"method": method, "data": data or {}}).encode("utf-8")
        self.sock.sendall(HEADER.pack(len(payload)) + payload)
        while True:
            message = self._read_message(timeout)
            if message is None:
                raise TimeoutError(f"no reply to {method} within {timeout} s")
            # Replies carry no "event" key; everything else is an event.
            if isinstance(message, dict) and "event" in message:
                self.pending.append(message)
                continue
            return message

    def events(self, duration: float) -> list[dict]:
        """Drain events that arrive within `duration` seconds."""
        collected, self.pending = self.pending, []
        deadline = time.monotonic() + duration
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return collected
            message = self._read_message(remaining)
            if message is None:
                return collected
            collected.append(message)


def call(method: str, data: dict | None = None) -> dict:
    client = Client()
    try:
        return client.call(method, data)
    finally:
        client.close()


def press(client: Client, *keys: str) -> None:
    """Press keys in order, release in reverse: a chord through stipc."""
    for key in keys:
        client.call("stipc/feed_key", {"key": key, "state": True})
    for key in reversed(keys):
        client.call("stipc/feed_key", {"key": key, "state": False})

"""Frontend side of the backend protocol (runs as the unprivileged frontend user)."""

import json
import socket
import time

from . import protocol

SOCKET = "/run/ditto-installer/backend.sock"


class ConnectionLost(RuntimeError):
    pass


class Client:
    def __init__(self, path=SOCKET, *, connect_timeout=180.0, sleep=time.sleep, clock=time.monotonic):
        self.path = str(path)
        self.connect_timeout = connect_timeout
        self._sleep, self._clock = sleep, clock
        self._socket = None
        self._reader = None

    def connect(self):
        deadline = self._clock() + self.connect_timeout
        while True:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
            try:
                sock.connect(self.path)
            except OSError:
                sock.close()
                if self._clock() >= deadline:
                    raise ConnectionLost("backend unavailable") from None
                self._sleep(0.5)
                continue
            self._socket, self._reader = sock, sock.makefile("rb")
            return self

    def close(self):
        if self._socket is not None:
            self._reader.close()
            self._socket.close()
            self._socket = self._reader = None

    def request(self, action, **fields):
        if self._socket is None:
            self.connect()
        try:
            self._socket.sendall(protocol.request_line(action, **fields))
            line = self._reader.readline(protocol.MAX_RESPONSE + 1)
        except OSError as error:
            self.close()
            raise ConnectionLost(str(error)) from error
        if not line or not line.endswith(b"\n"):
            self.close()
            raise ConnectionLost("backend closed the connection")
        return json.loads(line)

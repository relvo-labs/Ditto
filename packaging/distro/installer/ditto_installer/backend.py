"""Root backend: owns the session, the medium and the only write path.

The frontend runs as a fixed unprivileged user. Every connection is checked
with SO_PEERCRED against that UID before any request is read; the protocol
only carries fixed actions and opaque tokens (see protocol.py).
"""

from dataclasses import asdict
import os
from pathlib import Path
import socket
import stat
import struct
import threading

from . import protocol
from .session import CONFIRMING, INSTALLING, Session, SessionError

STARTING, SEARCHING, READY = "starting", "searching", "ready"


def disk_view(disk):
    return {"name": disk.name, "model": disk.model, "vendor": disk.vendor, "serial": disk.serial,
            "size_bytes": disk.size_bytes, "removable": disk.removable, "read_only": disk.read_only}


class Backend:
    def __init__(self, prepare_fn, reboot_fn, *, token_factory=None):
        """prepare_fn() -> (enumerate_fn, install_fn); install_fn(disk, cancel_check, progress).

        prepare_fn may raise any error with a .code (medium/manifest); that code is
        then reported as the medium state and only 'state'/'reboot' are served.
        """
        self._prepare_fn = prepare_fn
        self._reboot = reboot_fn
        self._token_factory = token_factory
        self._lock = threading.Lock()
        self.medium = SEARCHING
        self.session = None
        self._progress = {"stage": None, "done": 0, "total": 0}
        self._worker = None
        self.rebooting = False

    # -- medium -------------------------------------------------------------
    def prepare(self):
        try:
            enumerate_fn, install_fn = self._prepare_fn()
        except Exception as error:  # noqa: BLE001 - any failure means no medium, never a guess
            code = getattr(error, "code", None)
            with self._lock:
                self.medium = code if isinstance(code, str) else "medium_unavailable"
            return
        kwargs = {"token_factory": self._token_factory} if self._token_factory else {}

        def install(disk, cancel_check):
            return install_fn(disk, cancel_check, self._set_progress)
        with self._lock:
            self.session = Session(enumerate_fn, install, **kwargs)
            self.medium = READY

    def start(self):
        thread = threading.Thread(target=self.prepare, name="ditto-installer-medium", daemon=True)
        thread.start()
        return thread

    def _set_progress(self, stage, done, total):
        with self._lock:
            self._progress = {"stage": stage, "done": int(done), "total": int(total)}

    # -- requests -----------------------------------------------------------
    def snapshot(self):
        with self._lock:
            session = self.session
            progress = dict(self._progress)
            medium = self.medium
        result = session.result if session else None
        return {"ok": True, "medium": medium, "state": session.state if session else STARTING,
                "notice": session.notice if session else None, "progress": progress,
                "result": asdict(result) if result else None, "rebooting": self.rebooting}

    def handle(self, request):
        action = request["action"]
        if action == "state":
            return self.snapshot()
        if action == "reboot":
            return self._reboot_action()
        session = self.session
        if session is None:
            return {"ok": False, "error": "medium_not_ready" if self.medium == SEARCHING else self.medium}
        try:
            if action == "list":
                offers = session.list_disks()
                return {"ok": True, "disks": [dict(disk_view(o.candidate.disk), token=o.token,
                                                   reasons=list(o.candidate.reasons)) for o in offers]}
            if action == "select":
                confirmation = session.select(request["token"])
                return {"ok": True, "confirm_token": confirmation.token, "disk": disk_view(confirmation.disk)}
            if action == "back":
                session.back()
                return {"ok": True}
            if action == "confirm":
                return self._confirm(session, request["token"])
            if action == "cancel":
                if session.state == CONFIRMING:
                    session.back()
                    return {"ok": True, "state": session.state}
                session.request_cancel()
                return {"ok": True, "state": INSTALLING}
        except SessionError as error:
            return {"ok": False, "error": error.code}
        return {"ok": False, "error": "invalid_request"}

    def _confirm(self, session, token):
        with self._lock:
            if self._worker is not None and self._worker.is_alive():
                return {"ok": False, "error": "busy"}
            disk = session.begin(token)
            if disk is None:
                return {"ok": False, "error": "disk_changed"}
            self._progress = {"stage": "verify", "done": 0, "total": 0}
            self._worker = threading.Thread(target=session.run, args=(disk,), name="ditto-installer-write",
                                            daemon=False)
            self._worker.start()
        return {"ok": True, "state": INSTALLING}

    def _reboot_action(self):
        with self._lock:
            if self.session is not None and self.session.state == INSTALLING:
                return {"ok": False, "error": "busy"}
            if self._worker is not None and self._worker.is_alive():
                return {"ok": False, "error": "busy"}
            self.rebooting = True
        self._reboot()
        return {"ok": True}

    def wait(self, timeout=None):
        worker = self._worker
        if worker is not None:
            worker.join(timeout)


# -- socket server ---------------------------------------------------------
def peer_uid(connection):
    _pid, uid, _gid = struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED,
                                                                struct.calcsize("3i")))
    return uid


def handle_connection(connection, backend, allowed_uid):
    try:
        _handle_connection(connection, backend, allowed_uid)
    except OSError:
        pass  # peer went away; backend state is unaffected


def _handle_connection(connection, backend, allowed_uid):
    with connection:
        if peer_uid(connection) != allowed_uid:
            # Nothing from this peer is read or acted upon.
            connection.sendall(protocol.encode({"ok": False, "error": "peer_rejected"}))
            return
        reader = connection.makefile("rb")
        while True:
            line = reader.readline(protocol.MAX_REQUEST + 1)
            if not line:
                return
            try:
                request = protocol.parse_request(line)
            except protocol.ProtocolError as error:
                connection.sendall(protocol.encode({"ok": False, "error": error.code}))
                if len(line) > protocol.MAX_REQUEST or not line.endswith(b"\n"):
                    return  # framing lost: drop the connection
                continue
            connection.sendall(protocol.encode(backend.handle(request)))


def listen(path, *, socket_gid=None):
    path = Path(path)
    try:
        if stat.S_ISSOCK(path.lstat().st_mode):
            path.unlink()
    except FileNotFoundError:
        pass
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
    old_umask = os.umask(0o117)
    try:
        server.bind(str(path))
    finally:
        os.umask(old_umask)
    if socket_gid is not None:
        os.chown(path, 0, socket_gid)
    os.chmod(path, 0o660)
    server.listen(4)
    return server


def serve(server, backend, allowed_uid, stop=None):
    server.settimeout(0.2)
    while stop is None or not stop.is_set():
        try:
            connection, _ = server.accept()
        except TimeoutError:
            continue
        connection.settimeout(None)
        threading.Thread(target=handle_connection, args=(connection, backend, allowed_uid),
                         daemon=True).start()

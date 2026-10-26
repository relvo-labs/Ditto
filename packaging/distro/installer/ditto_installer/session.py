"""Installer state machine; the backend is the only authority over the target.

Frontends only send: list, select(disk token), confirm(confirm token),
cancel, and read state. Tokens are random, per listing / per confirmation
screen, single use. The disk is re-enumerated and compared with the snapshot
shown on the confirmation screen (including the kernel diskseq) here, and the
writer compares it again against the opened descriptor before the first write.

Cancel while installing goes through the attempt's CancelGate: accepted before
the GPT commit boundary, refused with "committing" once the commit has started.
"""

from dataclasses import dataclass
import secrets
import threading

from .writer import CancelGate, Result

LISTING, CONFIRMING, INSTALLING, SUCCEEDED, FAILED, CANCELLED = (
    "listing", "confirming", "installing", "succeeded", "failed", "cancelled")


class SessionError(RuntimeError):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


@dataclass(frozen=True)
class Offer:
    token: str | None    # None for disks that cannot be selected
    candidate: object    # disks.Candidate


@dataclass(frozen=True)
class Confirmation:
    token: str
    disk: object         # disks.Disk snapshot shown to the user


class Session:
    def __init__(self, enumerate_fn, install_fn, token_factory=lambda: secrets.token_hex(16)):
        """enumerate_fn() -> [Candidate]; install_fn(disk, gate) -> writer.Result.

        gate is a writer.CancelGate: callable as cancel_check, and gate.enter_commit
        must be handed to the writer as its commit boundary.
        """
        self._enumerate = enumerate_fn
        self._install = install_fn
        self._token = token_factory
        self._lock = threading.Lock()
        self._gate = None
        self.state = LISTING
        self._offers = {}
        self._confirmation = None
        self.result = None
        self.notice = None   # e.g. "disk_changed" after returning to the list

    def list_disks(self):
        """Also the way back after a failed or cancelled attempt; never after success."""
        with self._lock:
            if self.state not in (LISTING, CONFIRMING, FAILED, CANCELLED):
                raise SessionError("busy")
            self.state, self._confirmation, self.result = LISTING, None, None
            offers, self._offers = [], {}
            for candidate in self._enumerate():
                token = self._token() if candidate.eligible else None
                if token is not None:
                    self._offers[token] = candidate.disk
                offers.append(Offer(token, candidate))
            return offers

    def select(self, token):
        with self._lock:
            if self.state != LISTING:
                raise SessionError("not_listing")
            disk = self._offers.pop(token, None) if isinstance(token, str) else None
            if disk is None:
                raise SessionError("unknown_disk")
            self._offers.clear()
            self._confirmation = Confirmation(self._token(), disk)
            self.state, self.notice = CONFIRMING, None
            return self._confirmation

    def back(self):
        """Second-confirmation screen 'cancel': return to the list, nothing written."""
        with self._lock:
            if self.state != CONFIRMING:
                raise SessionError("not_confirming")
            self.state, self._confirmation = LISTING, None

    def begin(self, token):
        """Check the token and the disk again; on success the session is INSTALLING.

        Returns the confirmed disk, or None (state LISTING, notice disk_changed).
        There is no confirmed-but-not-started state: the caller must run() next.
        """
        with self._lock:
            pending = self._confirmation
            if self.state != CONFIRMING or pending is None:
                raise SessionError("not_confirming")
            if not isinstance(token, str) or not secrets.compare_digest(token, pending.token):
                raise SessionError("bad_confirmation")
            self._confirmation = None   # single use
            current = {c.disk.name: c for c in self._enumerate()}
            now = current.get(pending.disk.name)
            if now is None or not now.eligible or now.disk.identity() != pending.disk.identity():
                self.state, self.notice = LISTING, "disk_changed"
                return None
            self.state = INSTALLING
            self._gate = CancelGate()   # one per attempt; cancel is possible from here on
            return pending.disk

    def confirm(self, token):
        disk = self.begin(token)
        return None if disk is None else self.run(disk)

    def run(self, disk):
        with self._lock:
            if self.state != INSTALLING:
                raise SessionError("not_installing")
            gate = self._gate
        try:
            result = self._install(disk, gate)
        except Exception:  # noqa: BLE001 - an escaping writer bug must not look like success
            result = None
        with self._lock:
            if not isinstance(result, Result):
                result = Result("failed", "done", "internal_error", "unknown")
            if result.outcome == "succeeded" and gate():
                # Unreachable with a writer that honours enter_commit; never report both.
                result = Result("failed", result.stage, "internal_error", "unknown")
            self.result = result
            self.state = {"succeeded": SUCCEEDED, "cancelled": CANCELLED}.get(result.outcome, FAILED)
            return result

    def request_cancel(self):
        """Callable from another thread while installing.

        Accepted: the writer stops at its next check and never writes the GPT.
        Raises SessionError("committing") once the commit boundary was entered.
        """
        with self._lock:
            if self.state != INSTALLING:
                raise SessionError("not_installing")
            if not self._gate.request_cancel():
                raise SessionError("committing")

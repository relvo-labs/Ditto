"""Write a verified payload to one confirmed target and prove it by reading back.

Order (the GPT is the commit point, written last):
  1. hash every payload file (nothing written yet)
  2. plan the layout, open the target O_EXCL, then bind the OPEN descriptor to
     the confirmed disk: its own diskseq/devnum/size and the sysfs identity and
     eligibility of that devnum must equal what the user confirmed
  3. zero the old partition tables (head/tail 1 MiB)  -> disk is no longer untouched
  4. stream each partition image to its offset, checking raw length and SHA256
  5. read every written region back and compare its SHA256
  6. enter the commit boundary, write a fresh GPT (random GUIDs) and parse it back
Only when all six hold is the outcome "succeeded". A failure or cancellation
after step 3 leaves no new partition table, so the disk does not boot.

Cancellation and the commit boundary are decided under one lock (CancelGate):
a cancel accepted before the boundary always ends "cancelled" with no GPT
written; once the boundary is entered every cancel request is refused, so an
accepted cancel and "succeeded" can never both be reported.
"""

from dataclasses import dataclass
import errno
import fcntl
import hashlib
import mmap
import os
import stat
import struct
import subprocess
import threading
import uuid

from . import MIB, SECTOR, gpt
from .layout import LayoutError, plan
from .manifest import ManifestError, _read_regular, payload_path, verify_payloads

CHUNK = 4 * MIB
BLKGETSIZE64 = 0x80081272
BLKFLSBUF = 0x1261
BLKRRPART = 0x125F
BLKGETDISKSEQ = 0x80081280   # _IOR(0x12, 128, __u64), Linux >= 5.15


class CancelGate:
    """Single decision point between 'cancel accepted' and 'commit started'.

    Calling the gate answers "was a cancel accepted?" (the writer's cancel_check).
    request_cancel() and enter_commit() take the same lock, so exactly one wins.
    """

    def __init__(self):
        self._lock = threading.Lock()
        self._cancelled = False
        self._committing = False

    def __call__(self):
        with self._lock:
            return self._cancelled

    @property
    def committing(self):
        with self._lock:
            return self._committing

    def request_cancel(self):
        """True: accepted, the write will stop without a GPT. False: too late, commit has started."""
        with self._lock:
            if self._committing:
                return False
            self._cancelled = True
            return True

    def enter_commit(self):
        """True: no cancel was accepted and none will be from now on. False: stop as cancelled."""
        with self._lock:
            if self._cancelled:
                return False
            self._committing = True
            return True


@dataclass(frozen=True)
class Result:
    outcome: str        # succeeded | failed | cancelled
    stage: str          # verify | preflight | wipe | write | readback | commit | done
    code: str
    disk_state: str     # untouched | partially_written | installed
    detail: str = ""


class _Stop(Exception):
    def __init__(self, outcome, code, detail=""):
        super().__init__(code)
        self.outcome, self.code, self.detail = outcome, code, detail


def _pwrite_all(fd, data, offset):
    view = memoryview(data)
    while view:
        written = os.pwrite(fd, view, offset)
        if written <= 0:
            raise OSError(errno.EIO, "short write")
        view, offset = view[written:], offset + written


def _read_region(path, offset, length, direct):
    """SHA256 of [offset, offset+length) read through a fresh descriptor."""
    flags = os.O_RDONLY | os.O_CLOEXEC | (os.O_DIRECT if direct else 0)
    fd = os.open(path, flags)
    buffer = mmap.mmap(-1, CHUNK)  # page aligned, as O_DIRECT requires
    try:
        digest = hashlib.sha256()
        while length:
            size = min(CHUNK, length)
            view = memoryview(buffer)[:size]
            if os.preadv(fd, [view], offset) != size:
                raise OSError(errno.EIO, "short read")
            digest.update(view)
            view.release()
            offset, length = offset + size, length - size
        return digest.hexdigest()
    finally:
        buffer.close()
        os.close(fd)


class _Decoder:
    """Decoder input is an already opened, fstat-checked regular file; zstd never gets a path."""

    def __init__(self, path, codec, zstd_command):
        self.process = None
        self.source, _ = _read_regular(path)
        if codec == "none":
            self.stream = self.source
        else:
            try:
                self.process = subprocess.Popen([*zstd_command, "-q", "-d", "-c"], stdin=self.source,
                                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            except BaseException:
                self.source.close()
                raise
            self.stream = self.process.stdout

    def read(self, size):
        return self.stream.read(size)

    def close(self, ok):
        self.stream.close()
        self.source.close()
        if self.process is None:
            return True
        if not ok:
            self.process.kill()
        try:
            code = self.process.wait(timeout=60)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            return False
        return ok and code == 0


def open_target(path, *, allow_regular_file=False):
    """Never creates; O_EXCL makes the kernel refuse a mounted/claimed block device."""
    fd = os.open(path, os.O_RDWR | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW)
    info = os.fstat(fd)
    if stat.S_ISBLK(info.st_mode) or (allow_regular_file and stat.S_ISREG(info.st_mode)):
        return fd, info
    os.close(fd)
    raise OSError(errno.EINVAL, "target is not a block device")


def _fd_identity(fd, info, disk):
    """(devnum, diskseq, size) of the object the descriptor holds.

    A block device answers for itself (st_rdev, BLKGETDISKSEQ, BLKGETSIZE64).
    A regular file is only allowed by the tests' allow_regular_file flag; it has
    no device identity, so the confirmed devnum stands in and diskseq is None.
    """
    if stat.S_ISBLK(info.st_mode):
        devnum = f"{os.major(info.st_rdev)}:{os.minor(info.st_rdev)}"
        diskseq = struct.unpack("<Q", fcntl.ioctl(fd, BLKGETDISKSEQ, b"\0" * 8))[0]
        size = struct.unpack("<Q", fcntl.ioctl(fd, BLKGETSIZE64, b"\0" * 8))[0]
        return devnum, diskseq, size
    return disk.devnum, None, info.st_size


def _bind_target(fd, info, disk, recheck):
    """Raise _Stop unless the open descriptor is the confirmed, still eligible disk.

    The fd's own diskseq binds the descriptor to the confirmed kernel disk; the
    sysfs entry looked up by its devnum must carry the same diskseq too, so even
    a reused major:minor cannot pass for the confirmed disk.
    """
    try:
        devnum, diskseq, size = _fd_identity(fd, info, disk)
    except OSError as error:
        raise _Stop("failed", "target_changed", "descriptor identity unreadable") from error
    if devnum != disk.devnum:
        raise _Stop("failed", "target_changed", "device number")
    if diskseq is not None and diskseq != disk.diskseq:
        raise _Stop("failed", "target_changed", "diskseq")
    if size != disk.size_bytes:
        raise _Stop("failed", "target_changed", "size")
    try:
        current = recheck(devnum)
    except Exception as error:  # noqa: BLE001 - an unreadable identity is never a match
        raise _Stop("failed", "target_changed", "identity unreadable") from error
    if current is None:
        raise _Stop("failed", "target_changed", "disk gone")
    if current.disk.identity() != disk.identity():
        raise _Stop("failed", "target_changed", "identity")
    if not current.eligible:
        raise _Stop("failed", "target_changed", "not eligible: " + ",".join(current.reasons))


def install(manifest, payload_dir, target, disk, *, recheck, allow_regular_file=False,
            cancel_check=lambda: False, enter_commit=None, progress=lambda *_: None, guid_factory=uuid.uuid4,
            zstd_command=("zstd",)):
    """recheck(devnum) -> disks.Candidate | None, freshly enumerated (identity and eligibility).

    enter_commit() -> bool decides the commit boundary; pass CancelGate.enter_commit
    whenever cancel_check can change from another thread.
    """
    if enter_commit is None:
        def enter_commit():
            return not cancel_check()
    state = {"stage": "verify", "touched": False}

    def stop_if_cancelled():
        if cancel_check():
            raise _Stop("cancelled", "cancelled")

    def result(outcome, code, detail=""):
        disk_state = "installed" if outcome == "succeeded" else (
            "partially_written" if state["touched"] else "untouched")
        return Result(outcome, state["stage"], code, disk_state, detail)

    fd = None
    try:
        try:
            if not verify_payloads(manifest, payload_dir, cancel_check=cancel_check, progress=progress):
                raise _Stop("cancelled", "cancelled")
        except ManifestError as error:
            raise _Stop("failed", error.code, str(error)) from error
        state["stage"] = "preflight"
        try:
            layout = plan(manifest, disk.size_bytes)
        except LayoutError as error:
            raise _Stop("failed", error.code) from error
        try:
            fd, info = open_target(target, allow_regular_file=allow_regular_file)
        except OSError as error:
            raise _Stop("failed", "target_unusable", errno.errorcode.get(error.errno, "")) from error
        block = stat.S_ISBLK(info.st_mode)
        stop_if_cancelled()
        # Last check before the first destructive write: nothing slow runs in between.
        _bind_target(fd, info, disk, recheck)

        state["stage"] = "wipe"
        state["touched"] = True
        zeros = bytes(MIB)
        try:
            _pwrite_all(fd, zeros, 0)
            _pwrite_all(fd, zeros, disk.size_bytes - MIB)
        except OSError as error:
            raise _Stop("failed", "write_error", errno.errorcode.get(error.errno, "")) from error

        state["stage"] = "write"
        total = sum(p.spec.payload.raw_bytes for p in layout.placements if p.spec.payload)
        done = 0
        for placement in layout.placements:
            payload = placement.spec.payload
            if payload is None:
                # Spare slot: clear stale signatures at both ends, carry no data.
                head = min(MIB, placement.size_bytes)
                try:
                    _pwrite_all(fd, bytes(head), placement.start_bytes)
                    _pwrite_all(fd, bytes(head), placement.start_bytes + placement.size_bytes - head)
                except OSError as error:
                    raise _Stop("failed", "write_error", errno.errorcode.get(error.errno, "")) from error
                continue
            try:
                decoder = _Decoder(payload_path(payload_dir, payload), payload.codec, zstd_command)
            except ManifestError as error:
                raise _Stop("failed", error.code, payload.file) from error
            except OSError as error:
                raise _Stop("failed", "decompress_failed", errno.errorcode.get(error.errno, "")) from error
            ok = False
            try:
                digest, written = hashlib.sha256(), 0
                while chunk := decoder.read(CHUNK):
                    stop_if_cancelled()
                    if written + len(chunk) > payload.raw_bytes:
                        # Never spill into the next partition.
                        raise _Stop("failed", "payload_length_mismatch", payload.file)
                    try:
                        _pwrite_all(fd, chunk, placement.start_bytes + written)
                    except OSError as error:
                        raise _Stop("failed", "write_error", errno.errorcode.get(error.errno, "")) from error
                    digest.update(chunk)
                    written += len(chunk)
                    done += len(chunk)
                    progress("write", done, total)
                ok = True
            finally:
                clean = decoder.close(ok)
            if not clean:
                raise _Stop("failed", "decompress_failed", payload.file)
            if written != payload.raw_bytes:
                raise _Stop("failed", "payload_length_mismatch", payload.file)
            if digest.hexdigest() != payload.raw_sha256:
                raise _Stop("failed", "payload_hash_mismatch", payload.file)

        state["stage"] = "readback"
        try:
            os.fsync(fd)
            if block:
                fcntl.ioctl(fd, BLKFLSBUF)
            else:
                os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
        except OSError as error:
            raise _Stop("failed", "write_error", errno.errorcode.get(error.errno, "")) from error
        for placement in layout.placements:
            payload = placement.spec.payload
            if payload is None:
                continue
            stop_if_cancelled()
            try:
                # Reopen the very object held under O_EXCL, never re-resolve the path.
                actual = _read_region(f"/proc/self/fd/{fd}", placement.start_bytes, payload.raw_bytes, block)
            except OSError as error:
                raise _Stop("failed", "read_error", errno.errorcode.get(error.errno, "")) from error
            if actual != payload.raw_sha256:
                raise _Stop("failed", "readback_mismatch", payload.file)
        if not enter_commit():
            raise _Stop("cancelled", "cancelled")

        # Past the boundary: cancel requests are refused, the outcome is the commit's.
        state["stage"] = "commit"
        progress("commit", total, total)
        disk_guid = str(guid_factory()).upper()
        intended = tuple(gpt.Partition(p.spec.number, p.spec.type_guid, str(guid_factory()).upper(),
                                       p.first_lba, p.last_lba, p.spec.attributes, p.spec.name)
                         for p in layout.placements)
        try:
            for offset, data in gpt.build(disk.size_bytes, disk_guid, intended):
                _pwrite_all(fd, data, offset)
            os.fsync(fd)
            if block:
                fcntl.ioctl(fd, BLKFLSBUF)
            else:
                os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
            table = gpt.read(gpt.file_reader(fd), disk.size_bytes)
        except (OSError, gpt.GptError) as error:
            raise _Stop("failed", "commit_failed", type(error).__name__) from error
        if table.disk_guid != disk_guid or table.partitions != intended:
            raise _Stop("failed", "commit_failed", "partition table readback differs")
        if block:
            try:
                fcntl.ioctl(fd, BLKRRPART)
            except OSError:
                pass  # Kernel view refreshes on reboot; on-disk table is already verified.
        state["stage"] = "done"
        progress("done", total, total)
        return result("succeeded", "ok")
    except _Stop as stop:
        return result(stop.outcome, stop.code, stop.detail)
    finally:
        if fd is not None:
            os.close(fd)

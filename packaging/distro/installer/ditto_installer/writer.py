"""Write a verified payload to one confirmed target and prove it by reading back.

Order (the GPT is the commit point, written last):
  1. hash every payload file (nothing written yet)
  2. plan the layout, open the target O_EXCL and re-check its identity
  3. zero the old partition tables (head/tail 1 MiB)  -> disk is no longer untouched
  4. stream each partition image to its offset, checking raw length and SHA256
  5. read every written region back and compare its SHA256
  6. write a fresh GPT (random disk/partition GUIDs) and parse it back
Only when all six hold is the outcome "succeeded". A failure or cancellation
after step 3 leaves no new partition table, so the disk does not boot.
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
import uuid

from . import MIB, SECTOR, gpt
from .layout import LayoutError, plan
from .manifest import ManifestError, _read_regular, payload_path, verify_payloads

CHUNK = 4 * MIB
BLKGETSIZE64 = 0x80081272
BLKFLSBUF = 0x1261
BLKRRPART = 0x125F


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


def _target_size(fd, info):
    if stat.S_ISBLK(info.st_mode):
        return struct.unpack("<Q", fcntl.ioctl(fd, BLKGETSIZE64, b"\0" * 8))[0]
    return info.st_size


def install(manifest, payload_dir, target, disk, *, allow_regular_file=False,
            cancel_check=lambda: False, progress=lambda *_: None, guid_factory=uuid.uuid4,
            zstd_command=("zstd",)):
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
        if block and f"{os.major(info.st_rdev)}:{os.minor(info.st_rdev)}" != disk.devnum:
            raise _Stop("failed", "target_changed", "device number")
        if _target_size(fd, info) != disk.size_bytes:
            raise _Stop("failed", "target_changed", "size")
        stop_if_cancelled()

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
        stop_if_cancelled()

        state["stage"] = "commit"
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

"""Enumerate whole disks from sysfs and decide which ones may be offered.

All inputs are injectable (sysfs root, mountinfo, swaps, medium devnums) so
tests run on task-owned fake trees. Model/vendor/serial strings come from the
device and are treated as display data only: sanitised, never interpreted.
"""

from dataclasses import dataclass
import os
from pathlib import Path
import re

VIRTUAL = re.compile(r"(?:loop|ram|zram|dm-|md|sr|nbd|fd|mtdblock|zd)[0-9]*|mmcblk[0-9]+(?:boot[0-9]+|rpmb)")
NAME = re.compile(r"[a-z][a-z0-9]{0,31}")
DEVNUM = re.compile(r"[0-9]{1,10}:[0-9]{1,10}")
DISPLAY_LIMIT = 64

# Reason codes, in the order they are reported.
REASONS = ("install_medium", "in_use", "read_only", "removable", "unsupported_sector_size",
           "too_small", "unreadable")


@dataclass(frozen=True)
class Disk:
    name: str
    devnum: str
    size_bytes: int
    logical_block_size: int
    model: str
    vendor: str
    serial: str
    removable: bool
    read_only: bool

    def identity(self):
        """Everything shown to the user plus what binds the node; compared before writing."""
        return (self.name, self.devnum, self.size_bytes, self.logical_block_size, self.model,
                self.vendor, self.serial, self.removable, self.read_only)


@dataclass(frozen=True)
class Candidate:
    disk: Disk
    reasons: tuple

    @property
    def eligible(self):
        return not self.reasons


def _attr(path, limit=4096):
    try:
        with open(path, "rb") as stream:
            return stream.read(limit)
    except OSError:
        return None


def _text(path):
    data = _attr(path)
    return None if data is None else data.decode("utf-8", "replace").strip()


def display(value):
    """Printable, single-line, bounded display text from device-provided bytes."""
    if not value:
        return ""
    text = "".join(ch if ch.isprintable() else " " for ch in value)
    return " ".join(text.split())[:DISPLAY_LIMIT]


def _vpd_serial(data):
    # SCSI VPD page 0x80: byte 1 page code, bytes 2-3 length, then ASCII serial.
    if not data or len(data) < 4 or data[1] != 0x80:
        return ""
    length = int.from_bytes(data[2:4], "big")
    return data[4:4 + length].decode("ascii", "replace")


def _serial(block):
    for rel in ("serial", "device/serial"):
        value = _text(block / rel)
        if value:
            return value
    return _vpd_serial(_attr(block / "device/vpd_pg80"))


def _int(text):
    return int(text) if text is not None and re.fullmatch(r"[0-9]{1,20}", text) else None


@dataclass(frozen=True)
class _Scan:
    disk: Disk | None
    name: str
    partitions: tuple      # devnums of partitions
    busy_holders: bool
    unreadable: bool


def _scan_block(block):
    name = block.name
    devnum = _text(block / "dev")
    sectors = _int(_text(block / "size"))
    lbs = _int(_text(block / "queue/logical_block_size"))
    removable = _text(block / "removable")
    read_only = _text(block / "ro")
    partitions, busy = [], any((block / "holders").glob("*"))
    for child in sorted(block.iterdir()):
        if (child / "partition").is_file():
            part_dev = _text(child / "dev")
            if part_dev and DEVNUM.fullmatch(part_dev):
                partitions.append(part_dev)
            busy = busy or any((child / "holders").glob("*"))
    if (devnum is None or not DEVNUM.fullmatch(devnum) or sectors is None or lbs is None or
            removable not in ("0", "1") or read_only not in ("0", "1")):
        return _Scan(None, name, tuple(partitions), busy, True)
    disk = Disk(name, devnum, sectors * 512, lbs, display(_text(block / "device/model")),
                display(_text(block / "device/vendor")), display(_serial(block)),
                removable == "1", read_only == "1")
    return _Scan(disk, name, tuple(partitions), busy, False)


def mounted_devnums(mountinfo_text):
    used = set()
    for line in mountinfo_text.splitlines():
        fields = line.split()
        if len(fields) > 2 and DEVNUM.fullmatch(fields[2]):
            used.add(fields[2])
    return used


def swap_names(swaps_text):
    names = set()
    for line in swaps_text.splitlines()[1:]:
        fields = line.split()
        if fields and fields[0].startswith("/dev/"):
            names.add(os.path.basename(fields[0]))
    return names


def devnum_of_path(path):
    """major:minor of the file system holding path (used for the install medium)."""
    info = os.stat(path)
    return f"{os.major(info.st_dev)}:{os.minor(info.st_dev)}"


def enumerate_disks(sysfs, *, mountinfo="", swaps="", medium_devnums=(), min_bytes=0):
    """Return Candidates for every physical whole disk, eligible or not."""
    block_root = Path(sysfs) / "block"
    used = mounted_devnums(mountinfo)
    swapped = swap_names(swaps)
    medium = set(medium_devnums)
    candidates = []
    for block in sorted(block_root.iterdir()) if block_root.is_dir() else ():
        name = block.name
        if not NAME.fullmatch(name) or VIRTUAL.fullmatch(name) or not (block / "device").exists():
            continue
        scan = _scan_block(block)
        if scan.disk is None:
            # Unreadable metadata is never offered, but still reported.
            disk = Disk(name, "", 0, 0, "", "", "", False, True)
            candidates.append(Candidate(disk, ("unreadable",)))
            continue
        disk = scan.disk
        devnums = {disk.devnum, *scan.partitions}
        part_names = {child.name for child in block.iterdir() if (child / "partition").is_file()}
        reasons = []
        if devnums & medium:
            reasons.append("install_medium")
        if devnums & used or scan.busy_holders or ({name} | part_names) & swapped:
            reasons.append("in_use")
        if disk.read_only:
            reasons.append("read_only")
        if disk.removable:
            reasons.append("removable")
        if disk.logical_block_size != 512:
            reasons.append("unsupported_sector_size")
        if disk.size_bytes < min_bytes or disk.size_bytes == 0:
            reasons.append("too_small")
        candidates.append(Candidate(disk, tuple(r for r in REASONS if r in reasons)))
    return candidates

"""Target layout: the image's partitions in the same order, state filling the disk.

systemd-repart cannot grow ditto-state on first boot because the /usr slots
follow it; repart only grows a partition into free space directly behind it.
The installer therefore sizes ditto-state here, writes the 8 GiB file system
image at its start, and the image's fstab growfs entry extends ext4 on boot.
"""

from dataclasses import dataclass

from . import MIB, SECTOR
from .gpt import ENTRIES_SECTORS

# Backup GPT: entries plus header at the end of the disk.
TAIL_BYTES = (ENTRIES_SECTORS + 1) * SECTOR


class LayoutError(ValueError):
    def __init__(self, code, detail=""):
        super().__init__(f"{code}: {detail}" if detail else code)
        self.code = code


@dataclass(frozen=True)
class Placement:
    spec: object          # manifest.PartitionSpec
    start_bytes: int
    size_bytes: int

    @property
    def first_lba(self):
        return self.start_bytes // SECTOR

    @property
    def last_lba(self):
        return (self.start_bytes + self.size_bytes) // SECTOR - 1


@dataclass(frozen=True)
class Layout:
    disk_bytes: int
    placements: tuple


def minimum_disk_bytes(manifest):
    last = manifest.partitions[-1]
    return last.start_bytes + last.size_bytes + TAIL_BYTES


def plan(manifest, disk_bytes):
    if disk_bytes % SECTOR:
        raise LayoutError("target_unusable", "size is not a multiple of 512 bytes")
    if disk_bytes < minimum_disk_bytes(manifest):
        raise LayoutError("target_too_small")
    usable_end = disk_bytes - TAIL_BYTES
    parts = manifest.partitions
    state_index = next(i for i, p in enumerate(parts) if p.role == "state")
    state_start = parts[state_index].start_bytes
    after = sum(p.size_bytes for p in parts[state_index + 1:])
    state_size = (usable_end - state_start - after) // MIB * MIB
    if state_size < parts[state_index].size_bytes:
        raise LayoutError("target_too_small")
    placements = []
    cursor = None
    for index, part in enumerate(parts):
        if index <= state_index:
            start = part.start_bytes
        else:
            start = cursor
        size = state_size if index == state_index else part.size_bytes
        placements.append(Placement(part, start, size))
        cursor = start + size
    if cursor > usable_end:
        raise LayoutError("target_too_small")
    return Layout(disk_bytes, tuple(placements))

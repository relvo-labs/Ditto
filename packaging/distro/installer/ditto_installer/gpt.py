"""Minimal GPT (UEFI 2.10 §5.3) reader/writer for 512-byte logical sectors.

Kept in-process so the installer writes the table through the same exclusive
file descriptor it used for the payload; no second program has to open a
device the installer holds with O_EXCL. Tests cross-check output with sfdisk.
"""

from dataclasses import dataclass
import struct
import uuid
import zlib

from . import SECTOR

SIGNATURE = b"EFI PART"
REVISION = 0x00010000
HEADER = struct.Struct("<8sIIIIQQQQ16sQIII")  # 92 bytes
ENTRY = struct.Struct("<16s16sQQQ72s")        # 128 bytes
ENTRY_COUNT = 128
ENTRIES_SECTORS = ENTRY_COUNT * ENTRY.size // SECTOR  # 32
MAX_ENTRY_COUNT = 1024


class GptError(ValueError):
    """The table is absent, malformed or fails a CRC/consistency check."""


@dataclass(frozen=True)
class Partition:
    number: int          # 1-based entry index
    type_guid: str       # upper-case canonical form
    unique_guid: str
    first_lba: int
    last_lba: int        # inclusive
    attributes: int
    name: str

    @property
    def start_bytes(self):
        return self.first_lba * SECTOR

    @property
    def size_bytes(self):
        return (self.last_lba - self.first_lba + 1) * SECTOR


@dataclass(frozen=True)
class Table:
    disk_guid: str
    first_usable_lba: int
    last_usable_lba: int
    partitions: tuple


def _guid(raw):
    return str(uuid.UUID(bytes_le=raw)).upper()


def _encode_name(name):
    data = name.encode("utf-16-le")
    if len(data) > 72:
        raise GptError("partition name longer than 36 UTF-16 code units")
    return data.ljust(72, b"\0")


def protective_mbr(total_sectors):
    mbr = bytearray(SECTOR)
    size = min(total_sectors - 1, 0xFFFFFFFF)
    mbr[446:462] = struct.pack("<B3sB3sII", 0x00, b"\x00\x02\x00", 0xEE, b"\xff\xff\xff", 1, size)
    mbr[510:512] = b"\x55\xaa"
    return bytes(mbr)


def build(total_bytes, disk_guid, partitions):
    """Return [(offset, bytes), ...] for MBR, primary and backup GPT.

    partitions: iterable of Partition (number = entry index, 1-based).
    """
    if total_bytes % SECTOR:
        raise GptError("disk size is not a multiple of 512 bytes")
    total_sectors = total_bytes // SECTOR
    last_lba = total_sectors - 1
    first_usable = 2 + ENTRIES_SECTORS
    last_usable = last_lba - 1 - ENTRIES_SECTORS
    if last_usable < first_usable:
        raise GptError("disk too small for a GPT")
    entries = bytearray(ENTRY_COUNT * ENTRY.size)
    seen = set()
    previous_end = first_usable - 1
    for part in sorted(partitions, key=lambda p: p.first_lba):
        if not 1 <= part.number <= ENTRY_COUNT or part.number in seen:
            raise GptError("invalid or duplicate partition number")
        if not (previous_end < part.first_lba <= part.last_lba <= last_usable):
            raise GptError("partition outside usable area or overlapping")
        seen.add(part.number)
        previous_end = part.last_lba
        ENTRY.pack_into(entries, (part.number - 1) * ENTRY.size,
                        uuid.UUID(part.type_guid).bytes_le, uuid.UUID(part.unique_guid).bytes_le,
                        part.first_lba, part.last_lba, part.attributes, _encode_name(part.name))
    entries = bytes(entries)
    entries_crc = zlib.crc32(entries)
    guid = uuid.UUID(disk_guid).bytes_le

    def header(current, backup, entries_lba):
        fields = [SIGNATURE, REVISION, HEADER.size, 0, 0, current, backup,
                  first_usable, last_usable, guid, entries_lba, ENTRY_COUNT, ENTRY.size, entries_crc]
        crc = zlib.crc32(HEADER.pack(*fields))
        fields[3] = crc
        return HEADER.pack(*fields).ljust(SECTOR, b"\0")

    backup_entries_lba = last_lba - ENTRIES_SECTORS
    return [(0, protective_mbr(total_sectors)),
            (SECTOR, header(1, last_lba, 2)),
            (2 * SECTOR, entries),
            (backup_entries_lba * SECTOR, entries),
            (last_lba * SECTOR, header(last_lba, 1, backup_entries_lba))]


def _parse_header(sector, expected_lba):
    if len(sector) < HEADER.size:
        raise GptError("short GPT header")
    fields = list(HEADER.unpack_from(sector))
    (signature, revision, size, crc, _reserved, current, backup, first, last, guid,
     entries_lba, count, entry_size, entries_crc) = fields
    if signature != SIGNATURE or revision != REVISION or size != HEADER.size:
        raise GptError("no GPT header")
    fields[3] = 0
    if zlib.crc32(HEADER.pack(*fields)) != crc:
        raise GptError("GPT header CRC mismatch")
    if current != expected_lba or entry_size != ENTRY.size or not 1 <= count <= MAX_ENTRY_COUNT:
        raise GptError("unexpected GPT header geometry")
    return {"backup": backup, "first": first, "last": last, "guid": guid,
            "entries_lba": entries_lba, "count": count, "entries_crc": entries_crc}


def _read(reader, offset, size):
    data = reader(offset, size)
    if len(data) != size:
        raise GptError("short read")
    return data


def read(reader, total_bytes, *, require_backup=True):
    """Parse a GPT through reader(offset, size) -> bytes; verify both copies."""
    if total_bytes % SECTOR or total_bytes < 68 * SECTOR:
        raise GptError("disk size unsuitable for GPT")
    last_lba = total_bytes // SECTOR - 1
    primary = _parse_header(_read(reader, SECTOR, SECTOR), 1)
    if primary["backup"] != last_lba:
        raise GptError("backup GPT location does not match the disk size")
    span = primary["count"] * ENTRY.size
    entries = _read(reader, primary["entries_lba"] * SECTOR, span)
    if zlib.crc32(entries) != primary["entries_crc"]:
        raise GptError("GPT entries CRC mismatch")
    if require_backup:
        backup = _parse_header(_read(reader, last_lba * SECTOR, SECTOR), last_lba)
        if (backup["guid"], backup["first"], backup["last"], backup["count"], backup["entries_crc"]) != (
                primary["guid"], primary["first"], primary["last"], primary["count"], primary["entries_crc"]):
            raise GptError("primary and backup GPT differ")
        if _read(reader, backup["entries_lba"] * SECTOR, span) != entries:
            raise GptError("backup GPT entries differ")
    partitions = []
    for index in range(primary["count"]):
        type_raw, unique_raw, first, last, attributes, name = ENTRY.unpack_from(entries, index * ENTRY.size)
        if type_raw == b"\0" * 16:
            continue
        if not primary["first"] <= first <= last <= primary["last"]:
            raise GptError("partition outside the usable area")
        try:
            text = name.decode("utf-16-le").split("\0", 1)[0]
        except UnicodeError as error:
            raise GptError("partition name is not UTF-16") from error
        partitions.append(Partition(index + 1, _guid(type_raw), _guid(unique_raw), first, last,
                                    attributes, text))
    return Table(_guid(primary["guid"]), primary["first"], primary["last"], tuple(partitions))


def file_reader(fd):
    import os

    def reader(offset, size):
        return os.pread(fd, size, offset)
    return reader

"""Payload manifest: strict parsing and pre-write verification.

The installer image embeds the SHA256 of the manifest bytes it was assembled
with; the medium's manifest must match it before anything else is trusted.
That is an integrity binding between installer and payload on one medium, not
a signature. Every payload file is hashed in full before the first disk write.
"""

from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import stat

from . import MIB, SECTOR

SCHEMA = 1
MAX_MANIFEST_BYTES = 1024 * 1024
TYPE_GUIDS = {
    "esp": "C12A7328-F81F-11D2-BA4B-00A0C93EC93B",
    "state": "4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709",  # root, x86-64
    "usr": "8484680C-9521-48C6-9C11-B0720656F69E",    # /usr, x86-64
    "spare": "8484680C-9521-48C6-9C11-B0720656F69E",
}
ROLE_ORDER = ("esp", "state", "usr", "spare")
CODECS = ("zstd", "none")
HEX64 = re.compile(r"[0-9a-f]{64}")
NAME = re.compile(r"[A-Za-z0-9_.-]{1,36}")
FILE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}")


class ManifestError(ValueError):
    def __init__(self, code, detail=""):
        super().__init__(f"{code}: {detail}" if detail else code)
        self.code = code


@dataclass(frozen=True)
class Payload:
    file: str
    codec: str
    compressed_bytes: int
    compressed_sha256: str
    raw_bytes: int
    raw_sha256: str


@dataclass(frozen=True)
class PartitionSpec:
    number: int
    role: str
    name: str
    type_guid: str
    attributes: int
    start_bytes: int
    size_bytes: int
    payload: Payload | None


@dataclass(frozen=True)
class Manifest:
    image_version: str
    source_commit: str
    disk_sha256: str
    disk_bytes: int
    partitions: tuple
    sha256: str

    def role(self, name):
        return next(p for p in self.partitions if p.role == name)


def _unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result


def _reject_constant(_name):
    raise ValueError("non-finite number")


def _int(value, minimum=0):
    return type(value) is int and value >= minimum


def _payload(raw, size_bytes):
    if not isinstance(raw, dict) or set(raw) != {"file", "codec", "compressed_bytes", "compressed_sha256",
                                                 "raw_bytes", "raw_sha256"}:
        raise ManifestError("manifest_invalid", "payload fields")
    if (not isinstance(raw["file"], str) or not FILE.fullmatch(raw["file"]) or
            raw["codec"] not in CODECS or not _int(raw["compressed_bytes"], 1) or
            not _int(raw["raw_bytes"], 1) or
            not all(isinstance(raw[k], str) and HEX64.fullmatch(raw[k])
                    for k in ("compressed_sha256", "raw_sha256"))):
        raise ManifestError("manifest_invalid", "payload values")
    if raw["raw_bytes"] != size_bytes:
        raise ManifestError("manifest_invalid", "payload must cover the whole partition")
    if raw["codec"] == "none" and (raw["compressed_bytes"], raw["compressed_sha256"]) != (
            raw["raw_bytes"], raw["raw_sha256"]):
        raise ManifestError("manifest_invalid", "uncompressed payload digests differ")
    return Payload(**raw)


def parse(data, expected_sha256):
    """Parse manifest bytes; expected_sha256 comes from the installer image."""
    digest = hashlib.sha256(data).hexdigest()
    if not isinstance(expected_sha256, str) or not HEX64.fullmatch(expected_sha256):
        raise ManifestError("manifest_invalid", "installer carries no valid expected digest")
    if digest != expected_sha256:
        raise ManifestError("manifest_mismatch")
    try:
        raw = json.loads(data.decode("utf-8"), object_pairs_hook=_unique, parse_constant=_reject_constant)
    except (UnicodeError, ValueError, RecursionError) as error:
        raise ManifestError("manifest_invalid", "not strict JSON") from error
    fields = {"schema", "product", "image_version", "source_commit", "disk_sha256", "disk_bytes",
              "sector_size", "partitions"}
    if not isinstance(raw, dict) or set(raw) != fields:
        raise ManifestError("manifest_invalid", "top-level fields")
    if (type(raw["schema"]) is not int or raw["schema"] != SCHEMA or raw["product"] != "ditto" or
            not isinstance(raw["image_version"], str) or
            not re.fullmatch(r"[0-9][A-Za-z0-9.\-]{0,31}", raw["image_version"]) or
            not isinstance(raw["source_commit"], str) or
            not re.fullmatch(r"[0-9a-f]{40}", raw["source_commit"]) or
            not isinstance(raw["disk_sha256"], str) or not HEX64.fullmatch(raw["disk_sha256"]) or
            not _int(raw["disk_bytes"], 1) or raw["disk_bytes"] % SECTOR or
            type(raw["sector_size"]) is not int or raw["sector_size"] != SECTOR or
            not isinstance(raw["partitions"], list)):
        raise ManifestError("manifest_invalid", "top-level values")
    partitions = []
    for number, entry in enumerate(raw["partitions"], 1):
        if not isinstance(entry, dict) or set(entry) != {"number", "role", "name", "type_guid", "attributes",
                                                         "start_bytes", "size_bytes", "payload"}:
            raise ManifestError("manifest_invalid", "partition fields")
        if (type(entry["number"]) is not int or entry["number"] != number or
                entry["role"] not in ROLE_ORDER or
                not isinstance(entry["name"], str) or not NAME.fullmatch(entry["name"]) or
                entry["type_guid"] != TYPE_GUIDS.get(entry["role"]) or
                not _int(entry["attributes"]) or entry["attributes"] >= 1 << 64 or
                not _int(entry["start_bytes"], MIB) or entry["start_bytes"] % MIB or
                not _int(entry["size_bytes"], MIB) or entry["size_bytes"] % MIB):
            raise ManifestError("manifest_invalid", f"partition {number}")
        payload = entry["payload"]
        if (entry["role"] == "spare") != (payload is None):
            raise ManifestError("manifest_invalid", "only the spare slot carries no payload")
        partitions.append(PartitionSpec(entry["number"], entry["role"], entry["name"], entry["type_guid"],
                                        entry["attributes"], entry["start_bytes"], entry["size_bytes"],
                                        None if payload is None else _payload(payload, entry["size_bytes"])))
    roles = [p.role for p in partitions]
    if roles[:3] != ["esp", "state", "usr"] or any(role != "spare" for role in roles[3:]):
        raise ManifestError("manifest_invalid", "partition roles/order")
    if len({p.payload.file for p in partitions if p.payload}) != sum(1 for p in partitions if p.payload):
        raise ManifestError("manifest_invalid", "duplicate payload file")
    end = 0
    for part in partitions:
        if part.start_bytes < max(end, MIB):
            raise ManifestError("manifest_invalid", "partitions overlap or are unordered")
        end = part.start_bytes + part.size_bytes
    if end + 33 * SECTOR > raw["disk_bytes"]:
        raise ManifestError("manifest_invalid", "partitions exceed the source disk")
    return Manifest(raw["image_version"], raw["source_commit"], raw["disk_sha256"], raw["disk_bytes"],
                    tuple(partitions), digest)


def _read_regular(path, limit=None):
    """Open without following a final symlink; reject non-regular files."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as error:
        raise ManifestError("payload_missing", Path(path).name) from error
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise ManifestError("payload_unsafe", Path(path).name)
        if limit is not None and info.st_size > limit:
            raise ManifestError("manifest_invalid", "too large")
        return os.fdopen(fd, "rb"), info.st_size
    except BaseException:
        os.close(fd)
        raise


def load(path, expected_sha256):
    path = Path(path)
    if path.parent.is_symlink():
        raise ManifestError("payload_unsafe", "payload directory")
    stream, _size = _read_regular(path, MAX_MANIFEST_BYTES)
    with stream:
        return parse(stream.read(MAX_MANIFEST_BYTES + 1), expected_sha256)


def payload_path(directory, payload):
    directory = Path(directory)
    if directory.is_symlink() or not directory.is_dir():
        raise ManifestError("payload_unsafe", "payload directory")
    return directory / payload.file


def verify_payloads(manifest, directory, *, cancel_check=lambda: False, progress=lambda *_: None):
    """Hash every payload file completely; raise ManifestError on any defect."""
    total = sum(p.payload.compressed_bytes for p in manifest.partitions if p.payload)
    done = 0
    for part in manifest.partitions:
        if part.payload is None:
            continue
        stream, size = _read_regular(payload_path(directory, part.payload))
        with stream:
            if size != part.payload.compressed_bytes:
                raise ManifestError("payload_size_mismatch", part.payload.file)
            digest = hashlib.sha256()
            while chunk := stream.read(4 * MIB):
                if cancel_check():
                    return False
                digest.update(chunk)
                done += len(chunk)
                progress("verify", done, total)
            if digest.hexdigest() != part.payload.compressed_sha256:
                raise ManifestError("payload_hash_mismatch", part.payload.file)
    return True

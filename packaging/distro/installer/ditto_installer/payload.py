"""Builder side: cut the payload out of the finished whole disk by GPT byte range.

Input is out/ditto.raw AFTER finish-image.sh and the pristine scan, checked
against its disk.sha256. mkosi's split partition artifacts are never used:
finish installs the fallback EFI into the ESP after mkosi wrote them.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

from . import MIB
from .gpt import file_reader, read as read_gpt
from .manifest import SCHEMA, TYPE_GUIDS, parse, verify_payloads

MANIFEST = "payload-manifest.json"
CHUNK = 4 * MIB


class PayloadBuildError(ValueError):
    pass


def role_of(name):
    if name == "ditto-esp":
        return "esp"
    if name == "ditto-state":
        return "state"
    if re.fullmatch(r"ditto-usr-[0-9][A-Za-z0-9.\-]{0,31}", name):
        return "usr"
    if name == "_empty":
        return "spare"
    raise PayloadBuildError(f"unexpected partition label {name!r}")


def _sha256_file(path):
    with open(path, "rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def extract(disk_path, out_dir, *, expected_disk_sha256, image_version, source_commit,
            codec="zstd", zstd_command=("zstd", "-q", "-T0", "-10")):
    out_dir = Path(out_dir)
    if out_dir.exists() or out_dir.is_symlink():
        raise PayloadBuildError("output directory must not exist")
    if codec not in ("zstd", "none"):
        raise PayloadBuildError("unsupported codec")
    if _sha256_file(disk_path) != expected_disk_sha256:
        raise PayloadBuildError("finished disk does not match its recorded SHA256")
    fd = os.open(disk_path, os.O_RDONLY | os.O_CLOEXEC)
    try:
        disk_bytes = os.fstat(fd).st_size
        table = read_gpt(file_reader(fd), disk_bytes)
        parts = sorted(table.partitions, key=lambda p: p.number)
        if [p.number for p in parts] != list(range(1, len(parts) + 1)):
            raise PayloadBuildError("partition numbers are not contiguous from 1")
        out_dir.mkdir(parents=True)
        entries = []
        for part in parts:
            role = role_of(part.name)
            if part.type_guid != TYPE_GUIDS[role]:
                raise PayloadBuildError(f"partition {part.number} type does not match role {role}")
            payload = None
            if role != "spare":
                name = f"p{part.number}-{role}.img" + (".zst" if codec == "zstd" else "")
                payload = _cut(fd, part, out_dir / name, codec, zstd_command)
            entries.append({"number": part.number, "role": role, "name": part.name,
                            "type_guid": part.type_guid, "attributes": part.attributes,
                            "start_bytes": part.start_bytes, "size_bytes": part.size_bytes,
                            "payload": payload})
    finally:
        os.close(fd)
    manifest = {"schema": SCHEMA, "product": "ditto", "image_version": image_version,
                "source_commit": source_commit, "disk_sha256": expected_disk_sha256,
                "disk_bytes": disk_bytes, "sector_size": 512, "partitions": entries}
    data = (json.dumps(manifest, indent=1, sort_keys=True) + "\n").encode()
    (out_dir / MANIFEST).write_bytes(data)
    digest = hashlib.sha256(data).hexdigest()
    # Round trip through the installer's own parser and verifier.
    parsed = parse(data, digest)
    verify_payloads(parsed, out_dir)
    (out_dir / (MANIFEST + ".sha256")).write_text(f"{digest}  {MANIFEST}\n")
    return digest


def _cut(fd, part, path, codec, zstd_command):
    raw = hashlib.sha256()
    offset, remaining = part.start_bytes, part.size_bytes
    with open(path, "xb") as output:
        process = None
        sink = output
        if codec == "zstd":
            process = subprocess.Popen([*zstd_command, "-c", "-"], stdin=subprocess.PIPE, stdout=output)
            sink = process.stdin
        try:
            while remaining:
                chunk = os.pread(fd, min(CHUNK, remaining), offset)
                if not chunk:
                    raise PayloadBuildError("short read from finished disk")
                raw.update(chunk)
                sink.write(chunk)
                offset, remaining = offset + len(chunk), remaining - len(chunk)
        finally:
            if process is not None:
                process.stdin.close()
                if process.wait() != 0:
                    raise PayloadBuildError("zstd failed")
    return {"file": path.name, "codec": codec, "compressed_bytes": path.stat().st_size,
            "compressed_sha256": _sha256_file(path), "raw_bytes": part.size_bytes,
            "raw_sha256": raw.hexdigest()}

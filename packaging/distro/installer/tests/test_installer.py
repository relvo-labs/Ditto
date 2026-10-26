"""Installer core regressions on task-owned regular files and fake sysfs trees only.

No block device, loop device, mount or root privilege is used. Every target is
a sparse regular file under a per-test temporary directory; real sfdisk and
zstd are used only as independent readers/codecs on those files.
"""

import errno
import hashlib
import json
import os
from pathlib import Path
import random
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
INSTALLER = HERE.parent
sys.path.insert(0, str(INSTALLER))

from ditto_installer import MIB, SECTOR, disks, gpt, layout, manifest, messages, payload, session, writer  # noqa: E402

ESP = manifest.TYPE_GUIDS["esp"]
ROOT = manifest.TYPE_GUIDS["state"]
USR = manifest.TYPE_GUIDS["usr"]
GROWFS_BIT = 1 << 59
READ_ONLY_BIT = 1 << 60
COMMIT = "0123456789abcdef0123456789abcdef01234567"
# Small synthetic stand-in for the real 768M ESP + 8G state + 8G usr + 8G spare.
SOURCE_PARTS = (("ditto-esp", ESP, 0, 1, 2), ("ditto-state", ROOT, GROWFS_BIT, 3, 4),
                ("ditto-usr-7", USR, READ_ONLY_BIT, 7, 3), ("_empty", USR, 0, 10, 2))
SOURCE_BYTES = 13 * MIB


def sha(data):
    return hashlib.sha256(data).hexdigest()


def file_sha(path):
    return sha(Path(path).read_bytes())


def need(tool):
    path = shutil.which(tool)
    if path is None:
        raise unittest.SkipTest(f"{tool} not installed")
    return path


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ditto-installer-test-")
        self.root = Path(self.temp.name)
        self.counter = 0

    def tearDown(self):
        self.temp.cleanup()

    def path(self, name):
        self.counter += 1
        return self.root / f"{self.counter:03d}-{name}"

    # -- source disk / payload -------------------------------------------------
    def source_disk(self):
        disk = self.path("ditto.raw")
        rng = random.Random(221)
        with open(disk, "wb") as stream:
            stream.truncate(SOURCE_BYTES)
            parts = []
            for number, (name, type_guid, attrs, start_mib, size_mib) in enumerate(SOURCE_PARTS, 1):
                if name != "_empty":
                    stream.seek(start_mib * MIB)
                    stream.write(rng.randbytes(size_mib * MIB))
                parts.append(gpt.Partition(number, type_guid, f"00000000-0000-4000-8000-00000000000{number}",
                                           start_mib * MIB // SECTOR, (start_mib + size_mib) * MIB // SECTOR - 1,
                                           attrs, name))
            for offset, data in gpt.build(SOURCE_BYTES, "11111111-2222-4333-8444-555555555555", parts):
                stream.seek(offset)
                stream.write(data)
        return disk

    def build_payload(self, codec="zstd"):
        if codec == "zstd":
            need("zstd")
        disk = self.source_disk()
        out = self.path("payload")
        digest = payload.extract(disk, out, expected_disk_sha256=file_sha(disk), image_version="7",
                                 source_commit=COMMIT, codec=codec, zstd_command=("zstd", "-q", "-3"))
        return disk, out, digest

    def load(self, out, digest):
        return manifest.load(out / payload.MANIFEST, digest)

    def rewrite_manifest(self, out, mutate):
        data = json.loads((out / payload.MANIFEST).read_text())
        mutate(data)
        raw = json.dumps(data).encode()
        (out / payload.MANIFEST).write_bytes(raw)
        return sha(raw)

    # -- target ----------------------------------------------------------------
    def target(self, size=40 * MIB):
        target = self.path("target.img")
        with open(target, "wb") as stream:
            stream.truncate(size)
            # Previous owner's data: old table area, a tail and a marker everywhere.
            stream.write(b"OLD-DATA" * (MIB // 8))
            stream.seek(size - MIB)
            stream.write(b"OLD-TAIL" * (MIB // 8))
            for offset in range(MIB, size - MIB, 3 * MIB):
                stream.seek(offset)
                stream.write(b"OLD-MARK" * 512)
        self.assertTrue(str(target).startswith(str(self.root)))
        return target

    def disk_for(self, target, **changes):
        values = dict(name="sdz", devnum="8:240", size_bytes=os.path.getsize(target), logical_block_size=512,
                      model="Task Disk", vendor="ATA", serial="TASK-0001", removable=False, read_only=False)
        values.update(changes)
        return disks.Disk(**values)

    def install(self, man, out, target, **kwargs):
        kwargs.setdefault("allow_regular_file", True)
        disk = kwargs.pop("disk", None) or self.disk_for(target)
        return writer.install(man, out, target, disk, **kwargs)

    def assert_untouched(self, result, target, before):
        self.assertEqual(result.disk_state, "untouched", result)
        self.assertEqual(file_sha(target), before)

    def assert_no_table(self, target):
        size = os.path.getsize(target)
        with open(target, "rb") as stream:
            data = stream.read(2 * SECTOR)
            stream.seek(size - SECTOR)
            tail = stream.read(SECTOR)
        self.assertNotIn(b"EFI PART", data + tail)
        fd = os.open(target, os.O_RDONLY)
        try:
            with self.assertRaises(gpt.GptError):
                gpt.read(gpt.file_reader(fd), size)
        finally:
            os.close(fd)


class GptTests(Fixture):
    def test_round_trip_and_sfdisk_cross_check(self):
        need("sfdisk")
        disk = self.source_disk()
        fd = os.open(disk, os.O_RDONLY)
        try:
            table = gpt.read(gpt.file_reader(fd), SOURCE_BYTES)
        finally:
            os.close(fd)
        self.assertEqual([p.name for p in table.partitions], [p[0] for p in SOURCE_PARTS])
        result = subprocess.run(["sfdisk", "--json", str(disk)], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        info = json.loads(result.stdout)["partitiontable"]
        self.assertEqual((info["label"], info["id"].upper(), info["sectorsize"]),
                         ("gpt", table.disk_guid, 512))
        for part, row in zip(table.partitions, info["partitions"], strict=True):
            self.assertEqual((row["start"], row["size"], row["type"].upper(), row["uuid"].upper(), row["name"]),
                             (part.first_lba, part.last_lba - part.first_lba + 1, part.type_guid,
                              part.unique_guid, part.name))
            expected_attrs = {0: None, GROWFS_BIT: "GUID:59", READ_ONLY_BIT: "GUID:60"}[part.attributes]
            self.assertEqual(row.get("attrs"), expected_attrs)
        verify = subprocess.run(["sfdisk", "--verify", str(disk)], capture_output=True, text=True, timeout=30)
        self.assertEqual(verify.returncode, 0, verify.stdout + verify.stderr)

    def test_corruption_is_rejected(self):
        disk = self.source_disk()
        original = disk.read_bytes()
        cases = {"header": SECTOR + 40, "entries": 2 * SECTOR + 5,
                 "backup-header": SOURCE_BYTES - SECTOR + 40, "backup-entries": SOURCE_BYTES - 33 * SECTOR + 5}
        for name, offset in cases.items():
            with self.subTest(corrupt=name):
                data = bytearray(original)
                data[offset] ^= 0xFF
                disk.write_bytes(data)
                fd = os.open(disk, os.O_RDONLY)
                try:
                    with self.assertRaises(gpt.GptError):
                        gpt.read(gpt.file_reader(fd), SOURCE_BYTES)
                finally:
                    os.close(fd)
        with self.assertRaises(gpt.GptError):
            gpt.build(SOURCE_BYTES, "11111111-2222-4333-8444-555555555555",
                      [gpt.Partition(1, ESP, "00000000-0000-4000-8000-000000000001", 10, 20, 0, "x"),
                       gpt.Partition(2, ESP, "00000000-0000-4000-8000-000000000002", 20, 30, 0, "y")])


class ManifestTests(Fixture):
    def test_extracted_manifest_round_trip(self):
        disk, out, digest = self.build_payload()
        man = self.load(out, digest)
        self.assertEqual([p.role for p in man.partitions], ["esp", "state", "usr", "spare"])
        self.assertIsNone(man.role("spare").payload)
        self.assertEqual(man.role("usr").attributes, READ_ONLY_BIT)
        self.assertEqual(man.disk_sha256, file_sha(disk))
        data = disk.read_bytes()
        for part in man.partitions:
            if part.payload:
                self.assertEqual(part.payload.raw_sha256,
                                 sha(data[part.start_bytes:part.start_bytes + part.size_bytes]))
        self.assertEqual((out / "payload-manifest.json.sha256").read_text().split()[0], digest)
        self.assertEqual(layout.minimum_disk_bytes(man), 12 * MIB + 33 * SECTOR)

    def test_expected_digest_binding(self):
        _, out, digest = self.build_payload()
        with self.assertRaises(manifest.ManifestError) as caught:
            self.load(out, "0" * 64)
        self.assertEqual(caught.exception.code, "manifest_mismatch")
        for bad in (None, "", digest.upper(), digest[:-1]):
            with self.subTest(expected=bad), self.assertRaises(manifest.ManifestError) as caught:
                self.load(out, bad)
            self.assertEqual(caught.exception.code, "manifest_invalid")

    def test_strict_schema_rejections(self):
        _, out, _ = self.build_payload()
        good = json.loads((out / payload.MANIFEST).read_text())

        def part(index, **changes):
            def mutate(data):
                data["partitions"][index].update(changes)
            return mutate

        def pay(index, **changes):
            def mutate(data):
                data["partitions"][index]["payload"].update(changes)
            return mutate

        cases = {
            "schema-2": lambda d: d.update(schema=2), "schema-true": lambda d: d.update(schema=True),
            "extra-key": lambda d: d.update(extra=1), "product": lambda d: d.update(product="other"),
            "sector-4096": lambda d: d.update(sector_size=4096), "commit": lambda d: d.update(source_commit="x"),
            "role-order": lambda d: d["partitions"].reverse(),
            "missing-usr": lambda d: d["partitions"].pop(2),
            "type-mismatch": part(1, type_guid=ESP), "number": part(0, number=2),
            "unaligned": part(1, start_bytes=3 * MIB + SECTOR), "overlap": part(2, start_bytes=5 * MIB),
            "attr-bool": part(0, attributes=True), "attr-huge": part(0, attributes=1 << 64),
            "name-slash": part(0, name="a/b"), "spare-payload": part(3, payload=good["partitions"][0]["payload"]),
            "esp-no-payload": part(0, payload=None),
            "file-slash": pay(0, file="../p1.img.zst"), "file-dot": pay(0, file=".hidden"),
            "dup-file": pay(1, file=good["partitions"][0]["payload"]["file"]),
            "codec": pay(0, codec="gzip"), "raw-not-whole": pay(0, raw_bytes=MIB),
            "digest-upper": pay(0, raw_sha256="A" * 64), "bytes-float": pay(0, compressed_bytes=1.0),
            "exceeds-disk": lambda d: d.update(disk_bytes=12 * MIB),
        }
        for name, mutate in cases.items():
            with self.subTest(case=name):
                data = json.loads(json.dumps(good))
                mutate(data)
                raw = json.dumps(data).encode()
                with self.assertRaises(manifest.ManifestError) as caught:
                    manifest.parse(raw, sha(raw))
                self.assertEqual(caught.exception.code, "manifest_invalid")
        for raw in (b'{"schema": 1, "schema": 1}', b'{"disk_bytes": NaN}', b"\xff", b"[]"):
            with self.subTest(raw=raw), self.assertRaises(manifest.ManifestError):
                manifest.parse(raw, sha(raw))


class LayoutTests(Fixture):
    def test_state_fills_disk_in_image_order(self):
        _, out, digest = self.build_payload()
        man = self.load(out, digest)
        size = 64 * MIB
        planned = layout.plan(man, size)
        placements = planned.placements
        self.assertEqual([p.spec.role for p in placements], ["esp", "state", "usr", "spare"])
        self.assertEqual((placements[0].start_bytes, placements[0].size_bytes), (MIB, 2 * MIB))
        self.assertEqual(placements[1].start_bytes, 3 * MIB)
        for left, right in zip(placements, placements[1:]):
            self.assertEqual(left.start_bytes + left.size_bytes, right.start_bytes)
        for placement in placements:
            self.assertEqual(placement.start_bytes % MIB, 0)
            self.assertEqual(placement.size_bytes % MIB, 0)
        end = placements[-1].start_bytes + placements[-1].size_bytes
        self.assertLessEqual(end, size - layout.TAIL_BYTES)
        self.assertGreater(end + MIB, size - layout.TAIL_BYTES)
        self.assertEqual(placements[1].size_bytes, size // MIB * MIB - MIB - 2 * MIB - 3 * MIB - 2 * MIB - MIB)

    def test_minimum_boundary(self):
        _, out, digest = self.build_payload()
        man = self.load(out, digest)
        minimum = layout.minimum_disk_bytes(man)
        self.assertEqual(layout.plan(man, minimum).placements[1].size_bytes, man.role("state").size_bytes)
        for size, code in ((minimum - SECTOR, "target_too_small"), (MIB, "target_too_small"),
                           (minimum + 1, "target_unusable")):
            with self.subTest(size=size), self.assertRaises(layout.LayoutError) as caught:
                layout.plan(man, size)
            self.assertEqual(caught.exception.code, code)


def make_block(sysfs, name, *, size_bytes=64 << 30, dev="8:0", removable=0, ro=0, lbs=512,
               model="Disk", vendor="ATA", serial=None, serial_at="device/serial", device=True,
               partitions=(), holders=(), part_holders=(), write_size=True):
    block = sysfs / "block" / name
    block.mkdir(parents=True)
    (block / "dev").write_text(dev + "\n")
    if write_size:
        (block / "size").write_text(f"{size_bytes // 512}\n")
    (block / "removable").write_text(f"{removable}\n")
    (block / "ro").write_text(f"{ro}\n")
    (block / "queue").mkdir()
    (block / "queue/logical_block_size").write_text(f"{lbs}\n")
    (block / "holders").mkdir()
    for holder in holders:
        (block / "holders" / holder).mkdir()
    if device:
        (block / "device").mkdir()
        (block / "device/model").write_text(model + "\n")
        (block / "device/vendor").write_text(vendor + "\n")
    if serial is not None:
        path = block / serial_at
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(serial if isinstance(serial, bytes) else (serial + "\n").encode())
    for index, part_dev in enumerate(partitions, 1):
        part = block / f"{name}{'p' if name[-1].isdigit() else ''}{index}"
        part.mkdir()
        (part / "partition").write_text(f"{index}\n")
        (part / "dev").write_text(part_dev + "\n")
        (part / "holders").mkdir()
        if index == 1:
            for holder in part_holders:
                (part / "holders" / holder).mkdir()
    return block


class DiskTests(Fixture):
    def fake_sysfs(self):
        sysfs = self.path("sys")
        make_block(sysfs, "sda", dev="8:0", model="Samsung SSD 870", serial=b"\x00\x80\x00\x08S5SUNG01",
                   serial_at="device/vpd_pg80", partitions=("8:1", "8:2"))
        make_block(sysfs, "sdb", dev="8:16", model="USB Stick", partitions=("8:17",))
        make_block(sysfs, "sdc", dev="8:32", removable=1)
        make_block(sysfs, "sdd", dev="8:48", ro=1)
        make_block(sysfs, "nvme0n1", dev="259:0", model="WD SN770\x1b[31m" + "x" * 100, serial="NVME-1",
                   partitions=("259:1",))
        make_block(sysfs, "vda", dev="252:0", size_bytes=8 << 30, serial="VIRT-1", serial_at="serial")
        make_block(sysfs, "sde", dev="8:64", partitions=("8:65",), part_holders=("dm-0",))
        make_block(sysfs, "sdf", dev="8:80", lbs=4096)
        make_block(sysfs, "sdh", dev="8:112", partitions=("8:113",))
        make_block(sysfs, "sdi", dev="8:128", write_size=False)
        for virtual in ("loop0", "dm-0", "sr0", "zram0", "mmcblk0boot0", "md127", "nbd0"):
            make_block(sysfs, virtual, dev="7:0")
        make_block(sysfs, "sdg", dev="8:96", device=False)
        return sysfs

    def test_enumeration_reasons_and_display(self):
        sysfs = self.fake_sysfs()
        mountinfo = ("22 1 0:21 / /proc rw - proc proc rw\n"
                     "30 1 259:1 / /mnt rw - ext4 /dev/nvme0n1p1 rw\n"
                     "31 1 8:16 / /run/ditto-medium ro - iso9660 /dev/sdb ro\n")
        swaps = "Filename Type Size Used Priority\n/dev/sdh1 partition 1024 0 -2\n"
        result = {c.disk.name: c for c in disks.enumerate_disks(
            sysfs, mountinfo=mountinfo, swaps=swaps, medium_devnums={"8:16"}, min_bytes=25 << 30)}
        self.assertEqual(set(result), {"sda", "sdb", "sdc", "sdd", "nvme0n1", "vda", "sde", "sdf", "sdh", "sdi"})
        expected = {"sda": (), "sdb": ("install_medium", "in_use"), "sdc": ("removable",),
                    "sdd": ("read_only",), "nvme0n1": ("in_use",), "vda": ("too_small",),
                    "sde": ("in_use",), "sdf": ("unsupported_sector_size",), "sdh": ("in_use",),
                    "sdi": ("unreadable",)}
        self.assertEqual({name: c.reasons for name, c in result.items()}, expected)
        self.assertEqual([name for name, c in result.items() if c.eligible], ["sda"])
        self.assertEqual(result["sda"].disk.serial, "S5SUNG01")
        self.assertEqual(result["sda"].disk.size_bytes, 64 << 30)
        self.assertEqual(result["vda"].disk.serial, "VIRT-1")
        self.assertEqual(result["nvme0n1"].disk.serial, "NVME-1")
        model = result["nvme0n1"].disk.model
        self.assertTrue(model.startswith("WD SN770 [31m") and len(model) == disks.DISPLAY_LIMIT, model)
        self.assertTrue(model.isprintable())

    def test_medium_devnum_from_partition(self):
        sysfs = self.fake_sysfs()
        result = {c.disk.name: c for c in disks.enumerate_disks(sysfs, medium_devnums={"8:2"})}
        self.assertEqual(result["sda"].reasons, ("install_medium",))

    def test_mountinfo_and_swaps_parsing(self):
        self.assertEqual(disks.mounted_devnums("1 0 8:1 / / rw - ext4 /dev/sda1 rw\nbad\n"), {"8:1"})
        self.assertEqual(disks.swap_names("Filename\n/dev/dm-1 partition 1 0 -2\n/swapfile file 1 0 -3\n"),
                         {"dm-1"})
        self.assertEqual(disks.devnum_of_path(self.root),
                         f"{os.major(os.stat(self.root).st_dev)}:{os.minor(os.stat(self.root).st_dev)}")


class WriterTests(Fixture):
    def test_end_to_end_install(self):
        need("sfdisk")
        source, out, digest = self.build_payload()
        man = self.load(out, digest)
        target = self.target()
        progress = []
        result = self.install(man, out, target, progress=lambda *a: progress.append(a))
        self.assertEqual(result, writer.Result("succeeded", "done", "ok", "installed"))
        self.assertEqual(progress[-1][0], "done")
        size = os.path.getsize(target)
        fd = os.open(target, os.O_RDONLY)
        try:
            table = gpt.read(gpt.file_reader(fd), size)
        finally:
            os.close(fd)
        src_fd = os.open(source, os.O_RDONLY)
        try:
            src_table = gpt.read(gpt.file_reader(src_fd), SOURCE_BYTES)
        finally:
            os.close(src_fd)
        self.assertNotEqual(table.disk_guid, src_table.disk_guid)
        data, src = target.read_bytes(), source.read_bytes()
        for mine, theirs in zip(table.partitions, src_table.partitions, strict=True):
            self.assertEqual((mine.number, mine.type_guid, mine.name, mine.attributes),
                             (theirs.number, theirs.type_guid, theirs.name, theirs.attributes))
            self.assertNotEqual(mine.unique_guid, theirs.unique_guid)
            if theirs.name != "_empty":
                self.assertEqual(sha(data[mine.start_bytes:mine.start_bytes + theirs.size_bytes]),
                                 sha(src[theirs.start_bytes:theirs.start_bytes + theirs.size_bytes]))
        state = table.partitions[1]
        self.assertEqual(state.size_bytes, size // MIB * MIB - 12 * MIB + 4 * MIB - MIB)
        spare = table.partitions[3]
        self.assertEqual(data[spare.start_bytes:spare.start_bytes + MIB], bytes(MIB))
        self.assertEqual(data[spare.start_bytes + spare.size_bytes - MIB:spare.start_bytes + spare.size_bytes],
                         bytes(MIB))
        self.assertEqual(data[2 * SECTOR + 128 * 128:MIB], bytes(MIB - 2 * SECTOR - 128 * 128))
        self.assertNotIn(b"OLD-TAIL", data[-MIB:])
        info = json.loads(subprocess.run(["sfdisk", "--json", str(target)], capture_output=True, text=True,
                                         timeout=30, check=True).stdout)["partitiontable"]
        self.assertEqual([row["name"] for row in info["partitions"]],
                         ["ditto-esp", "ditto-state", "ditto-usr-7", "_empty"])
        self.assertEqual(info["partitions"][1]["size"] * SECTOR, state.size_bytes)
        verify = subprocess.run(["sfdisk", "--verify", str(target)], capture_output=True, text=True, timeout=30)
        self.assertEqual(verify.returncode, 0, verify.stdout + verify.stderr)
        # A second install draws fresh identities.
        again = self.target()
        self.assertEqual(self.install(man, out, again).outcome, "succeeded")
        fd = os.open(again, os.O_RDONLY)
        try:
            second = gpt.read(gpt.file_reader(fd), os.path.getsize(again))
        finally:
            os.close(fd)
        self.assertNotEqual(second.disk_guid, table.disk_guid)
        self.assertTrue({p.unique_guid for p in second.partitions}.isdisjoint(p.unique_guid for p in table.partitions))

    def test_uncompressed_codec_install(self):
        _, out, digest = self.build_payload(codec="none")
        man = self.load(out, digest)
        self.assertEqual(self.install(man, out, self.target()).outcome, "succeeded")

    def test_payload_defects_never_touch_the_disk(self):
        def corrupt(out, man):
            path = out / man.role("usr").payload.file
            data = bytearray(path.read_bytes())
            data[len(data) // 2] ^= 0x01
            path.write_bytes(data)

        def append(out, man):
            with open(out / man.role("esp").payload.file, "ab") as stream:
                stream.write(b"\0")

        def remove(out, man):
            (out / man.role("state").payload.file).unlink()

        def symlink(out, man):
            path = out / man.role("esp").payload.file
            moved = path.with_name("moved")
            path.rename(moved)
            path.symlink_to(moved.name)

        def directory(out, man):
            path = out / man.role("esp").payload.file
            path.unlink()
            path.mkdir()

        def fifo(out, man):
            path = out / man.role("esp").payload.file
            path.unlink()
            os.mkfifo(path)

        def linked_dir(out, man):
            moved = out.with_name(out.name + "-real")
            out.rename(moved)
            out.symlink_to(moved)

        cases = {"one-bit": (corrupt, "payload_hash_mismatch"), "appended": (append, "payload_size_mismatch"),
                 "missing": (remove, "payload_missing"), "symlink": (symlink, "payload_missing"),
                 "directory": (directory, "payload_unsafe"), "fifo": (fifo, "payload_unsafe"),
                 "linked-dir": (linked_dir, "payload_unsafe")}
        for name, (damage, code) in cases.items():
            with self.subTest(case=name):
                _, out, digest = self.build_payload()
                man = self.load(out, digest)
                damage(out, man)
                target = self.target()
                before = file_sha(target)
                result = self.install(man, out, target)
                self.assertEqual((result.outcome, result.stage, result.code), ("failed", "verify", code))
                self.assert_untouched(result, target, before)

    def test_preflight_refusals_leave_disk_untouched(self):
        _, out, digest = self.build_payload()
        man = self.load(out, digest)
        target = self.target()
        before = file_sha(target)
        link = self.path("link.img")
        link.symlink_to(target)
        fifo = self.path("fifo")
        os.mkfifo(fifo)
        small = self.target(size=layout.minimum_disk_bytes(man) - SECTOR)
        small_before = file_sha(small)
        rows = [
            ("regular-without-flag", dict(allow_regular_file=False), target, "target_unusable"),
            ("symlink", {}, link, "target_unusable"),
            ("fifo", dict(disk=self.disk_for(target)), fifo, "target_unusable"),
            ("missing", dict(disk=self.disk_for(target)), self.root / "absent.img", "target_unusable"),
            ("size-changed", dict(disk=self.disk_for(target, size_bytes=os.path.getsize(target) + MIB)), target,
             "target_changed"),
            ("too-small", {}, small, "target_too_small"),
        ]
        for name, kwargs, path, code in rows:
            with self.subTest(case=name):
                result = self.install(man, out, path, **kwargs)
                self.assertEqual((result.outcome, result.stage, result.code, result.disk_state),
                                 ("failed", "preflight", code, "untouched"))
        self.assertEqual(file_sha(target), before)
        self.assertEqual(file_sha(small), small_before)
        self.assertFalse((self.root / "absent.img").exists())

    def test_cancel_before_any_write(self):
        _, out, digest = self.build_payload()
        man = self.load(out, digest)
        for name, calls_before_cancel in (("during-verify", 0), ("before-wipe", 3)):
            with self.subTest(point=name):
                target = self.target()
                before = file_sha(target)
                count = {"n": 0}

                def cancel():
                    count["n"] += 1
                    return count["n"] > calls_before_cancel
                result = self.install(man, out, target, cancel_check=cancel)
                self.assertEqual((result.outcome, result.code), ("cancelled", "cancelled"))
                self.assert_untouched(result, target, before)

    def test_cancel_during_write_leaves_no_partition_table(self):
        _, out, digest = self.build_payload()
        man = self.load(out, digest)
        target = self.target()
        count = {"n": 0}
        verify_calls = sum(1 for p in man.partitions if p.payload)  # >= one check per verified file

        def cancel():
            count["n"] += 1
            return count["n"] > verify_calls + 2
        result = self.install(man, out, target, cancel_check=cancel)
        self.assertEqual((result.outcome, result.stage, result.disk_state),
                         ("cancelled", "write", "partially_written"))
        self.assert_no_table(target)

    def test_write_readback_and_commit_faults(self):
        _, out, digest = self.build_payload()
        man = self.load(out, digest)
        original_write = writer._pwrite_all
        calls = {"n": 0}

        def failing_write(fd, data, offset):
            calls["n"] += 1
            if calls["n"] == 4:
                raise OSError(errno.EIO, "injected")
            return original_write(fd, data, offset)
        target = self.target()
        with mock.patch.object(writer, "_pwrite_all", failing_write):
            result = self.install(man, out, target)
        self.assertEqual((result.outcome, result.stage, result.code, result.disk_state),
                         ("failed", "write", "write_error", "partially_written"))
        self.assert_no_table(target)

        target = self.target()
        with mock.patch.object(writer, "_read_region", lambda *a: "0" * 64):
            result = self.install(man, out, target)
        self.assertEqual((result.stage, result.code, result.disk_state),
                         ("readback", "readback_mismatch", "partially_written"))
        self.assert_no_table(target)

        target = self.target()
        with mock.patch.object(writer, "_read_region", side_effect=OSError(errno.EIO, "injected")):
            result = self.install(man, out, target)
        self.assertEqual((result.stage, result.code), ("readback", "read_error"))
        self.assert_no_table(target)

        target = self.target()
        real_read = gpt.read

        def different(*args, **kwargs):
            table = real_read(*args, **kwargs)
            return gpt.Table(table.disk_guid, table.first_usable_lba, table.last_usable_lba, table.partitions[:-1])
        with mock.patch.object(writer.gpt, "read", different):
            result = self.install(man, out, target)
        self.assertEqual((result.outcome, result.stage, result.code), ("failed", "commit", "commit_failed"))
        self.assertNotEqual(result.disk_state, "installed")

    def test_decoder_faults_never_spill_or_succeed(self):
        need("zstd")
        _, out, digest = self.build_payload()
        man = self.load(out, digest)
        esp = man.role("esp")

        def with_payload(content):
            path = out / esp.payload.file
            path.write_bytes(content)

            def mutate(data):
                data["partitions"][0]["payload"].update(compressed_bytes=len(content),
                                                        compressed_sha256=sha(content))
            return self.load(out, self.rewrite_manifest(out, mutate))

        # Garbage that zstd rejects, with a manifest that vouches for its bytes.
        broken = with_payload(b"not a zstd frame" * 64)
        target = self.target()
        result = self.install(broken, out, target)
        self.assertEqual((result.stage, result.code), ("write", "decompress_failed"))
        self.assert_no_table(target)

        # A frame that decompresses beyond the partition must stop before spilling.
        long_raw = random.Random(7).randbytes(esp.size_bytes + MIB)
        frame = subprocess.run(["zstd", "-q", "-c", "-"], input=long_raw, capture_output=True, check=True,
                               timeout=60).stdout
        spilling = with_payload(frame)
        target = self.target()
        neighbour = target.read_bytes()[esp.start_bytes + esp.size_bytes:esp.start_bytes + esp.size_bytes + MIB]
        result = self.install(spilling, out, target)
        self.assertEqual((result.stage, result.code), ("write", "payload_length_mismatch"))
        after = target.read_bytes()[esp.start_bytes + esp.size_bytes:esp.start_bytes + esp.size_bytes + MIB]
        self.assertEqual(after, neighbour)
        self.assert_no_table(target)

        # Swapped for a FIFO after verification: refused, never handed to zstd (no hang).
        _, out, digest = self.build_payload()
        man = self.load(out, digest)
        real_verify = writer.verify_payloads

        def verify_then_swap(manifest_, directory, **kwargs):
            ok = real_verify(manifest_, directory, **kwargs)
            path = Path(directory) / manifest_.role("state").payload.file
            path.unlink()
            os.mkfifo(path)
            return ok
        target = self.target()
        with mock.patch.object(writer, "verify_payloads", verify_then_swap):
            result = self.install(man, out, target)
        self.assertEqual((result.stage, result.code, result.disk_state),
                         ("write", "payload_unsafe", "partially_written"))
        self.assert_no_table(target)

        # Decoder binary missing: a recorded failure, not an escaping exception.
        _, out, digest = self.build_payload()
        man = self.load(out, digest)
        target = self.target()
        result = self.install(man, out, target, zstd_command=(str(self.root / "no-such-zstd"),))
        self.assertEqual((result.stage, result.code), ("write", "decompress_failed"))
        self.assert_no_table(target)

        # Right length, wrong content (manifest raw digest disagrees).
        _, out, digest = self.build_payload()

        def wrong_raw(data):
            data["partitions"][0]["payload"]["raw_sha256"] = "f" * 64
        man = self.load(out, self.rewrite_manifest(out, wrong_raw))
        target = self.target()
        result = self.install(man, out, target)
        self.assertEqual((result.stage, result.code), ("write", "payload_hash_mismatch"))
        self.assert_no_table(target)


class SessionTests(Fixture):
    def setup_session(self, install=None):
        _, out, digest = self.build_payload()
        man = self.load(out, digest)
        sysfs = self.path("sys")
        devroot = self.path("dev")
        devroot.mkdir()
        target = devroot / "sdz"
        shutil.copyfile(self.target(), target)
        make_block(sysfs, "sdz", dev="8:240", size_bytes=os.path.getsize(target), model="Task Disk",
                   serial="TASK-0001", serial_at="serial")
        make_block(sysfs, "sdy", dev="8:224", removable=1)
        calls = []

        def default_install(disk, cancel_check):
            calls.append(disk)
            return writer.install(man, out, devroot / disk.name, disk, allow_regular_file=True,
                                  cancel_check=cancel_check)
        state = {"mountinfo": ""}

        def enumerate_fn():
            return disks.enumerate_disks(sysfs, mountinfo=state["mountinfo"],
                                         min_bytes=layout.minimum_disk_bytes(man))
        tokens = iter(f"token-{n}" for n in range(100))
        sess = session.Session(enumerate_fn, install or default_install, token_factory=lambda: next(tokens))
        return sess, sysfs, target, calls, state

    def test_tokens_back_and_confirmation(self):
        sess, _, target, calls, _ = self.setup_session()
        before = file_sha(target)
        offers = sess.list_disks()
        by_name = {offer.candidate.disk.name: offer for offer in offers}
        self.assertIsNone(by_name["sdy"].token)
        self.assertEqual(by_name["sdy"].candidate.reasons, ("removable",))
        for bad in (None, "token-999", 7):
            with self.subTest(token=bad), self.assertRaises(session.SessionError):
                sess.select(bad)
        prompt = sess.select(by_name["sdz"].token)
        self.assertEqual((prompt.disk.model, prompt.disk.serial), ("Task Disk", "TASK-0001"))
        with self.assertRaises(session.SessionError):
            sess.select(by_name["sdz"].token)          # single use, not listing
        sess.back()
        self.assertEqual(sess.state, session.LISTING)
        with self.assertRaises(session.SessionError):
            sess.confirm(prompt.token)                  # stale after back
        self.assertEqual((calls, file_sha(target)), ([], before))
        offers = sess.list_disks()
        prompt = sess.select(next(o.token for o in offers if o.token))
        with self.assertRaises(session.SessionError) as caught:
            sess.confirm("token-wrong")
        self.assertEqual(caught.exception.code, "bad_confirmation")
        self.assertEqual(file_sha(target), before)
        result = sess.confirm(prompt.token)
        self.assertEqual((result.outcome, sess.state), ("succeeded", session.SUCCEEDED))
        self.assertEqual(len(calls), 1)
        with self.assertRaises(session.SessionError):
            sess.confirm(prompt.token)

    def test_disk_changes_between_confirmation_and_write(self):
        mutations = {
            "serial": lambda sysfs, state: (sysfs / "block/sdz/serial").write_text("OTHER\n"),
            "size": lambda sysfs, state: (sysfs / "block/sdz/size").write_text("99999999\n"),
            "mounted": lambda sysfs, state: state.update(mountinfo="1 0 8:240 / /mnt rw - ext4 /dev/sdz rw\n"),
            "gone": lambda sysfs, state: shutil.rmtree(sysfs / "block/sdz"),
        }
        for name, mutate in mutations.items():
            with self.subTest(change=name):
                sess, sysfs, target, calls, state = self.setup_session()
                before = file_sha(target)
                offers = sess.list_disks()
                prompt = sess.select(next(o.token for o in offers if o.token))
                mutate(sysfs, state)
                self.assertIsNone(sess.confirm(prompt.token))
                self.assertEqual((sess.state, sess.notice), (session.LISTING, "disk_changed"))
                self.assertEqual((calls, file_sha(target)), ([], before))

    def test_cancel_request_from_another_thread(self):
        started = threading.Event()

        def slow_install(disk, cancel_check):
            started.set()
            deadline = time.monotonic() + 10
            while not cancel_check():
                if time.monotonic() > deadline:
                    return writer.Result("failed", "write", "timeout", "partially_written")
                time.sleep(0.01)
            return writer.Result("cancelled", "write", "cancelled", "partially_written")
        sess, *_ = self.setup_session(install=slow_install)
        with self.assertRaises(session.SessionError):
            sess.request_cancel()
        offers = sess.list_disks()
        prompt = sess.select(next(o.token for o in offers if o.token))
        worker = threading.Thread(target=lambda: started.wait(5) and sess.request_cancel())
        worker.start()
        result = sess.confirm(prompt.token)
        worker.join(5)
        self.assertEqual((result.outcome, sess.state), ("cancelled", session.CANCELLED))
        with self.assertRaises(session.SessionError):
            sess.list_disks()


class TextAndCliTests(Fixture):
    def test_every_code_has_product_text(self):
        source = "\n".join((INSTALLER / "ditto_installer" / name).read_text()
                           for name in ("writer.py", "manifest.py", "layout.py"))
        codes = set(re.findall(r'_Stop\("(?:failed|cancelled)", "([a-z_]+)"', source))
        codes |= set(re.findall(r'(?:ManifestError|LayoutError)\("([a-z_]+)"', source))
        codes |= {"ok", "disk_changed", "internal_error"}
        self.assertLessEqual(codes, set(messages.RESULTS), codes - set(messages.RESULTS))
        self.assertEqual(set(disks.REASONS), set(messages.EXCLUDED))
        for table in (messages.RESULTS, messages.EXCLUDED):
            for code, (zh, en) in table.items():
                with self.subTest(code=code):
                    self.assertRegex(zh, r"[一-鿿]")
                    self.assertTrue(en.isascii() and en)
                    # Identifier-shaped codes stay in the diagnostic layer.
                    if "_" in code:
                        self.assertNotIn(code, zh + en)

    def test_make_payload_cli(self):
        need("zstd")
        disk = self.source_disk()
        script = INSTALLER / "make-payload.py"
        args = [sys.executable, script, "--disk", disk, "--image-version", "7", "--source-commit", COMMIT]
        wrong = subprocess.run([*map(str, args), "--disk-sha256", "0" * 64, "--output", str(self.path("bad"))],
                               capture_output=True, text=True, timeout=120)
        self.assertEqual(wrong.returncode, 2, wrong.stderr)
        self.assertIn("SHA256", wrong.stderr)
        out = self.path("good")
        good = subprocess.run([*map(str, args), "--disk-sha256", file_sha(disk), "--output", str(out)],
                              capture_output=True, text=True, timeout=120)
        self.assertEqual(good.returncode, 0, good.stderr)
        self.assertEqual(good.stdout.strip(), file_sha(out / payload.MANIFEST))
        again = subprocess.run([*map(str, args), "--disk-sha256", file_sha(disk), "--output", str(out)],
                               capture_output=True, text=True, timeout=120)
        self.assertEqual(again.returncode, 2, again.stderr)


if __name__ == "__main__":
    unittest.main()

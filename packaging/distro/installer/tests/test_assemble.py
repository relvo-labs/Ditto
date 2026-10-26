"""assemble-iso planning and validation. No xorriso/mtools/mkfs is executed:
a recording runner stands in for them and only creates task-owned files."""

import hashlib
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest

HERE = Path(__file__).resolve().parent
INSTALLER = HERE.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(INSTALLER))

import test_installer as base  # noqa: E402
from ditto_installer import MIB  # noqa: E402

LABEL = "DITTO_INSTALL_7"
EPOCH = 1792940557   # 2026-10-25T15:02:37Z


def load_assemble():
    loader = importlib.machinery.SourceFileLoader("assemble_iso", str(INSTALLER / "assemble-iso"))
    spec = importlib.util.spec_from_loader("assemble_iso", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


assemble_iso = load_assemble()


class AssembleTests(base.Fixture):
    def inputs(self, *, label=LABEL, mode="installer", digest_override=None, uki_bytes=b"MZ" + b"\0" * 8190):
        _, payload, digest = self.build_payload()
        build = self.path("installer-build")
        config = {"schema": 1, "manifest_sha256": digest_override or digest, "medium_label": label,
                  "payload_dir": "ditto/payload", "frontend_user": "ditto-installer"}
        (build / "extra/usr/lib/ditto-installer").mkdir(parents=True)
        (build / "extra/usr/share/ditto").mkdir(parents=True)
        (build / "extra/usr/lib/ditto-installer/installer.json").write_text(json.dumps(config))
        (build / "extra/usr/share/ditto/image-inputs.json").write_text(json.dumps(
            {"mode": mode, "payload_manifest_sha256": config["manifest_sha256"], "medium_label": label}))
        uki = self.path("ditto-installer.efi")
        uki.write_bytes(uki_bytes)
        return uki, build, payload, digest

    def recording_runner(self, calls, payload):
        def run(argv, **kwargs):
            calls.append(argv)
            if argv[0] == "xorriso" and "-o" in argv:
                tree = Path(argv[-1])
                copied = sorted(p.name for p in (tree / "ditto/payload").iterdir())
                self.assertEqual(copied, sorted(p.name for p in payload.iterdir()))
                for name in copied:
                    self.assertEqual(base.file_sha(tree / "ditto/payload" / name), base.file_sha(payload / name))
                Path(argv[argv.index("-o") + 1]).write_bytes(b"fake iso for " + argv[argv.index("-V") + 1].encode())
            return subprocess.CompletedProcess(argv, 0, "", "")
        return run

    def test_plan_is_uefi_only_hybrid(self):
        uki, _, payload, _ = self.inputs()
        steps, iso = assemble_iso.plan(uki=uki, payload_dir=payload, output=self.root / "out", label=LABEL,
                                       version="7", epoch=EPOCH)
        runs = [s[1] for s in steps if s[0] == "run"]
        self.assertEqual(iso.name, "ditto-7-installer-x86_64.iso")
        self.assertEqual(runs[0][:6], ["mkfs.vfat", "-C", "-F", "32", "-n", "DITTO_EFI"])
        self.assertEqual(runs[0][-1], str(64 * MIB // 1024))
        self.assertEqual(runs[2][-1], "::/EFI/BOOT/BOOTX64.EFI")
        xorriso = runs[3]
        for option in (["-V", LABEL], ["-append_partition", "2", assemble_iso.ESP_TYPE_XORRISO],
                       ["-e", "--interval:appended_partition_2:all::", "-no-emul-boot"]):
            index = xorriso.index(option[0])
            self.assertEqual(xorriso[index:index + len(option)], option)
        self.assertIn("-appended_part_as_gpt", xorriso)
        self.assertIn("--modification-date=2026102515023700", xorriso)
        for bios in ("-b", "--grub2-mbr", "-isohybrid-mbr", "-boot-info-table"):
            self.assertNotIn(bios, xorriso)
        self.assertTrue(all(s[2]["SOURCE_DATE_EPOCH"] == str(EPOCH) for s in steps if s[0] == "run"))
        copies = {s[2].name for s in steps if s[0] == "copy"}
        self.assertEqual(copies, {p.name for p in payload.iterdir()})

    def test_esp_size(self):
        self.assertEqual(assemble_iso.esp_image_bytes(1), 64 * MIB)
        size = assemble_iso.esp_image_bytes(300 * MIB)
        self.assertEqual(size % MIB, 0)
        self.assertGreaterEqual(size, 300 * MIB + 15 * MIB + 16 * MIB)

    def test_assemble_with_recording_runner(self):
        uki, build, payload, digest = self.inputs()
        calls = []
        out = self.root / "iso-out"
        iso = assemble_iso.assemble(uki=uki, installer_build=build, payload_dir=payload, output=out,
                                    version="7", epoch=EPOCH, runner=self.recording_runner(calls, payload))
        self.assertEqual([c[0] for c in calls], ["mkfs.vfat", "mmd", "mcopy", "xorriso", "xorriso"])
        sums = (out / "SHA256SUMS").read_text()
        self.assertEqual(sums, f"{hashlib.sha256(iso.read_bytes()).hexdigest()}  {iso.name}\n")
        record = json.loads((out / "assembly.json").read_text())
        self.assertEqual((record["medium_label"], record["payload_manifest_sha256"], record["payload_image_version"]),
                         (LABEL, digest, "7"))
        self.assertEqual(record["installer_uki_sha256"], base.file_sha(uki))
        self.assertFalse((out / "work/tree").exists())

    def test_refusals_happen_before_any_tool_runs(self):
        def never(*args, **kwargs):
            raise AssertionError("a tool was run")
        cases = {
            "not-pe": dict(uki_bytes=b"XX" + b"\0" * 8190),
            "tiny-uki": dict(uki_bytes=b"MZ"),
            "other-manifest": dict(digest_override="0" * 64),
            "image-profile": dict(mode="normal"),
        }
        for name, kwargs in cases.items():
            with self.subTest(case=name):
                uki, build, payload, _ = self.inputs(**kwargs)
                with self.assertRaises(assemble_iso.AssemblyError):
                    assemble_iso.assemble(uki=uki, installer_build=build, payload_dir=payload,
                                          output=self.path("out"), version="7", epoch=EPOCH, runner=never)
        uki, build, payload, _ = self.inputs()
        man = json.loads((payload / "payload-manifest.json").read_text())
        damaged = payload / man["partitions"][0]["payload"]["file"]
        damaged.write_bytes(damaged.read_bytes() + b"\0")
        with self.assertRaises(assemble_iso.AssemblyError):
            assemble_iso.assemble(uki=uki, installer_build=build, payload_dir=payload, output=self.path("out"),
                                  version="7", epoch=EPOCH, runner=never)
        uki, build, payload, _ = self.inputs()
        existing = self.path("exists")
        existing.mkdir()
        for kwargs in (dict(output=existing), dict(version="../7"), dict(epoch=0), dict(epoch=True)):
            with self.subTest(kwargs=kwargs), self.assertRaises(assemble_iso.AssemblyError):
                assemble_iso.assemble(**{"uki": uki, "installer_build": build, "payload_dir": payload,
                                         "output": self.path("out"), "version": "7", "epoch": EPOCH,
                                         "runner": never, **kwargs})

    def test_cli_rejects_bad_inputs_without_tools(self):
        uki, build, payload, _ = self.inputs(uki_bytes=b"not a PE file" * 1000)
        result = subprocess.run([sys.executable, str(INSTALLER / "assemble-iso"), "--installer-uki", str(uki),
                                 "--installer-build", str(build), "--payload", str(payload), "--version", "7",
                                 "--source-date-epoch", str(EPOCH), "--output", str(self.path("cli-out"))],
                                capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("not a PE image", result.stderr)


if __name__ == "__main__":
    unittest.main()

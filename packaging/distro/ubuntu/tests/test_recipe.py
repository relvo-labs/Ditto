"""Filesystem/metadata regressions only: no guest, runtime binary or root mount."""

import configparser
import hashlib
import io
import itertools
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import unittest

RECIPE = Path(os.environ.get("DITTO_RECIPE_UNDER_TEST", Path(__file__).resolve().parents[1]))
REPO = Path(__file__).resolve().parents[4]


def call(*args):
    return subprocess.run([str(a) for a in args], text=True, capture_output=True, timeout=30)


class RecipeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.shared = tempfile.TemporaryDirectory(prefix="ditto-regression-source-")
        cls.archive = Path(cls.shared.name) / "source.tar"
        cls.commit = call("git", "-C", REPO, "rev-parse", "HEAD").stdout.strip()
        result = call("git", "-C", REPO, "archive", "--format=tar", "--output", cls.archive, cls.commit)
        if result.returncode:
            raise RuntimeError(result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.shared.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ditto-recipe-regression-")
        self.root = Path(self.temp.name)
        self.counter = itertools.count()
        self.tree = self.root / "runtime"
        self.put("usr/lib/os-release", "IMAGE_ID=ditto\n", self.root / "image")
        self.put("etc/shadow", "root:!:1:0:99999:7:::\n", self.root / "image")
        names = ["usr/bin/quickshell", "usr/bin/wayfire", "usr/lib/ditto-node/bin/node",
                 "usr/local/libexec/xdg-desktop-portal-wlr",
                 "usr/lib/ditto/packages/host-runtime/dist/ditto-hostd.mjs",
                 "usr/lib/ditto/packages/agent-runtime/dist/ditto-agentd.mjs",
                 "usr/lib/ditto/target/ditto-packages/builtin.dittopkg",
                 "usr/share/doc/ditto-runtime/NOTICE"]
        names += ["usr/lib/ditto/target/release/" + n for n in (
            "ditto-core", "ditto-worker", "ditto-confine", "ditto-supervisor", "dittoctl",
            "ditto-test-host", "ditto-dbus-proxy", "ditto-generation-runner")]
        for name in names:
            self.put(name, "synthetic non-executable runtime fixture\n", self.tree)

    def tearDown(self):
        self.temp.cleanup()

    @staticmethod
    def put(name, text, root):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def lock(self, archive=None, commit=None):
        files, links = {}, {}
        for path in self.tree.rglob("*"):
            name = path.relative_to(self.tree).as_posix()
            if path.is_symlink():
                links[name] = path.readlink().as_posix()
            elif path.is_file():
                files[name] = hashlib.sha256(path.read_bytes()).hexdigest()
        return {"source_commit": commit or self.commit,
                "source_sha256": hashlib.sha256((archive or self.archive).read_bytes()).hexdigest(),
                "snapshot": "20261020T000000Z", "qt": "6.10.2", "rust": "1.98.1", "node": "22.23.2",
                "quickshell_revision": "1a4716cde794a59928d9d9fc15f2afc7a95de360",
                "wayfire_revision": "d39902379c5737eebe1dc3a830659fa3f0fa22e0",
                "files": files, "symlinks": links}

    def generate(self, expected=0, archive=None, commit=None, lock=None, flags=()):
        lock = lock or self.lock(archive, commit)
        lock_path = self.root / f"lock-{next(self.counter)}.json"
        lock_path.write_text(json.dumps(lock))
        output = self.root / f"output-{next(self.counter)}"
        result = call(sys.executable, RECIPE / "generate.py", "--source-tar", archive or self.archive,
                      "--source-commit", commit or self.commit, "--source-sha256", lock["source_sha256"],
                      "--runtime-tree", self.tree, "--runtime-lock", lock_path,
                      "--version", "1", "--output", output, *flags)
        self.assertEqual(result.returncode, expected, result.stderr)
        if expected:
            self.assertFalse(output.exists(), result.stderr)
        return output, result

    def scan(self, expected=0, flags=()):
        result = call(sys.executable, RECIPE / "scan-pristine-rootfs.py", self.root / "image", *flags)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def test_clean_locked(self):
        self.scan()

    def test_shadow_rejects_empty_active_malformed_and_duplicate(self):
        for line in ("root::1:0:99999:7:::\n", "root:synthetic-hash:1:0:99999:7:::\n",
                     "root\n", "root:!\n", "root:!:1:0:99999:7:::\n" * 2):
            with self.subTest(kind=line.split(":")[0]):
                self.put("etc/shadow", line, self.root / "image")
                report = self.scan(1)
                self.assertIn("etc/shadow", report["identity_files"])
                self.assertNotIn("synthetic-hash", json.dumps(report))

    def test_shadow_allows_only_truly_locked_fields(self):
        for field in ("!", "!!", "*", "!*", "***"):
            self.put("etc/shadow", f"root:{field}:1:0:99999:7:::\n", self.root / "image")
            self.scan()

    def test_autologin_and_sudo_rejected(self):
        cases = [("etc/greetd/config.toml", '[initial_session]\ncommand="/bin/sh"\nuser="root"\n'),
                 ("etc/sudoers.d/90-fixture", "fixture ALL=(ALL) NOPASSWD: ALL\n"),
                 ("etc/sudoers", "Defaults !authenticate\n"),
                 ("etc/sudoers", "#1000 ALL=(ALL) NOPASSWD: ALL\n"),
                 ("etc/sudoers.d/README", "fixture ALL=(ALL) NOPASSWD: ALL\n"),
                 ("etc/systemd/system/getty@tty1.service.d/login.conf", "[Service]\nExecStart=-/sbin/agetty --autologin root tty1\n"),
                 ("etc/gdm3/custom.conf", "[daemon]\nAutomaticLoginEnable=true\n"),
                 ("etc/sddm.conf", "[Autologin]\nUser=root\n")]
        for name, contents in cases:
            with self.subTest(path=name):
                path = self.put(name, contents, self.root / "image")
                self.scan(1)
                path.unlink()

    def test_default_distro_auth_configs_allowed(self):
        self.put("etc/greetd/config.toml", '[default_session]\ncommand="/usr/sbin/agreety --cmd /usr/local/libexec/ditto-image-session"\nuser="_greetd"\n', self.root / "image")
        self.put("etc/sudoers", '# NOPASSWD: example only\nroot ALL=(ALL:ALL) ALL\n@includedir /etc/sudoers.d\n', self.root / "image")
        self.put("etc/sudoers.d/README", '# No active NOPASSWD: rules\n', self.root / "image")
        self.put("etc/gdm3/custom.conf", '[daemon]\n# AutomaticLoginEnable=true\nAutomaticLoginEnable=false\n', self.root / "image")
        self.scan()

    def test_unit_masks_aliases_and_auth_directory_links(self):
        target = self.put("usr/lib/systemd/system/fixture.service", "[Service]\nExecStart=/bin/true\n", self.root / "image")
        mask = self.root / "image/etc/systemd/system/getty@tty1.service"
        mask.parent.mkdir(parents=True)
        mask.symlink_to("/dev/null")
        alias = target.parent / "fixture-alias.service"
        alias.symlink_to(target.name)
        self.scan()
        target.write_text("[Service]\nExecStart=/sbin/agetty --autologin root tty1\n")
        self.scan(1)
        target.write_text("[Service]\nExecStart=/bin/true\n")
        alias.unlink()
        alias.symlink_to("../../../../../../outside")
        self.scan(1)
        alias.unlink()
        outside = self.root / "outside-greetd"
        outside.mkdir()
        (self.root / "image/etc/greetd").symlink_to(outside, target_is_directory=True)
        self.scan(1)

    def test_sudo_include_cannot_hide_rules(self):
        self.put("etc/sudoers", "@include /etc/custom-rule\n", self.root / "image")
        self.put("etc/custom-rule", "fixture ALL=(ALL) NOPASSWD: ALL\n", self.root / "image")
        self.scan(1)

    def test_identity_symlink_is_not_a_pristine_exception(self):
        path = self.root / "image/etc/ssh/ssh_host_ed25519_key"
        path.parent.mkdir(parents=True)
        path.symlink_to("/dev/null")
        report = self.scan(1)
        self.assertIn("etc/ssh/ssh_host_ed25519_key", report["identity_files"])

    def test_legitimate_home_tunable(self):
        self.put("etc/apparmor.d/tunables/home", "@{HOMEDIRS}=/home/ /srv/home/\n@{HOME}=@{HOMEDIRS}/*/ /root/\n", self.root / "image")
        self.scan()

    def test_precise_private_and_build_paths(self):
        for text in ("/home/author/build/ditto", "/data/runner/worktrees/project", "/data/runner/agent-runs/task"):
            path = self.put("usr/lib/fixture", text, self.root / "image")
            self.scan(1)
            path.unlink()
        self.put("usr/lib/fixture", "build-marker", self.root / "image")
        self.scan(1, ("--forbid", "build-marker"))

    def test_matching_source_control(self):
        output, _ = self.generate()
        self.assertTrue((output / "extra/usr/lib/ditto/packaging/reference-image/session/xdg/foot/foot.ini").is_file())

    def test_staged_runtime_manifest_and_no_debug_default(self):
        output, _ = self.generate()
        for name in self.lock()["files"]:
            self.assertEqual((output / "runtime" / name).read_bytes(), (self.tree / name).read_bytes())
            self.assertFalse((output / "extra" / name).exists())
        self.assertTrue((output / "apply-runtime.py").is_file())
        self.assertNotIn("systemd.debug_shell", (output / "mkosi.conf").read_text())

    def test_wrong_declared_source(self):
        _, result = self.generate(2, commit="0" * 40)
        self.assertIn("PAX", result.stderr)

    def test_absent_pax_comment(self):
        archive = self.root / "no-comment.tar"
        with tarfile.open(self.archive) as old, tarfile.open(archive, "w", format=tarfile.PAX_FORMAT) as new:
            for member in old:
                member.pax_headers.pop("comment", None)
                new.addfile(member, old.extractfile(member) if member.isfile() else None)
        _, result = self.generate(2, archive=archive)
        self.assertIn("PAX", result.stderr)

    def test_corrupt_runtime_digest(self):
        lock = self.lock()
        (self.tree / "usr/bin/quickshell").write_text("changed")
        _, result = self.generate(2, lock=lock)
        self.assertIn("digest", result.stderr)

    def test_core_library_injection(self):
        for name in ("libc.so.6", "libQt6Core.so.6.10.2"):
            path = self.put("usr/lib/x86_64-linux-gnu/" + name, "synthetic forbidden replacement", self.tree)
            _, result = self.generate(2)
            self.assertIn("not admitted", result.stderr)
            path.unlink()

    def test_valid_wayfire_links(self):
        lib = self.put("usr/lib/x86_64-linux-gnu/libwf-config.so.0.0.0", "synthetic library", self.tree)
        (lib.parent / "libwf-config.so.0").symlink_to(lib.name)
        (lib.parent / "libwf-config.so").symlink_to("libwf-config.so.0")
        (lib.parent / "libwf-utils.so").symlink_to("/usr/lib/x86_64-linux-gnu/" + lib.name)
        self.generate()

    def test_invalid_links_reach_link_validation(self):
        lib = self.put("usr/lib/x86_64-linux-gnu/libwf-config.so.0.0.0", "synthetic library", self.tree)
        link = lib.parent / "libwf-config.so"
        for target in ("libwf-config.so", "libwf-config.so.9", "/etc/passwd", "../../../../../../outside"):
            with self.subTest(target=target):
                link.symlink_to(target)
                _, result = self.generate(2)
                self.assertIn("runtime link", result.stderr)
                link.unlink()
        # Present on disk but deliberately unlisted must not be admitted by resolution.
        unlisted = self.put("usr/lib/x86_64-linux-gnu/libwf-config.so.9", "unlisted", self.tree)
        link.symlink_to(unlisted.name)
        lock = self.lock()
        lock["files"].pop(unlisted.relative_to(self.tree).as_posix())
        _, result = self.generate(2, lock=lock)
        self.assertIn("unlisted", result.stderr)
        link.unlink()
        other = lib.parent / "libwf-config.so.0"
        link.symlink_to(other.name)
        other.symlink_to(link.name)
        _, result = self.generate(2)
        self.assertIn("cycle", result.stderr)

    def test_lock_generation_uses_same_admission(self):
        args = [sys.executable, RECIPE / "lock-runtime.py", "--runtime-tree", self.tree,
                "--source-commit", self.commit, "--source-sha256", self.lock()["source_sha256"]]
        self.assertEqual(call(*args).returncode, 0)
        self.put("usr/lib/x86_64-linux-gnu/libc.so.6", "synthetic forbidden replacement", self.tree)
        result = call(*args)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("not admitted", result.stderr)

    def test_parent_symlink_confinement(self):
        docs = self.tree / "usr/share/doc/ditto-runtime"
        outside = self.root / "outside"
        shutil.move(docs, outside)
        docs.symlink_to(outside, target_is_directory=True)
        lock = self.lock()
        lock["symlinks"].pop("usr/share/doc/ditto-runtime", None)
        lock["files"]["usr/share/doc/ditto-runtime/NOTICE"] = hashlib.sha256((outside / "NOTICE").read_bytes()).hexdigest()
        _, result = self.generate(2, lock=lock)
        self.assertIn("parent symlink", result.stderr)

    def test_link_parent_cannot_be_normalized_past_an_unlisted_symlink(self):
        lib = self.put("usr/lib/x86_64-linux-gnu/libwf-config.so.0", "synthetic library", self.tree)
        outside = self.root / "outside"
        outside.mkdir()
        parent = lib.parent / "escape"
        parent.symlink_to(outside, target_is_directory=True)
        (lib.parent / "libwf-config.so").symlink_to("escape/../" + lib.name)
        lock = self.lock()
        lock["symlinks"].pop(parent.relative_to(self.tree).as_posix(), None)
        _, result = self.generate(2, lock=lock)
        self.assertIn("runtime link parent", result.stderr)

    def test_target_ownership_with_real_dpkg_query(self):
        self.assertIsNotNone(shutil.which("dpkg-query"), "real target dpkg-query required")
        target = self.root / "target"
        self.put("var/lib/dpkg/status", "Package: fixture\nStatus: install ok installed\nArchitecture: amd64\nVersion: 1\nMaintainer: Fixture <fixture@example.invalid>\nDescription: task-owned fixture\n\n", target)
        # A late-sorting collision proves that earlier payloads were not copied first.
        owned = self.put("var/lib/dpkg/info/fixture.list", "/usr/share/doc/ditto-runtime/NOTICE\n", target)
        lock_path = self.root / "apply-lock.json"
        lock_path.write_text(json.dumps(self.lock()))
        args = [sys.executable, RECIPE / "apply-runtime.py", "--root", target,
                "--runtime-lock", lock_path, "--runtime-tree", self.tree]
        result = call(*args)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("owned by an installed target", result.stderr)
        self.assertFalse((target / "usr/bin/wayfire").exists())
        owned.write_text("/usr/share/doc/fixture/copyright\n")
        result = call(*args)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = call(sys.executable, RECIPE / "apply-runtime.py", "--root", target, "--runtime-lock", lock_path)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_drm_present_delayed_absent_and_unit_wiring(self):
        cards = self.root / "drm"
        cards.mkdir()
        args = [sys.executable, RECIPE / "wait-drm.py", "--sys-class-drm", cards, "--timeout", "0.5"]
        card = cards / "card7/device"
        card.mkdir(parents=True)
        self.assertEqual(call(*args).returncode, 0)
        shutil.rmtree(card.parent)
        def arrive():
            time.sleep(0.1)
            card.mkdir(parents=True)
        worker = threading.Thread(target=arrive)
        worker.start()
        try:
            self.assertEqual(call(*args).returncode, 0)
        finally:
            worker.join()
        shutil.rmtree(card.parent)
        (cards / "card7-HDMI-A-1/device").mkdir(parents=True)
        self.assertEqual(call(*args).returncode, 1)
        output, _ = self.generate()
        unit = configparser.ConfigParser()
        unit.read(output / "extra/etc/systemd/system/greetd.service.d/seat.conf")
        helper = unit["Service"]["ExecStartPre"]
        self.assertEqual(helper, "/usr/lib/ditto/wait-drm")
        self.assertTrue(os.access(output / "extra" / helper.lstrip("/"), os.X_OK))

    def test_dev_renderer_mode_is_explicit_and_recorded(self):
        for flags, mode in (((), "normal"), (("--dev-software-render",), "dev-software-render")):
            output, _ = self.generate(flags=flags)
            launcher = (output / "extra/usr/local/libexec/ditto-image-session").read_text()
            inputs = json.loads((output / "extra/usr/share/ditto/image-inputs.json").read_text())
            self.assertEqual(inputs["mode"], mode)
            self.assertEqual("LIBGL_ALWAYS_SOFTWARE=1" in launcher, bool(flags))
            self.assertEqual("WLR_RENDERER_ALLOW_SOFTWARE=1" in launcher, bool(flags))


class DecisionTableTests(unittest.TestCase):
    def test_d51_is_structurally_in_decision_table(self):
        path = Path(os.environ.get("DITTO_DECISION_TABLE", REPO / "milestones/01/05-risks-decisions.md"))
        text = path.read_text()
        table = next(block for block in text.split("\n\n") if block.startswith("| # | 議題 |"))
        rows = [line.split("|")[1].strip() for line in table.splitlines()[2:]]
        self.assertIn("D-51", rows)
        self.assertEqual(rows[rows.index("D-51") - 1], "D-50")


if __name__ == "__main__":
    unittest.main()

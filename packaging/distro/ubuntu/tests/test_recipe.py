"""Filesystem/metadata regressions only: no guest, runtime binary or root mount."""

import configparser
import contextlib
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
from unittest import mock

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
        self.put("etc/passwd", "root:x:0:0:root:/root:/bin/bash\n", self.root / "image")
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

    def test_empty_root_passwd_with_locked_shadow(self):
        self.put("etc/passwd", "root::0:0:root:/root:/bin/bash\n", self.root / "image")
        report = self.scan(1)
        self.assertIn("etc/passwd", report["identity_files"])
        self.assertEqual(report["errors"], [])

    def test_empty_extra_account_passwd(self):
        self.put("etc/passwd", "root:x:0:0:root:/root:/bin/bash\nfixture::1000:1000::/nonexistent:/usr/sbin/nologin\n", self.root / "image")
        # Exact refined witness: locked root shadow, extra passwd account only.
        report = self.scan(1)
        self.assertIn("etc/passwd", report["identity_files"])
        self.assertEqual(report["errors"], [])

    def test_passwd_active_fields_and_privacy(self):
        for field in ("synthetic-hash", "!synthetic-hash", "*synthetic-hash", "X", "!!synthetic-hash"):
            with self.subTest(field=field):
                self.put("etc/passwd", f"root:{field}:0:0:root:/root:/bin/bash\n", self.root / "image")
                report = self.scan(1)
                self.assertIn("etc/passwd", report["identity_files"])
                self.assertNotIn("synthetic-hash", json.dumps(report))
                self.assertEqual(report["errors"], [])

    def test_distro_account_pairs_and_locked_fields(self):
        for field in ("x", "!", "!!", "*", "!*", "***"):
            with self.subTest(field=field):
                self.put("etc/passwd", f"root:{field}:0:0:root:/root:/bin/bash\ndaemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin\n_greetd:x:999:999::/nonexistent:/usr/sbin/nologin\nnobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin\n", self.root / "image")
                self.put("etc/shadow", "root:!:1:0:99999:7:::\ndaemon:*:1:0:99999:7:::\n_greetd:!!:::::::\nnobody:!*:1:0:99999:7:::\n", self.root / "image")
                self.scan()

    def test_account_mapping_missing_duplicate_and_malformed(self):
        passwd = "root:x:0:0:root:/root:/bin/bash\n"
        shadow = "root:!:1:0:99999:7:::\n"
        cases = [
            (passwd + "daemon:x:1:1::/usr/sbin:/usr/sbin/nologin\n", shadow, "etc/passwd"),
            (passwd, shadow + "daemon:*:1:0:99999:7:::\n", "etc/shadow"),
            (passwd * 2, shadow, "etc/passwd"),
            ("daemon:x:1:1::/usr/sbin:/usr/sbin/nologin\n", shadow, "etc/passwd"),
            (passwd, "daemon:*:1:0:99999:7:::\n", "etc/shadow"),
            ("root:x:0:0:root:/root\n", shadow, "etc/passwd"),
            ("root:x:bad:0:root:/root:/bin/bash\n", shadow, "etc/passwd"),
            ("root:x:0::root:/root:/bin/bash\n", shadow, "etc/passwd"),
            (passwd + "\n", shadow, "etc/passwd"),
            (passwd.replace("root:/root", "bad\x00:/root"), shadow, "etc/passwd"),
            (passwd, shadow.replace(":1:", ":bad:"), "etc/shadow"),
        ]
        for index, (pw, sh, bad) in enumerate(cases):
            with self.subTest(row=index):
                self.put("etc/passwd", pw, self.root / "image")
                self.put("etc/shadow", sh, self.root / "image")
                report = self.scan(1)
                self.assertIn(bad, report["identity_files"])
                self.assertEqual(report["errors"], [])

    def test_account_files_missing_and_unsafe_links(self):
        for name in ("passwd", "shadow"):
            path = self.root / "image/etc" / name
            original = path.read_bytes()
            for kind in ("missing", "relative", "absolute", "dangling", "directory", "nonutf8"):
                with self.subTest(file=name, kind=kind):
                    path.unlink()
                    if kind == "relative":
                        self.put("account-copy", original.decode(), path.parent)
                        path.symlink_to("account-copy")
                    elif kind == "absolute":
                        path.symlink_to("/dev/null")
                    elif kind == "dangling":
                        path.symlink_to("missing-account")
                    elif kind == "directory":
                        path.mkdir()
                    elif kind == "nonutf8":
                        path.write_bytes(b"\xff")
                    try:
                        report = self.scan(1)
                        self.assertTrue(any(row["file"] == "etc/" + name for row in report["errors"]) or
                                        "etc/" + name in report["identity_files"])
                    finally:
                        if path.is_dir() and not path.is_symlink():
                            path.rmdir()
                        elif path.exists() or path.is_symlink():
                            path.unlink()
                        path.write_bytes(original)

    def test_account_parent_link_and_unreadable_fail_closed(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("pristine", RECIPE / "scan-pristine-rootfs.py")
        scanner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(scanner)
        # Real entry-point control for an unsafe parent; no host account file read.
        etc = self.root / "image/etc"
        moved = self.root / "account-dir"
        etc.rename(moved)
        etc.symlink_to(moved)
        self.scan(1)
        etc.unlink()
        moved.rename(etc)
        # Permission bits are ineffective for root runners. Inject an actual read
        # failure at the filesystem API, without a privileged account/session.
        original_read = Path.read_bytes
        def unreadable(path):
            if path.name == "passwd":
                raise PermissionError("synthetic private value must not escape")
            return original_read(path)
        output = io.StringIO()
        with mock.patch.object(Path, "read_bytes", unreadable), mock.patch.object(
                sys, "argv", ["scan", str(self.root / "image")]), contextlib.redirect_stdout(output):
            self.assertEqual(scanner.main(), 1)
        report = json.loads(output.getvalue())
        self.assertEqual(report["errors"][0]["file"], "etc/passwd")
        self.assertNotIn("synthetic private", json.dumps(report))

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

    def apply_fixture(self, case, owned, aliases=(), candidate="usr/bin/wayfire", expected=2):
        """Actual entry + real target dpkg DB; no fixture binary is executable."""
        self.assertIsNotNone(shutil.which("dpkg-query"), "real target dpkg-query required")
        target = self.root / case
        self.put("var/lib/dpkg/status", "Package: fixture\nStatus: install ok installed\nArchitecture: amd64\nVersion: 1\nMaintainer: Fixture <fixture@example.invalid>\nDescription: task-owned fixture\n\n", target)
        self.put("var/lib/dpkg/info/fixture.list", owned + "\n", target)
        for name, value in aliases:
            path = target / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.symlink_to(value)
        original = self.put(candidate, "original task-owned target fixture\n", target)
        lock_path = self.root / f"apply-{next(self.counter)}.json"
        lock_path.write_text(json.dumps(self.lock()))
        query = call("dpkg-query", "--admindir=" + str(target / "var/lib/dpkg"), "-S", owned)
        self.assertEqual(query.returncode, 0, query.stderr)
        before = sorted(p.relative_to(target).as_posix() for p in target.rglob("*"))
        result = call(sys.executable, RECIPE / "apply-runtime.py", "--root", target,
                      "--runtime-lock", lock_path, "--runtime-tree", self.tree)
        self.assertEqual(result.returncode, expected, result.stderr)
        if expected:
            self.assertIn("owned by an installed target", result.stderr)
            self.assertEqual(original.read_text(), "original task-owned target fixture\n")
            self.assertEqual(sorted(p.relative_to(target).as_posix() for p in target.rglob("*")), before)
        return target, result

    def test_owned_bin_relative_and_image_absolute_aliases(self):
        for index, value in enumerate(("usr/bin", "/usr/bin", "./usr/bin", "usr/../usr/bin")):
            with self.subTest(target=value):
                self.apply_fixture(f"bin-{index}", "/bin/wayfire", [("bin", value)])

    def test_owned_nested_chained_aliases(self):
        cases = [
            [("opt/desktop", "/usr/bin")],
            [("opt/desktop", "../compat/bin"), ("compat/bin", "/usr/bin")],
            [("opt/desktop", "../compat/bin/../bin"), ("compat", "usr")],
        ]
        for index, aliases in enumerate(cases):
            with self.subTest(row=index):
                self.apply_fixture(f"nested-{index}", "/opt/desktop/wayfire", aliases)

    def test_late_alias_collision_preflights_all_payloads(self):
        self.apply_fixture("late-alias", "/legacy/share/doc/ditto-runtime/NOTICE",
                           [("legacy", "/usr")], "usr/share/doc/ditto-runtime/NOTICE")

    def test_symlink_runtime_entries_are_owned_too(self):
        lib = self.put("usr/lib/x86_64-linux-gnu/libwf-config.so.0", "synthetic library", self.tree)
        (lib.parent / "libwf-config.so").symlink_to(lib.name)
        # The owned link need not exist yet: installed package authority still wins.
        self.apply_fixture("owned-link", "/compat/x86_64-linux-gnu/libwf-config.so",
                           [("compat", "/usr/lib")], "usr/bin/wayfire")

    def test_distinct_bin_directory_is_not_an_alias(self):
        target = self.root / "distinct"
        legacy = self.put("bin/wayfire", "distinct package fixture\n", target)
        self.apply_fixture("distinct", "/bin/wayfire", expected=0)
        self.assertEqual(legacy.read_text(), "distinct package fixture\n")
        self.assertEqual((target / "usr/bin/wayfire").read_bytes(), (self.tree / "usr/bin/wayfire").read_bytes())

    def test_unowned_alias_control(self):
        self.apply_fixture("unowned-alias", "/bin/unrelated", [("bin", "/usr/bin")], expected=0)

    def test_alias_query_and_target_confinement_fail_closed(self):
        for index, value in enumerate(("loop", "../../outside", "/host/../../outside")):
            with self.subTest(target=value):
                target = self.root / f"bad-alias-{index}"
                self.put("var/lib/dpkg/status", "Package: fixture\nStatus: install ok installed\nArchitecture: amd64\nVersion: 1\nMaintainer: Fixture <fixture@example.invalid>\nDescription: fixture\n\n", target)
                self.put("var/lib/dpkg/info/fixture.list", "/loop/wayfire\n", target)
                (target / "loop").symlink_to(value)
                lock = self.root / f"bad-alias-{index}.json"
                lock.write_text(json.dumps(self.lock()))
                result = call(sys.executable, RECIPE / "apply-runtime.py", "--root", target,
                              "--runtime-lock", lock, "--runtime-tree", self.tree)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertRegex(result.stderr, "alias cycle/depth|escapes image")
                self.assertFalse((target / "usr/bin/quickshell").exists())

    def test_target_database_and_host_root_refusals(self):
        lock = self.root / "database-lock.json"
        lock.write_text(json.dumps(self.lock()))
        for kind in ("missing", "malformed", "symlink-status", "symlink-parent", "target-parent",
                     "symlink-info", "symlink-list", "symlink-diversions"):
            with self.subTest(kind=kind):
                target = self.root / ("db-" + kind)
                target.mkdir()
                if kind == "missing":
                    pass
                elif kind == "malformed":
                    self.put("var/lib/dpkg/status", "not a package database\n", target)
                else:
                    self.put("var/lib/dpkg/status", "", target)
                    self.put("var/lib/dpkg/info/fixture.list", "", target)
                    if kind == "symlink-status":
                        (target / "var/lib/dpkg/status").unlink()
                        (target / "var/lib/dpkg/status").symlink_to("/dev/null")
                    elif kind == "symlink-parent":
                        (target / "var").rename(target / "elsewhere")
                        (target / "var").symlink_to("elsewhere")
                    elif kind == "target-parent":
                        (target / "usr").symlink_to("/usr")
                    elif kind == "symlink-info":
                        (target / "var/lib/dpkg/info").rename(target / "saved-info")
                        (target / "var/lib/dpkg/info").symlink_to("../../../saved-info")
                    elif kind == "symlink-list":
                        (target / "var/lib/dpkg/info/fixture.list").unlink()
                        (target / "var/lib/dpkg/info/fixture.list").symlink_to("../../../../list-outside")
                        self.put("list-outside", "", target)
                    elif kind == "symlink-diversions":
                        (target / "var/lib/dpkg/diversions").symlink_to("../../../diversions-outside")
                        self.put("diversions-outside", "", target)
                result = call(sys.executable, RECIPE / "apply-runtime.py", "--root", target,
                              "--runtime-lock", lock, "--runtime-tree", self.tree)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertRegex(result.stderr, "dpkg|parent symlink")
                if kind != "target-parent":
                    self.assertFalse((target / "usr/bin/quickshell").exists())
        # Valid runtime prerequisites ensure this reaches the host-root guard.
        for target in ("/",):
            result = call(sys.executable, RECIPE / "apply-runtime.py", "--root", target,
                          "--runtime-lock", lock, "--runtime-tree", self.tree)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("refusing host root", result.stderr)

    def test_target_query_failures_never_admit_runtime(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("policy", RECIPE / "runtime_policy.py")
        policy = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(policy)
        target = self.root / "query-target"
        self.put("var/lib/dpkg/status", "", target)
        def query(command, **kwargs):
            self.assertIn("--admindir=" + str(target / "var/lib/dpkg"), command)
            if "-W" in command:
                return subprocess.CompletedProcess(command, 0, "", "")
            return subprocess.CompletedProcess(command, 1, "", "unexpected query error\n")
        with mock.patch.object(policy.subprocess, "run", query):
            with self.assertRaisesRegex(ValueError, "query failed closed"):
                policy.check_target_ownership(target, ["usr/bin/wayfire"])
        # Noncanonical host-root spelling must be refused before any query. This
        # mock makes it impossible for the frozen RED run to read the host DB.
        with mock.patch.object(policy.subprocess, "run", side_effect=AssertionError("host DB query attempted")):
            with self.assertRaisesRegex(ValueError, "refusing host root"):
                policy.check_target_ownership(Path("/usr/.."), ["usr/bin/wayfire"])

    def target_database(self, case, owned="/usr/share/doc/fixture/copyright"):
        target = self.root / case
        self.put("var/lib/dpkg/status", "Package: fixture\nStatus: install ok installed\nArchitecture: amd64\nVersion: 1\nMaintainer: Fixture <fixture@example.invalid>\nDescription: task-owned fixture\n\n", target)
        self.put("var/lib/dpkg/info/fixture.list", owned + "\n", target)
        return target

    def runtime_args(self, target, copy=True):
        lock = self.root / f"runtime-{next(self.counter)}.json"
        lock.write_text(json.dumps(self.lock()))
        return [RECIPE / "apply-runtime.py", "--root", target, "--runtime-lock", lock,
                *(["--runtime-tree", self.tree] if copy else [])]

    def test_target_query_timeouts_exit_two_before_copy(self):
        # Execute the real CLI in a child interpreter. Only the selected dpkg
        # call raises TimeoutExpired; all other queries use the real target DB.
        script = """
import runpy, subprocess, sys
from pathlib import Path
original_run = subprocess.run
fail_at = int(sys.argv[1])
queries = 0
def query(command, **kwargs):
    global queries
    if command[0] == 'dpkg-query':
        queries += 1
        if queries == fail_at:
            raise subprocess.TimeoutExpired(command, kwargs['timeout'])
    return original_run(command, **kwargs)
subprocess.run = query
sys.argv = sys.argv[2:]
sys.path.insert(0, str(Path(sys.argv[0]).parent))
runpy.run_path(sys.argv[0], run_name='__main__')
"""
        for index, stage in enumerate(("probe", "catalog", "exact-path"), 1):
            with self.subTest(stage=stage):
                target = self.target_database("timeout-" + stage)
                args = self.runtime_args(target)
                result = call(sys.executable, "-c", script, index, *args)
                self.assertFalse((target / "usr").exists(), result.stderr)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertNotIn("Traceback", result.stderr)
                self.assertIn("timed out", result.stderr)
                control = call(sys.executable, *args)
                self.assertEqual(control.returncode, 0, control.stderr)
                self.assertEqual((target / "usr/bin/wayfire").read_bytes(),
                                 (self.tree / "usr/bin/wayfire").read_bytes())
                # Finish's read-only audit must use the same rejection path.
                audit = call(sys.executable, "-c", script, index,
                             *self.runtime_args(target, copy=False))
                self.assertEqual(audit.returncode, 2, audit.stderr)
                self.assertNotIn("Traceback", audit.stderr)

    def test_target_metadata_symlinks_rejected_before_copy(self):
        for name in ("updates", "info/format"):
            for dangling in (False, True):
                with self.subTest(metadata=name, dangling=dangling):
                    target = self.target_database(f"metadata-{next(self.counter)}")
                    path = target / "var/lib/dpkg" / name
                    saved = target / "saved-metadata"
                    if not dangling:
                        if name == "updates":
                            saved.mkdir()
                        else:
                            saved.write_text("1\n")
                    path.symlink_to(saved)
                    result = call(sys.executable, *self.runtime_args(target))
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertIn("ownership database missing or unsafe", result.stderr)
                    self.assertFalse((target / "usr").exists())

    def test_target_regular_metadata_control(self):
        target = self.target_database("metadata-control")
        (target / "var/lib/dpkg/updates").mkdir()
        self.put("var/lib/dpkg/info/format", "1\n", target)
        result = call(sys.executable, *self.runtime_args(target))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((target / "usr/bin/wayfire").read_bytes(),
                         (self.tree / "usr/bin/wayfire").read_bytes())

    def assert_updates_rejected(self, target, untouched):
        import importlib.util
        spec = importlib.util.spec_from_file_location("policy", RECIPE / "runtime_policy.py")
        policy = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(policy)
        before = {path: path.read_bytes() for path in untouched}
        # Ordering guard also prevents a FIFO regression from hanging dpkg.
        with mock.patch.object(policy.subprocess, "run", side_effect=AssertionError("dpkg reached")):
            with self.assertRaisesRegex(ValueError, "ownership database missing or unsafe: updates journal"):
                policy.check_target_ownership(target, ["usr/bin/wayfire"])
        result = call(sys.executable, *self.runtime_args(target))
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("ownership database missing or unsafe: updates journal", result.stderr)
        self.assertFalse((target / "usr/bin").exists(), "no earlier runtime copy")
        self.assertEqual({path: path.read_bytes() for path in untouched}, before)
        # Prepare a valid installed payload to reach finish's read-only audit.
        shutil.copytree(self.tree, target, dirs_exist_ok=True)
        audit = call(sys.executable, *self.runtime_args(target, copy=False))
        self.assertEqual(audit.returncode, 2, audit.stderr)
        self.assertIn("ownership database missing or unsafe: updates journal", audit.stderr)
        self.assertEqual({path: path.read_bytes() for path in untouched}, before)
        for name in self.lock()["files"]:
            self.assertEqual((target / name).read_bytes(), (self.tree / name).read_bytes())

    def test_updates_unsafe_objects_and_entries_rejected_before_query_and_copy(self):
        kinds = ("object-file", "object-fifo", "object-link", "object-dangling", "object-loop",
                 "external-link", "other-name-link", "nonnumeric-link", "dangling-link",
                 "directory-link", "self-loop", "two-link-loop", "directory", "fifo")
        for kind in kinds:
            with self.subTest(kind=kind):
                target = self.target_database("journal-" + kind, "/usr/share/doc/fixture/protected")
                protected = self.put("usr/share/doc/fixture/protected", "protected package bytes\n", target)
                record = "Package: fixture\nStatus: install ok installed\nArchitecture: amd64\nVersion: 2\nMaintainer: Fixture <fixture@example.invalid>\nDescription: external task-owned journal\n\n"
                outside = self.put("outside-" + kind, record, self.root)
                sentinel = self.put("outside-dir-" + kind + "/sentinel", "outside directory bytes\n", self.root)
                updates = target / "var/lib/dpkg/updates"
                if kind == "object-file":
                    updates.write_text(record)
                elif kind == "object-fifo":
                    os.mkfifo(updates)
                elif kind == "object-link":
                    updates.symlink_to(sentinel.parent)
                elif kind == "object-dangling":
                    updates.symlink_to(self.root / "missing-updates")
                elif kind == "object-loop":
                    updates.symlink_to(updates.name)
                else:
                    updates.mkdir()
                    name = {"other-name-link": "0042", "nonnumeric-link": "tmp.i"}.get(kind, "0001")
                    entry = updates / name
                    if kind in ("external-link", "other-name-link", "nonnumeric-link"):
                        entry.symlink_to(outside)
                    elif kind == "dangling-link":
                        entry.symlink_to(self.root / "missing-journal")
                    elif kind == "directory-link":
                        entry.symlink_to(sentinel.parent)
                    elif kind == "self-loop":
                        entry.symlink_to(entry.name)
                    elif kind == "two-link-loop":
                        entry.symlink_to("0002")
                        (updates / "0002").symlink_to(entry.name)
                    elif kind == "directory":
                        entry.mkdir()
                    elif kind == "fifo":
                        os.mkfifo(entry)
                self.assert_updates_rejected(target, [outside, sentinel, protected,
                    target / "var/lib/dpkg/status", target / "var/lib/dpkg/info/fixture.list"])

    def test_updates_absent_empty_and_regular_journal_controls(self):
        for kind in ("absent", "empty", "regular"):
            with self.subTest(kind=kind):
                target = self.target_database("journal-control-" + kind)
                updates = target / "var/lib/dpkg/updates"
                version = "1"
                if kind != "absent":
                    updates.mkdir()
                if kind == "regular":
                    version = "2"
                    # Same installed package and coherent .list: this journal
                    # must affect the real query and still allow apply/audit.
                    self.put("var/lib/dpkg/updates/0001", (target / "var/lib/dpkg/status").read_text().replace(
                        "Version: 1\n", "Version: 2\n"), target)
                    # dpkg's temporary journal file is regular and is ignored.
                    self.put("var/lib/dpkg/updates/tmp.i", "temporary journal bytes\n", target)
                query = call("dpkg-query", "--admindir=" + str(target / "var/lib/dpkg"), "-W")
                self.assertEqual(query.returncode, 0, query.stderr)
                self.assertEqual(query.stdout, "fixture\t" + version + "\n")
                self.assertEqual(query.stderr, "")
                catalog = call("dpkg-query", "--admindir=" + str(target / "var/lib/dpkg"), "-S", "*")
                self.assertEqual(catalog.returncode, 0, catalog.stderr)
                self.assertIn("fixture: /usr/share/doc/fixture/copyright", catalog.stdout)
                untouched = [target / "var/lib/dpkg/status", target / "var/lib/dpkg/info/fixture.list"]
                if kind == "regular":
                    untouched.extend(updates.iterdir())
                before = {path: path.read_bytes() for path in untouched}
                result = call(sys.executable, *self.runtime_args(target))
                self.assertEqual(result.returncode, 0, result.stderr)
                audit = call(sys.executable, *self.runtime_args(target, copy=False))
                self.assertEqual(audit.returncode, 0, audit.stderr)
                self.assertEqual({path: path.read_bytes() for path in untouched}, before)
                for name in self.lock()["files"]:
                    self.assertEqual((target / name).read_bytes(), (self.tree / name).read_bytes())

    def test_target_root_inode_alias_stat_simulation(self):
        # Stat simulation only, NOT privileged bind-mount acceptance. The real
        # CLI sees /'s (st_dev, st_ino) at a task-owned target; it never reads the
        # host dpkg DB. Each single-field difference is a valid-root control.
        script = """
import os, runpy, sys
from pathlib import Path
mode, target = sys.argv[1], Path(sys.argv[2])
original_stat = Path.stat
fields = list(original_stat(Path('/')))
if mode == 'other-inode':
    fields[1] += 1
elif mode == 'other-device':
    fields[2] += 1
identity = os.stat_result(fields)
def target_stat(path, *args, **kwargs):
    return identity if path == target else original_stat(path, *args, **kwargs)
Path.stat = target_stat
sys.argv = sys.argv[3:]
sys.path.insert(0, str(Path(sys.argv[0]).parent))
runpy.run_path(sys.argv[0], run_name='__main__')
"""
        for mode in ("alias", "other-inode", "other-device"):
            with self.subTest(mode=mode):
                target = self.target_database("root-stat-" + mode)
                result = call(sys.executable, "-c", script, mode, target,
                              *self.runtime_args(target))
                self.assertEqual(result.returncode, 2 if mode == "alias" else 0, result.stderr)
                if mode == "alias":
                    self.assertIn("refusing host root", result.stderr)
                    self.assertFalse((target / "usr").exists())
                else:
                    self.assertEqual((target / "usr/bin/wayfire").read_bytes(),
                                     (self.tree / "usr/bin/wayfire").read_bytes())

    def test_target_catalog_terminal_dotdot_rejected(self):
        for row in ("/usr/bin/wayfire/child/..", "/usr/bin/wayfire/child/../",
                    "/unrelated/child/.."):
            with self.subTest(row=row):
                target = self.target_database(f"catalog-{next(self.counter)}", row)
                catalog = call("dpkg-query", "--admindir=" + str(target / "var/lib/dpkg"), "-S", "*")
                self.assertEqual(catalog.returncode, 0, catalog.stderr)
                self.assertIn(row.rstrip("/"), catalog.stdout)
                result = call(sys.executable, *self.runtime_args(target))
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("catalog failed closed", result.stderr)
                self.assertFalse((target / "usr").exists())

    def test_target_catalog_interior_dotdot_controls(self):
        self.apply_fixture("dotdot-collision", "/opt/../usr/bin/wayfire")
        self.apply_fixture("dotdot-unowned", "/opt/../usr/bin/unrelated", expected=0)

    def test_existing_hardlink_rejected_before_any_copy(self):
        target = self.target_database("hardlink", "/usr/share/doc/fixture/protected")
        protected = self.put("usr/share/doc/fixture/protected", "protected package bytes\n", target)
        # A late destination shares the package inode, but its path is unowned.
        name = "usr/share/doc/ditto-runtime/NOTICE"
        dest = target / name
        dest.parent.mkdir(parents=True)
        dest.hardlink_to(protected)
        identity = (protected.stat().st_dev, protected.stat().st_ino)
        self.assertEqual(dest.stat().st_nlink, 2)
        result = call(sys.executable, *self.runtime_args(target))
        self.assertEqual(protected.read_bytes(), b"protected package bytes\n", result.stderr)
        self.assertEqual((dest.stat().st_dev, dest.stat().st_ino), identity)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("existing target hardlink", result.stderr)
        self.assertFalse((target / "usr/bin").exists())

    def test_existing_single_link_destination_control(self):
        target = self.target_database("single-link")
        dest = self.put("usr/share/doc/ditto-runtime/NOTICE", "replaceable bytes\n", target)
        self.assertEqual(dest.stat().st_nlink, 1)
        result = call(sys.executable, *self.runtime_args(target))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(dest.read_bytes(), (self.tree / "usr/share/doc/ditto-runtime/NOTICE").read_bytes())

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

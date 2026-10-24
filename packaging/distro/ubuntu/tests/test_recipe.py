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
# Contract value: symlinks followed across the WHOLE unit alias chain (parent
# and leaf components together, never reset per layer). Linux MAXSYMLINKS.
UNIT_ALIAS_MAX_HOPS = 40
# Filesystem calls one in-process resolution may make. A valid chain at the hop
# limit needs a few hundred; a resolver that resets or forgets its budget loops
# forever, so the recorder fails it here instead of growing without bound.
RESOLVER_OPERATION_BUDGET = 4096
SNAPSHOT = "20261020T000000Z"
# Target packages providing Quickshell's direct sonames from the first real
# target readback (libunwind.so.8 was "not found"); remaining sonames arrive as
# dependencies. Source-only contract: not evidence that a target resolves them.
QUICKSHELL_TARGET_PACKAGES = {
    "libunwind8", "libjemalloc2", "libgbm1", "libegl1", "libpipewire-0.3-0t64",
    "libpolkit-agent-1-0", "libqt6waylandclient6", "libqt6widgets6", "libqt6core6t64",
    "libqt6gui6", "libqt6qml6", "libqt6quick6"}
TIMERS = ("fstrim", "dpkg-db-backup", "motd-news")
PUBLIC_PRODUCER_MANIFEST = "public-producer-path-fixtures.json"
# The eight package/vendor hits of the first #205 real-image scan; the four
# owned Rust artifacts of that scan are deliberately absent (remap instead).
REAL_PUBLIC_PRODUCER_PATHS = {
    "usr/share/doc/adduser/examples/adduser.local.conf",
    "usr/share/doc/adduser/examples/README",
    "usr/share/doc/libasound2t64/examples/asoundrc.txt",
    "usr/share/doc/util-linux/deprecated.txt",
    "usr/share/xkeyboard-config-2/symbols/se",
    "usr/share/icons/hicolor/scalable/apps/org.fcitx.Fcitx5.svg",
    "usr/lib/x86_64-linux-gnu/libgtk-3.so.0.2420.32",
    "usr/lib/ditto-node/bin/node"}
OWNED_IMAGE_PREFIXES = ("usr/lib/ditto/", "usr/share/ditto/", "usr/share/doc/ditto-runtime/",
                        "usr/local/libexec/")
# Synthetic public fixture: a producer-path hit that is NOT Ditto's.
UPSTREAM_REL = "usr/share/doc/vendor-fixture/examples/asoundrc.txt"
UPSTREAM_BYTES = b"# upstream example\npcm.level {\n\tlib /home/upstream-author/scopes/level.so\n}\n"
SYNTHETIC_KEY = ("-----BEGIN " + "PRIVATE KEY-----\nU1lOVEhFVElDS0VZ\nTk9UQVJFQUxLRVk=\n"
                 "-----END " + "PRIVATE KEY-----\n").encode()


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def call(*args):
    return subprocess.run([str(a) for a in args], text=True, capture_output=True, timeout=30)


def load_module(name, path):
    import importlib.util
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@contextlib.contextmanager
def confined_filesystem_access(root, never_open=()):
    """Record every path the resolver touches; fail on any access outside root.

    readlink/open must stay inside root. Metadata on root's own ancestors is
    not a host same-name read and is tolerated. Paths in never_open must never
    be opened (a FIFO open would block)."""
    import builtins
    root = str(root)
    touched, opened = [], []
    never_open = {str(path) for path in never_open}
    originals = {"lstat": os.lstat, "stat": os.stat, "readlink": os.readlink, "open": os.open}
    original_io_open = io.open

    def record(operation, path):
        if isinstance(path, int):
            return
        text = os.fsdecode(os.fspath(path))
        touched.append((operation, text))
        if len(touched) > RESOLVER_OPERATION_BUDGET:
            raise AssertionError("unit resolver exceeded its filesystem operation budget")
        if operation == "open":
            opened.append(text)
            if text in never_open:
                raise AssertionError("non-regular unit target was opened")

    def wrap(name):
        def wrapper(path, *args, **kwargs):
            record(name, path)
            return originals[name](path, *args, **kwargs)
        return wrapper

    def io_open(path, *args, **kwargs):
        record("open", path)
        return original_io_open(path, *args, **kwargs)

    def inside(operation, path):
        if path == root or path.startswith(root + "/"):
            return True
        ancestor = path == "/" or root.startswith(path.rstrip("/") + "/")
        return operation in ("lstat", "stat") and ancestor

    with contextlib.ExitStack() as stack:
        for name in originals:
            stack.enter_context(mock.patch.object(os, name, wrap(name)))
        stack.enter_context(mock.patch.object(io, "open", io_open))
        stack.enter_context(mock.patch.object(builtins, "open", io_open))
        yield touched, opened
    outside = sorted({operation for operation, path in touched if not inside(operation, path)})
    if outside:
        raise AssertionError(f"resolver used {outside} outside the image root")


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

    def generate(self, expected=0, archive=None, commit=None, lock=None, flags=(), recipe=RECIPE):
        lock = lock or self.lock(archive, commit)
        lock_path = self.root / f"lock-{next(self.counter)}.json"
        lock_path.write_text(json.dumps(lock))
        output = self.root / f"output-{next(self.counter)}"
        result = call(sys.executable, recipe / "generate.py", "--source-tar", archive or self.archive,
                      "--source-commit", commit or self.commit, "--source-sha256", lock["source_sha256"],
                      "--runtime-tree", self.tree, "--runtime-lock", lock_path,
                      "--version", "1", "--output", output, *flags)
        self.assertEqual(result.returncode, expected, result.stderr)
        if expected:
            self.assertFalse(output.exists(), result.stderr)
        return output, result

    def scan(self, expected=0, flags=(), image=None, recipe=RECIPE):
        result = call(sys.executable, recipe / "scan-pristine-rootfs.py", image or self.root / "image", *flags)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def pristine_image(self, name):
        image = self.root / name
        self.put("usr/lib/os-release", "IMAGE_ID=ditto\n", image)
        self.put("etc/shadow", "root:!:1:0:99999:7:::\n", image)
        self.put("etc/passwd", "root:x:0:0:root:/root:/bin/bash\n", image)
        return image

    @staticmethod
    def link(root, name, target):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.symlink_to(target)
        return path

    def merged_usr_image(self, name, lib_target="usr/lib"):
        """Ubuntu-shaped merged /usr: lib -> usr/lib and real vendor timers."""
        image = self.pristine_image(name)
        expected = {}
        for timer in TIMERS:
            body = f"[Timer]\n# task-owned {timer} fixture\nOnCalendar=daily\n"
            self.put(f"usr/lib/systemd/system/{timer}.timer", body, image)
            rel = f"etc/systemd/system/timers.target.wants/{timer}.timer"
            self.link(image, rel, f"/lib/systemd/system/{timer}.timer")
            expected[rel] = body.encode()
        self.link(image, "lib", lib_target)
        return image, expected

    def resolve_unit(self, image, rel, never_open=()):
        scanner = load_module("pristine", RECIPE / "scan-pristine-rootfs.py")
        with confined_filesystem_access(image, never_open):
            try:
                return scanner.unit_link_contents(image, rel)
            except (ValueError, OSError) as error:
                self.fail(f"valid in-image alias rejected ({type(error).__name__}: {error})")

    def assert_unit_rejected(self, image, rel, message=None, never_open=()):
        scanner = load_module("pristine", RECIPE / "scan-pristine-rootfs.py")
        with confined_filesystem_access(image, never_open):
            with self.assertRaises((ValueError, OSError)) as caught:
                scanner.unit_link_contents(image, rel)
        if message:
            self.assertRegex(str(caught.exception), message)

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
        # B1: the three real timers.target.wants aliases resolve through the
        # image's own merged-/usr parent link (relative and image-absolute).
        for lib_target in ("usr/lib", "/usr/lib"):
            with self.subTest(lib=lib_target):
                image, expected = self.merged_usr_image(f"merged-{next(self.counter)}", lib_target)
                vendor = image / "usr/lib/systemd/system"
                self.put("fixture.service", "[Service]\nExecStart=/bin/true\n", vendor)
                self.link(vendor, "fixture-alias.service", "fixture.service")
                expected["usr/lib/systemd/system/fixture-alias.service"] = b"[Service]\nExecStart=/bin/true\n"
                # Relative leaf that climbs to the image root, then uses the lib alias.
                rel = "etc/systemd/system/multi-user.target.wants/relative.service"
                self.link(image, rel, "../../../../lib/systemd/system/fixture.service")
                expected[rel] = expected["usr/lib/systemd/system/fixture-alias.service"]
                # Multi-hop: parent alias -> parent alias, then a leaf alias.
                self.link(image, "compat", "lib")
                self.link(vendor, "legacy-fstrim.timer", "fstrim.timer")
                rel = "etc/systemd/system/timers.target.wants/multihop.timer"
                self.link(image, rel, "/compat/systemd/system/legacy-fstrim.timer")
                expected[rel] = expected["etc/systemd/system/timers.target.wants/fstrim.timer"]
                for rel, data in expected.items():
                    self.assertEqual(self.resolve_unit(image, rel), data, rel)
                report = self.scan(image=image)
                self.assertEqual(report["authentication_config"], [])
        # A genuinely separate physical lib directory is read for itself.
        image = self.pristine_image("physical-lib")
        self.put("usr/lib/systemd/system/fstrim.timer", "[Timer]\n# merged copy\n", image)
        physical = self.put("lib/systemd/system/fstrim.timer", "[Timer]\n# physical copy\n", image)
        rel = "etc/systemd/system/timers.target.wants/fstrim.timer"
        self.link(image, rel, "/lib/systemd/system/fstrim.timer")
        self.assertEqual(self.resolve_unit(image, rel), b"[Timer]\n# physical copy\n")
        self.scan(image=image)
        physical.write_text("[Service]\nExecStart=-/sbin/agetty --autologin root tty1\n")
        self.assertIn(rel, self.scan(1, image=image)["authentication_config"])

    def test_unit_resolver_order_and_confinement(self):
        # B2: parent links are expanded before a following '..'; two distinct
        # in-image destinations prove the actual resolution order.
        image, _ = self.merged_usr_image("order")
        self.put("usr/lib/systemd/order.timer", "[Timer]\n# expanded parent\n", image)
        self.put("order.timer", "[Timer]\n# lexical normalisation\n", image)
        self.link(image, "units", "usr/lib/systemd/system")
        wants = "etc/systemd/system/timers.target.wants/"
        self.link(image, wants + "order.timer", "/units/../order.timer")
        self.assertEqual(self.resolve_unit(image, wants + "order.timer"), b"[Timer]\n# expanded parent\n")
        # A valid chain may pass through the same parent alias more than once.
        self.link(image, wants + "repeat.timer", "/lib/../../lib/systemd/system/fstrim.timer")
        self.assertEqual(self.resolve_unit(image, wants + "repeat.timer"),
                         (image / "usr/lib/systemd/system/fstrim.timer").read_bytes())
        # Escapes after expansion, relative and absolute, and lexical-only traps.
        self.link(image, "rootlink", "/")
        self.link(image, "up", "../..")
        escapes = {"relative.timer": "../../../../../../outside",
                   "absolute.timer": "/../outside",
                   "expanded.timer": "/units/../../../../../outside",
                   "rootdotdot.timer": "/rootlink/../order.timer",
                   "updir.timer": "/up/order.timer"}
        for name, target in escapes.items():
            self.link(image, wants + name, target)
        cycles = {"self.timer": "self.timer", "pair-a.timer": "pair-b.timer",
                  "pair-b.timer": "pair-a.timer", "parent.timer": "/ploop/x.timer",
                  "parent-pair.timer": "/pa/x.timer", "mixed.timer": "/mixdir/x"}
        self.link(image, "ploop", "ploop")
        self.link(image, "pa", "pb")
        self.link(image, "pb", "pa")
        self.link(image, "mixdir", wants + "mixed.timer")
        for name, target in cycles.items():
            self.link(image, wants + name, target)
        for name in escapes:
            with self.subTest(escape=name):
                self.assert_unit_rejected(image, wants + name, "outside image")
        for name in cycles:
            with self.subTest(cycle=name):
                self.assert_unit_rejected(image, wants + name, "cycle/depth")
        report = self.scan(1, image=image)
        rejected = {wants + name for name in [*escapes, *cycles]}
        self.assertEqual(set(report["authentication_config"]), rejected)

    def build_alias_chain(self, image, tag, parent_hops, leaf_hops):
        """Return an alias whose resolution follows parent_hops + leaf_hops links."""
        self.put(f"usr/lib/systemd/system/depth-{tag}.timer", "[Timer]\n# depth target\n", image)
        directory = "/usr/lib/systemd/system"
        for index in range(1, parent_hops + 1):
            self.link(image, f"p-{tag}-{index}",
                      "usr/lib/systemd/system" if index == 1 else f"p-{tag}-{index - 1}")
            directory = f"/p-{tag}-{index}"
        wants = "etc/systemd/system/timers.target.wants/"
        for index in range(1, leaf_hops + 1):
            self.link(image, f"{wants}a-{tag}-{index}.timer",
                      f"{directory}/depth-{tag}.timer" if index == 1 else f"a-{tag}-{index - 1}.timer")
        return f"{wants}a-{tag}-{leaf_hops}.timer"

    def test_unit_resolver_cumulative_hop_bound(self):
        # B2/B3: the bound covers the whole chain; it is never reset per layer.
        limit = UNIT_ALIAS_MAX_HOPS
        image = self.pristine_image("depth")
        accepted = [self.build_alias_chain(image, "leaf-max", 0, limit),
                    self.build_alias_chain(image, "parent-max", limit - 1, 1),
                    self.build_alias_chain(image, "split-max", limit // 2, limit // 2)]
        rejected = [self.build_alias_chain(image, "leaf-over", 0, limit + 1),
                    self.build_alias_chain(image, "parent-over", limit, 1),
                    self.build_alias_chain(image, "split-over", limit // 2 + 1, limit // 2)]
        for rel in accepted:
            with self.subTest(accepted=rel):
                self.assertEqual(self.resolve_unit(image, rel), b"[Timer]\n# depth target\n")
        for rel in rejected:
            with self.subTest(rejected=rel):
                self.assert_unit_rejected(image, rel, "cycle/depth")
        report = self.scan(1, image=image)
        self.assertEqual(set(report["authentication_config"]), set(rejected))

    def test_unit_resolver_terminals_and_errors_fail_closed(self):
        # B3: dangling, missing, non-regular terminals/components, OSError.
        image, _ = self.merged_usr_image("terminals")
        vendor = image / "usr/lib/systemd/system"
        fifo = vendor / "fifo.timer"
        os.mkfifo(fifo)
        sentinel = self.put("outside-sentinel.timer",
                            "[Service]\nExecStart=-/sbin/agetty --autologin root tty1\n", self.root)
        self.link(image, "gone", "missing-directory")
        wants = "etc/systemd/system/timers.target.wants/"
        rows = {"dangling-leaf.timer": "missing.timer",
                "dangling-parent.timer": "/gone/systemd/system/fstrim.timer",
                "missing-middle.timer": "/usr/lib/nonexistent/system/fstrim.timer",
                "terminal-directory.timer": "/usr/lib/systemd/system",
                "terminal-directory-alias.timer": "/lib/systemd/system",
                "regular-middle.timer": "/lib/systemd/system/fstrim.timer/child",
                "fifo-direct.timer": "../../../../usr/lib/systemd/system/fifo.timer",
                "fifo-alias.timer": "/lib/systemd/system/fifo.timer",
                "fifo-middle.timer": "/lib/systemd/system/fifo.timer/child",
                "host-absolute.timer": str(sentinel)}
        for name, target in rows.items():
            self.link(image, wants + name, target)
        for name in rows:
            with self.subTest(row=name):
                self.assert_unit_rejected(image, wants + name, never_open=[fifo])
        # The FIFO is skipped, never opened; a regression would block here.
        report = self.scan(1, image=image)
        self.assertEqual(set(report["authentication_config"]), {wants + name for name in rows})
        self.assertNotIn("autologin", json.dumps(report))
        # Controlled OSError on lstat, readlink and the final read: rejected,
        # reported without exception text.
        scanner = load_module("pristine", RECIPE / "scan-pristine-rootfs.py")
        self.put("opt/units/error.timer", "[Timer]\n# readable bytes\n", image)
        error_rel = wants + "error.timer"
        self.link(image, error_rel, "/opt/units/error.timer")
        self.assertEqual(self.resolve_unit(image, error_rel), b"[Timer]\n# readable bytes\n")
        failing = {"lstat": image / "opt/units", "readlink": image / "lib",
                   "open": image / "opt/units/error.timer"}
        import builtins
        for operation, target in failing.items():
            with self.subTest(oserror=operation):
                def failing_call(original, _target=str(target)):
                    def fail(path, *args, **kwargs):
                        if not isinstance(path, int) and os.fsdecode(os.fspath(path)) == _target:
                            raise PermissionError("synthetic secret exception text")
                        return original(path, *args, **kwargs)
                    return fail
                rel = error_rel if operation != "readlink" else wants + "fstrim.timer"
                patches = [mock.patch.object(os, operation, failing_call(getattr(os, operation)))]
                if operation == "open":
                    # Any read API, so the row does not depend on how bytes are read.
                    patches += [mock.patch.object(io, "open", failing_call(io.open)),
                                mock.patch.object(builtins, "open", failing_call(io.open))]
                with contextlib.ExitStack() as stack:
                    for patch in patches:
                        stack.enter_context(patch)
                    with self.assertRaises(OSError):
                        scanner.unit_link_contents(image, rel)
                    output = io.StringIO()
                    with mock.patch.object(sys, "argv", ["scan", str(image)]), \
                            contextlib.redirect_stdout(output):
                        self.assertEqual(scanner.main(), 1)
                report = json.loads(output.getvalue())
                self.assertIn(rel, report["authentication_config"])
                self.assertNotIn("synthetic secret", output.getvalue())

    def test_unit_masks_and_authentication_through_aliases(self):
        # B4: exact /dev/null leaf masks, direct or at the end of a valid chain.
        image, _ = self.merged_usr_image("masks")
        system = "etc/systemd/system/"
        self.link(image, system + "getty@tty1.service", "/dev/null")
        self.link(image, system + "chain-mask.service", "chain-mask-2.service")
        self.link(image, system + "chain-mask-2.service", "/dev/null")
        self.link(image, "usr/lib/systemd/system/vendor-mask.service", "/dev/null")
        self.link(image, system + "merged-mask.service", "/lib/systemd/system/vendor-mask.service")
        masks = ["getty@tty1.service", "chain-mask.service", "merged-mask.service"]
        for name in masks:
            with self.subTest(mask=name):
                self.assertEqual(self.resolve_unit(image, system + name), b"")
        self.assertEqual(self.scan(image=image)["authentication_config"], [])
        # /dev/null is not a parent-component, other-device or spelling exception.
        not_masks = {"null-parent.service": "/dev/null/child", "zero.service": "/dev/zero",
                     "dot-null.service": "/dev/./null", "double-null.service": "/dev//null",
                     "relative-null.service": "../../../dev/null",
                     "null-trailing.service": "/dev/null/"}
        self.link(image, "devlink", "/dev")
        not_masks["devlink.service"] = "/devlink/null"
        for name, target in not_masks.items():
            self.link(image, system + name, target)
        for name in not_masks:
            with self.subTest(not_mask=name):
                self.assert_unit_rejected(image, system + name)
        # Autologin reached through merged-/usr, mixed chains and a destination
        # outside the ordinary unit directories is still rejected at the alias.
        autologin = "[Service]\nExecStart=-/sbin/agetty --autologin root tty1\n"
        self.put("usr/lib/systemd/system/getty-auto.service", autologin, image)
        self.link(image, "usr/lib/systemd/system/x-auto.service", "getty-auto.service")
        self.link(image, "compat", "lib")
        self.put("opt/vendor/evil.service", "[Service]\nExecStart=/bin/login -f root\n", image)
        self.link(image, "optlink", "opt/vendor")
        auth = {"getty.target.wants/getty@tty2.service": "/lib/systemd/system/getty-auto.service",
                "mixed-auto.service": "/compat/systemd/system/x-auto.service",
                "outside-dirs.service": "/opt/vendor/evil.service",
                "outside-alias.service": "/optlink/../vendor/evil.service"}
        for name, target in auth.items():
            self.link(image, system + name, target)
        # Identity and authentication symlinks to /dev/null keep their findings.
        self.link(image, "etc/sudoers.d/masked", "/dev/null")
        self.link(image, "etc/greetd/config.toml", "/dev/null")
        report = self.scan(1, image=image)
        flagged = set(report["authentication_config"])
        self.assertLessEqual({system + name for name in [*not_masks, *auth]}, flagged)
        self.assertLessEqual({"etc/sudoers.d/masked", "etc/greetd/config.toml"}, flagged)
        self.assertTrue(flagged.isdisjoint({system + name for name in masks}))
        self.assertTrue(flagged.isdisjoint(f"etc/systemd/system/timers.target.wants/{t}.timer"
                                           for t in TIMERS))

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
        (self.root / "image/usr/lib/fixture").unlink()
        # C1: producer-shaped NUL-separated strings, as rustc embeds panic and
        # debug paths. Neutral remapped paths and the generic /home/ root pass;
        # this synthetic control is NOT evidence that a real remap succeeded.
        image = self.root / "image"
        release = "usr/lib/ditto/target/release/"
        owned = [release + name for name in ("ditto-core", "dittoctl", "ditto-test-host", "ditto-worker")]
        neutral = b"\x7fELF\x02\x01\x01\x00\x00" + b"\x00".join((
            b"/rustc/0123456789abcdef0123456789abcdef01234567/library/core/src/panicking.rs",
            b"/ditto/source/crates/ditto-core/src/main.rs",
            b"/cargo/registry/src/index.crates.io-0000000000000000/serde-1.0.0/src/de/mod.rs",
            b"/rustup/toolchain/lib/rustlib/src/rust/library/std/src/thread/mod.rs",
            b"/home/", b"@{HOMEDIRS}=/home/")) + b"\x00"
        for rel in owned:
            (image / rel).parent.mkdir(parents=True, exist_ok=True)
            (image / rel).write_bytes(neutral)
        self.assertEqual(self.scan()["literal_matches"], [])
        markers = (b"/home/producer/ditto/crates/ditto-core/src/main.rs",
                   b"/home/producer/.cargo/registry/src/index/serde-1.0.0/src/lib.rs",
                   b"/data/runner/agent-runs/task/repo/crates/core/src/lib.rs",
                   b"/data/runner/worktrees/ditto/crates/core/src/lib.rs",
                   b"/data/runner/ditto-runs/run/crates/core/src/lib.rs",
                   b"/data/runner/cache/scratch/target/release/build/out.rs")
        others = ["usr/lib/fixture-unknown", "usr/lib/ditto-node/bin/node",
                  "usr/share/doc/vendor-fixture/examples/README"]
        for rel in [*owned, *others]:
            for marker in markers:
                with self.subTest(path=rel, marker=marker):
                    original = (image / rel).read_bytes() if (image / rel).exists() else None
                    (image / rel).parent.mkdir(parents=True, exist_ok=True)
                    (image / rel).write_bytes(neutral[:-1] + b"\x00" + marker + b"\x00")
                    self.assertEqual(self.scan(1)["literal_matches"], [rel])
                    if original is None:
                        (image / rel).unlink()
                    else:
                        (image / rel).write_bytes(original)
        link = image / (release + "ditto-core-debug")
        for marker in markers:
            with self.subTest(link=marker):
                link.symlink_to(marker.decode())
                self.assertEqual(self.scan(1)["literal_matches"], [release + "ditto-core-debug"])
                link.unlink()
        # Registering an owned artifact's hash (or the marker's) as a "public
        # fixture" does not mask a producer leak; neither does the GnuTLS path.
        polluted = neutral + markers[0] + b"\x00"
        recipe = self.root / "recipe-with-registered-hash"
        recipe.mkdir()
        shutil.copy2(RECIPE / "scan-pristine-rootfs.py", recipe)
        approved = json.loads((RECIPE / "public-selftest-key-sha256.json").read_text())
        approved += [hashlib.sha256(polluted).hexdigest(), hashlib.sha256(markers[0]).hexdigest()]
        (recipe / "public-selftest-key-sha256.json").write_text(json.dumps(approved))
        (image / owned[0]).write_bytes(polluted)
        gnutls = "usr/lib/x86_64-linux-gnu/libgnutls.so.30.41.1"
        (image / gnutls).parent.mkdir(parents=True, exist_ok=True)
        (image / gnutls).write_bytes(polluted)
        report = self.scan(1, recipe=recipe)
        self.assertEqual(sorted(report["literal_matches"]), sorted([owned[0], gnutls]))
        self.assertEqual(report["public_fixtures"], [])
        # Nor does registering the owned artifact in the public producer-path
        # manifest: an owned path makes the whole manifest invalid (fail closed).
        manifest = json.loads((RECIPE / PUBLIC_PRODUCER_MANIFEST).read_text()) \
            if (RECIPE / PUBLIC_PRODUCER_MANIFEST).is_file() else self.fixture_manifest()
        manifest["entries"].append(self.fixture_entry(owned[0], polluted))
        (recipe / PUBLIC_PRODUCER_MANIFEST).write_text(json.dumps(manifest))
        report = self.scan(1, recipe=recipe)
        self.assertEqual(sorted(report["literal_matches"]), sorted([owned[0], gnutls]))
        self.assertEqual(report.get("public_producer_fixtures"), [])
        self.assertIn(PUBLIC_PRODUCER_MANIFEST, [row["file"] for row in report["errors"]])

    @staticmethod
    def fixture_entry(rel=UPSTREAM_REL, data=UPSTREAM_BYTES, kind="ubuntu-deb"):
        if kind == "ubuntu-deb":
            source = {"kind": "ubuntu-deb", "package": "vendor-fixture", "version": "1.0-1",
                      "deb": "pool/main/v/vendor-fixture/vendor-fixture_1.0-1_all.deb",
                      "deb_sha256": "a" * 64,
                      "packages_index": "https://snapshot.example.invalid/main/binary-amd64/Packages.xz",
                      "index_sha256": "b" * 64}
            level = "signed-snapshot-index"
        else:
            source = {"kind": "upstream-archive", "name": "node", "version": "0.0.1",
                      "url": "https://dist.example.invalid/node-v0.0.1-linux-x64.tar.xz",
                      "member": "node-v0.0.1-linux-x64/bin/node", "archive_sha256": "c" * 64,
                      "shasums_url": "https://dist.example.invalid/SHASUMS256.txt"}
            level = "https-shasums-pgp-unverified"
        return {"path": rel, "sha256": sha256_hex(data), "bytes": len(data), "source": source,
                "verification": {"level": level, "detail": "synthetic task-owned fixture"},
                "classification": "synthetic upstream example, not a Ditto producer path"}

    def fixture_manifest(self, *entries):
        return {"schema": 1, "authority": "synthetic task-owned manifest",
                "entries": list(entries) or [self.fixture_entry()]}

    def fixture_recipe(self, manifest):
        """Task-owned scanner copy; manifest is an object, raw text, None (absent) or 'directory'."""
        recipe = self.root / f"fixture-recipe-{next(self.counter)}"
        recipe.mkdir()
        for name in ("scan-pristine-rootfs.py", "public-selftest-key-sha256.json"):
            shutil.copy2(RECIPE / name, recipe)
        path = recipe / PUBLIC_PRODUCER_MANIFEST
        if manifest == "directory":
            path.mkdir()
        elif isinstance(manifest, str):
            path.write_text(manifest)
        elif manifest is not None:
            path.write_text(json.dumps(manifest))
        return recipe

    def fixture_image(self, files):
        image = self.pristine_image(f"public-{next(self.counter)}")
        for rel, data in files.items():
            (image / rel).parent.mkdir(parents=True, exist_ok=True)
            (image / rel).write_bytes(data)
        return image

    def assert_no_content(self, report):
        text = json.dumps(report)
        for secret in ("upstream-author", "U1lOVEhFVElDS0VZ", "NOPASSWD", "autologin"):
            self.assertNotIn(secret, text)

    def test_public_producer_fixture_exact_match_is_classified(self):
        # D1/D2 positive: one unique, complete entry; the report keeps path,
        # source identity and hash, never the matched content.
        node = b"\x7fELF\x02\x01\x01\x00\x00/home/iojs-like/build/node\x00"
        node_rel = "usr/lib/ditto-node/bin/node"
        recipe = self.fixture_recipe(self.fixture_manifest(
            self.fixture_entry(), self.fixture_entry(node_rel, node, "upstream-archive")))
        image = self.fixture_image({UPSTREAM_REL: UPSTREAM_BYTES, node_rel: node})
        report = self.scan(image=image, recipe=recipe)
        self.assertEqual(report["literal_matches"], [])
        self.assertEqual(report["errors"], [])
        rows = {row["file"]: row for row in report.get("public_producer_fixtures", [])}
        self.assertEqual(set(rows), {UPSTREAM_REL, node_rel})
        self.assertEqual(rows[UPSTREAM_REL]["sha256"], sha256_hex(UPSTREAM_BYTES))
        self.assertEqual((rows[UPSTREAM_REL]["source"]["package"], rows[UPSTREAM_REL]["source"]["version"]),
                         ("vendor-fixture", "1.0-1"))
        self.assertEqual(rows[UPSTREAM_REL]["verification"], "signed-snapshot-index")
        self.assertEqual(rows[node_rel]["verification"], "https-shasums-pgp-unverified")
        self.assertNotIn("iojs-like", json.dumps(report))
        self.assert_no_content(report)
        # Control: the committed manifest does not cover this synthetic path.
        self.assertEqual(sorted(self.scan(1, image=image)["literal_matches"]), sorted([UPSTREAM_REL, node_rel]))

    def test_public_producer_fixture_requires_exact_path_and_bytes(self):
        # D1 negatives: only the exact path AND the complete bytes classify.
        other = "usr/share/doc/other-vendor/examples/asoundrc.txt"
        modified = UPSTREAM_BYTES.replace(b"upstream example", b"upstream exbmple")
        rows = {
            "one-byte": ({UPSTREAM_REL: modified}, [self.fixture_entry()], UPSTREAM_REL),
            "truncated": ({UPSTREAM_REL: UPSTREAM_BYTES[:-1]}, [self.fixture_entry()], UPSTREAM_REL),
            "appended-private": ({UPSTREAM_REL: UPSTREAM_BYTES + b"/home/producer/ditto\n"},
                                 [self.fixture_entry()], UPSTREAM_REL),
            "appended-neutral": ({UPSTREAM_REL: UPSTREAM_BYTES + b"\n"}, [self.fixture_entry()], UPSTREAM_REL),
            "same-bytes-other-path": ({other: UPSTREAM_BYTES}, [self.fixture_entry()], other),
            "unknown-file-same-pattern": ({"usr/lib/fixture-unknown": b"/home/upstream-author/scopes\n"},
                                          [self.fixture_entry()], "usr/lib/fixture-unknown"),
            "directory-prefix-entry": ({UPSTREAM_REL: UPSTREAM_BYTES},
                                       [self.fixture_entry(str(Path(UPSTREAM_REL).parent))], UPSTREAM_REL),
            "size-mismatch": ({UPSTREAM_REL: UPSTREAM_BYTES},
                              [self.fixture_entry() | {"bytes": len(UPSTREAM_BYTES) + 1}], UPSTREAM_REL),
            "partial-string-hash": ({UPSTREAM_REL: UPSTREAM_BYTES},
                                    [self.fixture_entry() | {"sha256": sha256_hex(b"/home/upstream-author")}],
                                    UPSTREAM_REL),
        }
        for name, (files, entries, rel) in rows.items():
            with self.subTest(row=name):
                report = self.scan(1, image=self.fixture_image(files),
                                   recipe=self.fixture_recipe(self.fixture_manifest(*entries)))
                self.assertEqual(report["literal_matches"], [rel])
                self.assertEqual(report.get("public_producer_fixtures"), [])
                self.assertEqual(report["errors"], [])

    def test_public_producer_manifest_fails_closed(self):
        # D2: any manifest defect fails the scan and classifies nothing.
        entry = self.fixture_entry()
        good = self.fixture_manifest(entry)

        def with_entry(**changes):
            return self.fixture_manifest(entry | changes)

        def with_source(drop=None, **changes):
            source = entry["source"] | changes
            source.pop(drop, None)
            return with_entry(source=source)

        text = json.dumps(good)
        rows = {
            "absent": None, "directory": "directory", "not-json": "{not json",
            "empty-file": "", "top-level-list": [entry],
            "duplicate-top-key": text.replace('"schema": 1', '"schema": 1, "schema": 1'),
            "duplicate-entry-key": text.replace('"bytes": ', '"bytes": 1, "bytes": '),
            "nan-bytes": text.replace(f'"bytes": {len(UPSTREAM_BYTES)}', '"bytes": NaN'),
            "duplicate-entry": self.fixture_manifest(entry, entry),
            "conflicting-entry": self.fixture_manifest(entry, entry | {"sha256": "d" * 64}),
            "empty-entries": {**good, "entries": []},
            "unknown-schema": {**good, "schema": 2},
            "unknown-top-key": {**good, "extra": True},
            "unknown-entry-key": with_entry(note="x"),
            "uppercase-digest": with_entry(sha256=entry["sha256"].upper()),
            "short-digest": with_entry(sha256=entry["sha256"][:63]),
            "non-hex-digest": with_entry(sha256="g" * 64),
            "bad-deb-digest": with_source(deb_sha256="xyz"),
            "bytes-bool": with_entry(bytes=True), "bytes-string": with_entry(bytes="77"),
            "bytes-zero": with_entry(bytes=0), "bytes-negative": with_entry(bytes=-1),
            "missing-source": self.fixture_manifest({k: v for k, v in entry.items() if k != "source"}),
            "missing-version": with_source(drop="version"),
            "empty-version": with_source(version=""),
            "missing-package": with_source(drop="package"),
            "unknown-source-kind": with_source(kind="ppa"),
            "level-mismatch": with_entry(verification={"level": "https-shasums-pgp-unverified",
                                                       "detail": "x"}),
            "missing-classification": self.fixture_manifest(
                {k: v for k, v in entry.items() if k != "classification"}),
            "empty-classification": with_entry(classification=""),
        }
        for index, path in enumerate(("/" + UPSTREAM_REL, UPSTREAM_REL.replace("/", "//", 1),
                                      "usr/./" + UPSTREAM_REL[4:], "usr/../" + UPSTREAM_REL,
                                      UPSTREAM_REL + "/", UPSTREAM_REL.replace("/", "\\", 1),
                                      UPSTREAM_REL + "\x00")):
            rows[f"non-canonical-{index}"] = with_entry(path=path)
        for path in ("usr/lib/ditto/target/release/ditto-core", "usr/lib/ditto/target/release/dittoctl",
                     "usr/share/ditto/runtime-lock.json", "usr/local/libexec/ditto-session",
                     "usr/share/doc/ditto-runtime/NOTICE"):
            rows["owned-" + path] = self.fixture_manifest(entry, self.fixture_entry(path))
        image = self.fixture_image({UPSTREAM_REL: UPSTREAM_BYTES})
        self.assertEqual(self.scan(image=image, recipe=self.fixture_recipe(good))["literal_matches"], [])
        for name, manifest in rows.items():
            with self.subTest(row=name):
                result = call(sys.executable, self.fixture_recipe(manifest) / "scan-pristine-rootfs.py", image)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertNotIn("Traceback", result.stderr)
                report = json.loads(result.stdout)
                self.assertIn(PUBLIC_PRODUCER_MANIFEST, [row["file"] for row in report["errors"]])
                self.assertEqual(report["literal_matches"], [UPSTREAM_REL])
                self.assertEqual(report["public_producer_fixtures"], [])
                self.assert_no_content(report)

    def test_public_producer_fixture_does_not_dominate_other_checks(self):
        # D3: an exact manifest match only reclassifies the producer-path hit.
        home = b"# from /home/upstream-author/src\n"
        rows = {
            "forbid": (UPSTREAM_REL, UPSTREAM_BYTES, ("--forbid", "upstream-author"), "literal_matches"),
            "private-key": (UPSTREAM_REL, UPSTREAM_BYTES + SYNTHETIC_KEY, (), "unapproved_keys"),
            "nopasswd": ("etc/sudoers.d/vendor-fixture", home + b"fixture ALL=(ALL) NOPASSWD: ALL\n", (),
                         "authentication_config"),
            "autologin": ("etc/systemd/system/getty@tty1.service.d/vendor.conf",
                          home + b"[Service]\nExecStart=-/sbin/agetty --autologin root tty1\n", (),
                          "authentication_config"),
            "identity": ("etc/ssh/ssh_host_ed25519_key", home, (), "identity_files"),
            "gnutls-extra-key": ("usr/lib/x86_64-linux-gnu/libgnutls.so.30.41.1", home + SYNTHETIC_KEY, (),
                                 "unapproved_keys"),
        }
        for name, (rel, data, flags, finding) in rows.items():
            with self.subTest(row=name):
                recipe = self.fixture_recipe(self.fixture_manifest(self.fixture_entry(rel, data)))
                report = self.scan(1, flags, image=self.fixture_image({rel: data}), recipe=recipe)
                self.assertIn(rel, report[finding])
                self.assertEqual(report["errors"], [])
                self.assertEqual(report["public_fixtures"], [])
                if name == "forbid":
                    self.assertEqual(report.get("public_producer_fixtures"), [])
                self.assert_no_content(report)
        # A read error is reported, never classified, and leaks no exception text.
        recipe = self.fixture_recipe(self.fixture_manifest())
        image = self.fixture_image({UPSTREAM_REL: UPSTREAM_BYTES})
        scanner = load_module("pristine_fixture", recipe / "scan-pristine-rootfs.py")
        original_read = Path.read_bytes

        def unreadable(path):
            if path.as_posix().endswith(UPSTREAM_REL):
                raise PermissionError("synthetic secret exception text")
            return original_read(path)
        output = io.StringIO()
        with mock.patch.object(Path, "read_bytes", unreadable), mock.patch.object(
                sys, "argv", ["scan", str(image)]), contextlib.redirect_stdout(output):
            self.assertEqual(scanner.main(), 1)
        report = json.loads(output.getvalue())
        self.assertIn(UPSTREAM_REL, [row["file"] for row in report["errors"]])
        self.assertEqual(report.get("public_producer_fixtures"), [])
        self.assertNotIn("synthetic secret", output.getvalue())

    def test_committed_public_producer_manifest(self):
        # D1: the committed manifest lists exactly the eight independently
        # source-verified public hits, no owned artifact, and Node's weaker
        # verification level stays explicit.
        manifest = RECIPE / PUBLIC_PRODUCER_MANIFEST
        self.assertTrue(manifest.is_file(), "public producer-path manifest missing")
        scanner = load_module("pristine", RECIPE / "scan-pristine-rootfs.py")
        fixtures = scanner.load_public_producer_fixtures(manifest)
        self.assertEqual(set(fixtures), REAL_PUBLIC_PRODUCER_PATHS)
        self.assertFalse(any(path.startswith(OWNED_IMAGE_PREFIXES) for path in fixtures))
        for path, entry in fixtures.items():
            with self.subTest(path=path):
                if path == "usr/lib/ditto-node/bin/node":
                    self.assertEqual(entry["source"]["kind"], "upstream-archive")
                    self.assertEqual(entry["source"]["version"], "22.23.2")
                    self.assertEqual(entry["verification"]["level"], "https-shasums-pgp-unverified")
                    self.assertIn("PGP", entry["verification"]["detail"])
                else:
                    self.assertEqual(entry["source"]["kind"], "ubuntu-deb")
                    self.assertIn("20261020T000000Z", entry["source"]["packages_index"])
                    self.assertEqual(entry["verification"]["level"], "signed-snapshot-index")
        # Different bytes at a registered path stay a literal finding.
        rel = "usr/lib/x86_64-linux-gnu/libgtk-3.so.0.2420.32"
        report = self.scan(1, image=self.fixture_image({rel: b"\x00/home/upstream-author/icons\x00"}))
        self.assertEqual(report["literal_matches"], [rel])
        self.assertEqual(report.get("public_producer_fixtures"), [])

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

    # Every generator mode. There is no fault-injection mode in this generator;
    # dev-software-render is listed as a mode here, not as fault evidence.
    MODES = (((), "normal"), (("--dev-software-render",), "dev-software-render"))

    def closure_violations(self, recipe=RECIPE):
        """Parse the generator's actual mkosi.conf in every mode; list violations."""
        violations, closures = [], {}
        for flags, mode in self.MODES:
            output, _ = self.generate(flags=flags, recipe=recipe)
            conf = configparser.ConfigParser(interpolation=None, strict=True)
            conf.optionxform = str
            conf.read(output / "mkosi.conf")
            packages = conf["Content"]["Packages"].split(",")
            inputs = json.loads((output / "extra/usr/share/ditto/image-inputs.json").read_text())
            if conf["Distribution"]["Snapshot"] != SNAPSHOT or inputs["snapshot"] != SNAPSHOT:
                violations.append(f"{mode}: snapshot is not {SNAPSHOT}")
            if inputs["mode"] != mode:
                violations.append(f"{mode}: recorded mode differs")
            if len(packages) != len(set(packages)) or not all(packages):
                violations.append(f"{mode}: duplicate or empty package entry")
            missing = QUICKSHELL_TARGET_PACKAGES - set(packages)
            if missing:
                violations.append(f"{mode}: Quickshell target closure lacks {sorted(missing)}")
            if "linux-image-7.0.0-38-generic" not in packages:
                violations.append(f"{mode}: kernel pin missing")
            # Distro libraries arrive as packages, never through the runtime tree.
            staged = [p.name for p in (output / "runtime").rglob("*")]
            if any(name.startswith("libunwind") for name in staged):
                violations.append(f"{mode}: distro libunwind staged in runtime tree")
            closures[mode] = packages
        if len(set(map(tuple, closures.values()))) != 1:
            violations.append("generator modes produce different package closures")
        return violations, closures

    def test_target_package_closure_includes_libunwind_in_every_mode(self):
        violations, closures = self.closure_violations()
        self.assertEqual(violations, [])
        declared = [line for line in (RECIPE / "packages.txt").read_text().splitlines()
                    if line and not line.startswith("#")]
        for mode, packages in closures.items():
            self.assertEqual(packages, declared, mode)

    def test_closure_contract_detects_missing_or_single_mode_fix(self):
        # Controls for the contract itself on task-owned recipe copies.
        rows = {}
        recipe = self.root / "recipe-without-unwind"
        shutil.copytree(RECIPE, recipe, ignore=shutil.ignore_patterns("tests", "__pycache__"))
        packages = recipe / "packages.txt"
        packages.write_text("".join(line + "\n" for line in packages.read_text().splitlines()
                                    if line != "libunwind8"))
        rows["missing"] = recipe
        recipe = self.root / "recipe-dev-only-unwind"
        shutil.copytree(rows["missing"], recipe)
        generator = recipe / "generate.py"
        anchor = '        put("mkosi.conf", f"""[Distribution]'
        text = generator.read_text()
        self.assertEqual(text.count(anchor), 1)
        generator.write_text(text.replace(anchor, "        if args.dev_software_render:\n"
                                          "            packages.append(\"libunwind8\")\n" + anchor))
        rows["dev-only"] = recipe
        for name, recipe in rows.items():
            with self.subTest(row=name):
                violations, _ = self.closure_violations(recipe)
                self.assertTrue(any("libunwind8" in row for row in violations), violations)
                if name == "dev-only":
                    self.assertIn("generator modes produce different package closures", violations)

    def test_distro_unwind_library_is_not_runtime_admitted(self):
        # The fix is a target package; runtime system-library admission stays closed.
        for name in ("libunwind.so.8", "libunwind.so.8.2.0"):
            with self.subTest(name=name):
                path = self.put("usr/lib/x86_64-linux-gnu/" + name, "synthetic distro library", self.tree)
                _, result = self.generate(2)
                self.assertIn("not admitted", result.stderr)
                lock = call(sys.executable, RECIPE / "lock-runtime.py", "--runtime-tree", self.tree,
                            "--source-commit", self.commit, "--source-sha256", self.lock()["source_sha256"])
                self.assertEqual(lock.returncode, 2, lock.stderr)
                self.assertIn("not admitted", lock.stderr)
                path.unlink()
        lib = self.put("usr/lib/x86_64-linux-gnu/libwf-config.so.0", "synthetic library", self.tree)
        (lib.parent / "libunwind.so.8").symlink_to(lib.name)
        _, result = self.generate(2)
        self.assertIn("not admitted", result.stderr)


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

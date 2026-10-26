"""Backend protocol, medium detection and text frontend on task-owned files only.

The backend serves a real AF_UNIX socket in a temporary directory; targets are
sparse regular files (allow_regular_file=True is passed only by these tests).
"""

import configparser
import errno
import functools
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import threading
import time
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))

import test_installer as base  # noqa: E402
from ditto_installer import backend, client, medium, messages, protocol, service, session, textui, writer  # noqa: E402

LABEL = "DITTO_INSTALL_7"


def wait_for(predicate, timeout=20.0):
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() > deadline:
            raise AssertionError("condition not reached")
        time.sleep(0.01)


class BackendFixture(base.Fixture):
    def start(self, *, allowed_uid=None, corrupt=False, prepare_error=None, install_wrapper=None):
        self.source_disk_path, self.payload, digest = self.build_payload()
        man = self.load(self.payload, digest)
        if corrupt:
            path = self.payload / man.role("usr").payload.file
            data = bytearray(path.read_bytes())
            data[len(data) // 3] ^= 0x01
            path.write_bytes(data)
        self.sysfs = self.path("sys")
        self.devroot = self.path("dev")
        self.devroot.mkdir()
        self.target_path = self.devroot / "sdz"
        shutil.copyfile(self.target(), self.target_path)
        self.before = base.file_sha(self.target_path)
        base.make_block(self.sysfs, "sdz", dev="8:240", size_bytes=os.path.getsize(self.target_path),
                        model="Task Disk", serial="TASK-0001", serial_at="serial", wwid="eui.task0001")
        base.make_block(self.sysfs, "sdy", dev="8:224", removable=1)
        base.make_block(self.sysfs, "sdb", dev="8:16", model="USB Stick", partitions=("8:17",))
        self.config = {"schema": 1, "manifest_sha256": digest, "medium_label": LABEL,
                       "payload_dir": "ditto/payload", "frontend_user": "ditto-installer"}
        self.reboots = []

        def fake_find(label, payload_subdir, **_):
            if prepare_error:
                raise prepare_error
            self.assertEqual((label, payload_subdir), (LABEL, "ditto/payload"))
            return medium.Medium(Path("/dev/sdb"), self.payload, frozenset({"8:16"}))
        install = functools.partial(writer.install, allow_regular_file=True)
        if install_wrapper:
            install = install_wrapper(install)
        self.mountinfo = self.path("mountinfo")
        self.mountinfo.write_text("")
        empty = self.path("empty")
        empty.write_text("")
        prepare = service.make_prepare(self.config, find=fake_find, sysfs=self.sysfs, dev_root=self.devroot,
                                       mountinfo_path=self.mountinfo, swaps_path=empty, install=install)
        self.backend = backend.Backend(prepare, lambda: self.reboots.append("reboot"))
        self.backend.prepare()
        self.sock = self.root / "backend.sock"
        server = backend.listen(self.sock)
        self.stop = threading.Event()
        self.thread = threading.Thread(target=backend.serve,
                                       args=(server, self.backend, os.getuid() if allowed_uid is None else allowed_uid,
                                             self.stop), daemon=True)
        self.thread.start()
        self.addCleanup(self._shutdown, server)
        self.client = client.Client(self.sock, connect_timeout=5)
        self.addCleanup(self.client.close)
        return self.client

    def _shutdown(self, server):
        self.stop.set()
        self.thread.join(5)
        server.close()
        self.backend.wait(30)

    def raw(self, payload):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.connect(str(self.sock))
            sock.sendall(payload)
            sock.shutdown(socket.SHUT_WR)
            data = b""
            while chunk := sock.recv(65536):
                data += chunk
        return [json.loads(line) for line in data.splitlines()]

    def select_target(self):
        listing = self.client.request("list")
        self.assertTrue(listing["ok"], listing)
        token = next(d["token"] for d in listing["disks"] if d["name"] == "sdz")
        chosen = self.client.request("select", token=token)
        self.assertTrue(chosen["ok"], chosen)
        return chosen

    def finish(self):
        wait_for(lambda: self.client.request("state")["state"] != "installing")
        self.backend.wait(30)
        return self.client.request("state")

    def gated(self, stage):
        """Install wrapper that pauses once at `stage` until the test sends cancel."""
        self.reached, self.release = threading.Event(), threading.Event()

        def wrap(install):
            def run(man, payload_dir, target, disk, *, progress, **kwargs):
                def gate_progress(name, done, total):
                    progress(name, done, total)
                    if name == stage and not self.reached.is_set():
                        self.reached.set()
                        self.release.wait(20)
                if stage != "readback":
                    return install(man, payload_dir, target, disk, progress=gate_progress, **kwargs)
                real = writer._read_region

                def gate_read(*args):
                    if not self.reached.is_set():
                        self.reached.set()
                        self.release.wait(20)
                    return real(*args)
                with mock.patch.object(writer, "_read_region", gate_read):
                    return install(man, payload_dir, target, disk, progress=progress, **kwargs)
            return run
        return wrap


class ProtocolTests(BackendFixture):
    def test_peer_uid_rejected_before_any_request_is_read(self):
        self.start(allowed_uid=os.getuid() + 1)
        # The verdict is sent on accept, before anything is read.
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(5)   # a missing check would leave the connection open: fail, never hang
            sock.connect(str(self.sock))
            data = b""
            try:
                while chunk := sock.recv(65536):
                    data += chunk
            except TimeoutError:
                self.fail("server kept an unauthorised connection open")
        self.assertEqual(json.loads(data), {"ok": False, "error": "peer_rejected"})
        # Requests sent anyway are never acted on (the reply may be lost to a reset).
        try:
            self.raw(protocol.request_line("list") + protocol.request_line("reboot"))
        except ConnectionResetError:
            pass
        time.sleep(0.2)
        self.assertEqual(self.backend.session.state, session.LISTING)
        self.assertEqual(self.backend.session._offers, {})
        self.assertEqual(self.reboots, [])

    def test_invalid_requests_change_nothing(self):
        self.start()
        bad = [b"not json\n", b'{"action": "format"}\n', b'{"action": "list", "target": "/dev/sda"}\n',
               b'{"action": "select"}\n', b'{"action": "select", "token": 5}\n',
               b'{"action": "select", "token": "../../dev/sda"}\n', b'{"action": "confirm", "token": ""}\n',
               b'{"action": "list", "action": "reboot"}\n', b'{"action": "state", "x": NaN}\n',
               b'["list"]\n', b'{"action": "reboot", "command": "sh"}\n']
        replies = self.raw(b"".join(bad) + protocol.request_line("state"))
        self.assertEqual(replies[:-1], [{"ok": False, "error": "invalid_request"}] * len(bad))
        self.assertEqual((replies[-1]["state"], replies[-1]["medium"]), ("listing", "ready"))
        self.assertEqual(self.reboots, [])
        # A line longer than the limit loses framing: one error, then the connection closes.
        replies = self.raw(b'{"action": "state", "pad": "' + b"x" * 5000 + b'"}\n' + protocol.request_line("state"))
        self.assertEqual(replies, [{"ok": False, "error": "invalid_request"}])
        self.assertEqual(base.file_sha(self.target_path), self.before)

    def test_install_over_socket_and_reboot(self):
        cli = self.start()
        listing = cli.request("list")
        reasons = {d["name"]: d["reasons"] for d in listing["disks"]}
        self.assertEqual(reasons, {"sdb": ["install_medium"], "sdy": ["removable"], "sdz": []})
        self.assertEqual([d["name"] for d in listing["disks"] if d["token"]], ["sdz"])
        chosen = self.select_target()
        self.assertEqual((chosen["disk"]["model"], chosen["disk"]["serial"]), ("Task Disk", "TASK-0001"))
        self.assertEqual(cli.request("confirm", token="wrong-token"), {"ok": False, "error": "bad_confirmation"})
        self.assertEqual(cli.request("confirm", token=chosen["confirm_token"]), {"ok": True, "state": "installing"})
        state = self.finish()
        self.assertEqual(state["result"], {"outcome": "succeeded", "stage": "done", "code": "ok",
                                           "disk_state": "installed", "detail": ""})
        self.assertEqual(state["progress"]["stage"], "done")
        self.assertEqual(cli.request("list"), {"ok": False, "error": "busy"})
        self.assertEqual(cli.request("reboot"), {"ok": True})
        self.assertEqual(self.reboots, ["reboot"])
        self.assertNotEqual(base.file_sha(self.target_path), self.before)

    def test_disk_changed_between_select_and_confirm(self):
        cli = self.start()
        chosen = self.select_target()
        (self.sysfs / "block/sdz/serial").write_text("SWAPPED\n")
        self.assertEqual(cli.request("confirm", token=chosen["confirm_token"]), {"ok": False, "error": "disk_changed"})
        state = cli.request("state")
        self.assertEqual((state["state"], state["notice"]), ("listing", "disk_changed"))
        self.assertEqual(base.file_sha(self.target_path), self.before)

    def test_corrupt_payload_is_never_reported_as_success(self):
        cli = self.start(corrupt=True)
        chosen = self.select_target()
        cli.request("confirm", token=chosen["confirm_token"])
        state = self.finish()
        self.assertEqual((state["state"], state["result"]["outcome"], state["result"]["stage"],
                          state["result"]["code"], state["result"]["disk_state"]),
                         ("failed", "failed", "verify", "payload_hash_mismatch", "untouched"))
        self.assertEqual(base.file_sha(self.target_path), self.before)
        self.assertTrue(cli.request("list")["ok"])            # may choose again after a failure
        self.assertEqual(cli.request("state")["result"], None)

    def test_medium_unavailable_serves_only_state_and_reboot(self):
        cli = self.start(prepare_error=medium.MediumError("medium_unavailable"))
        state = cli.request("state")
        self.assertEqual((state["medium"], state["state"]), ("medium_unavailable", "starting"))
        for action in ("list", "back", "cancel"):
            self.assertEqual(cli.request(action), {"ok": False, "error": "medium_unavailable"})
        self.assertEqual(cli.request("reboot"), {"ok": True})
        for error, code in ((base.manifest.ManifestError("manifest_mismatch"), "manifest_mismatch"),
                            (RuntimeError("unexpected"), "medium_unavailable")):
            other = backend.Backend(lambda e=error: (_ for _ in ()).throw(e), lambda: None)
            other.prepare()
            self.assertEqual(other.snapshot()["medium"], code)
        searching = backend.Backend(lambda: None, lambda: None)
        self.assertEqual(searching.handle({"action": "list"}), {"ok": False, "error": "medium_not_ready"})


class CancelTests(BackendFixture):
    def test_cancel_in_each_phase(self):
        expected = {"verify": "untouched", "write": "partially_written", "readback": "partially_written"}
        for stage, disk_state in expected.items():
            with self.subTest(stage=stage):
                cli = self.start(install_wrapper=self.gated(stage))
                self.assertEqual(cli.request("cancel"), {"ok": False, "error": "not_installing"})
                chosen = self.select_target()
                self.assertEqual(cli.request("cancel"), {"ok": True, "state": "listing"})   # confirming → back
                self.assertEqual(cli.request("confirm", token=chosen["confirm_token"]),
                                 {"ok": False, "error": "not_confirming"})
                chosen = self.select_target()
                cli.request("confirm", token=chosen["confirm_token"])
                self.assertTrue(self.reached.wait(20))
                self.assertEqual(cli.request("reboot"), {"ok": False, "error": "busy"})
                self.assertEqual(cli.request("cancel"), {"ok": True, "state": "installing"})
                self.release.set()
                state = self.finish()
                self.assertEqual((state["state"], state["result"]["outcome"], state["result"]["disk_state"]),
                                 ("cancelled", "cancelled", disk_state))
                if disk_state == "untouched":
                    self.assertEqual(base.file_sha(self.target_path), self.before)
                else:
                    self.assert_no_table(self.target_path)
                self.assertEqual(self.reboots, [])
                self.doCleanups()

    def test_cancel_at_every_write_point_is_cancelled_or_refused(self):
        """Class B end to end: inject a real backend 'cancel' before each disk write.

        Before the GPT commit the reply is ok and the result is cancelled with no
        partition table; from the first GPT write on the reply is 'committing' and
        the result is the commit's. An accepted cancel never ends 'succeeded'."""
        def run_with(inject_at):
            counter = {"writes": 0, "before_gpt": None}
            replies = []
            real_write, real_build = writer._pwrite_all, writer.gpt.build

            def write(*args):
                counter["writes"] += 1
                if counter["writes"] == inject_at:
                    replies.append(self.backend.handle({"action": "cancel"}))
                return real_write(*args)

            def build(*args):
                if counter["before_gpt"] is None:
                    counter["before_gpt"] = counter["writes"]
                return real_build(*args)
            cli = self.start()
            chosen = self.select_target()
            with mock.patch.object(writer, "_pwrite_all", write), mock.patch.object(writer.gpt, "build", build):
                self.assertEqual(cli.request("confirm", token=chosen["confirm_token"]), {"ok": True, "state": "installing"})
                state = self.finish()
            return counter, replies, state

        counter, replies, state = run_with(None)
        self.doCleanups()
        self.assertEqual((replies, state["result"]["outcome"]), ([], "succeeded"))
        total, before_gpt = counter["writes"], counter["before_gpt"]
        self.assertGreater(total, before_gpt)
        for n in range(1, total + 1):
            with self.subTest(write=n, before_gpt=before_gpt):
                _, replies, state = run_with(n)
                result = state["result"]
                if n <= before_gpt:
                    self.assertEqual(replies, [{"ok": True, "state": "installing"}])
                    self.assertEqual((state["state"], result["outcome"], result["disk_state"]),
                                     ("cancelled", "cancelled", "partially_written"))
                    self.assert_no_table(self.target_path)
                else:
                    self.assertEqual(replies, [{"ok": False, "error": "committing"}])
                    self.assertEqual((state["state"], result["outcome"]), ("succeeded", "succeeded"))
                    fd = os.open(self.target_path, os.O_RDONLY)
                    try:
                        base.gpt.read(base.gpt.file_reader(fd), os.path.getsize(self.target_path))
                    finally:
                        os.close(fd)
                self.doCleanups()

    def test_cancel_racing_into_the_boundary_wins_or_loses_whole(self):
        """Class B: a cancel that takes the gate just before enter_commit stops the write
        (no GPT); one that arrives just after it is refused and the commit decides."""
        for name, first in (("cancel-first", True), ("commit-first", False)):
            with self.subTest(order=name):
                replies = []
                real_enter = writer.CancelGate.enter_commit

                def enter(gate):
                    if first:
                        replies.append(self.backend.handle({"action": "cancel"}))
                        return real_enter(gate)
                    entered = real_enter(gate)
                    replies.append(self.backend.handle({"action": "cancel"}))
                    return entered
                cli = self.start()
                chosen = self.select_target()
                with mock.patch.object(writer.CancelGate, "enter_commit", enter):
                    cli.request("confirm", token=chosen["confirm_token"])
                    state = self.finish()
                if first:
                    self.assertEqual(replies, [{"ok": True, "state": "installing"}])
                    self.assertEqual((state["state"], state["result"]["stage"]), ("cancelled", "readback"))
                    self.assert_no_table(self.target_path)
                else:
                    self.assertEqual(replies, [{"ok": False, "error": "committing"}])
                    self.assertEqual(state["state"], "succeeded")
                self.doCleanups()

    def test_cancel_after_success_is_refused(self):
        cli = self.start()
        chosen = self.select_target()
        cli.request("confirm", token=chosen["confirm_token"])
        state = self.finish()
        self.assertEqual(state["state"], "succeeded")
        self.assertEqual(cli.request("cancel"), {"ok": False, "error": "not_installing"})
        self.assertEqual(cli.request("state")["result"]["outcome"], "succeeded")


class HotplugTests(BackendFixture):
    def test_swap_after_confirmation_is_never_written(self):
        """Class A end to end: the confirmed disk is replaced (or changes) while the payload
        is being verified; the writer must refuse before its first write."""
        def write(rel, text):
            return lambda: (self.sysfs / "block/sdz" / rel).write_text(text)

        def holder():
            (self.sysfs / "block/sdz/holders/dm-0").mkdir()
        rows = {
            "serial-a-to-serial-b": write("serial", "SERIAL-B\n"),
            "new-diskseq-same-serial": write("diskseq", "424242\n"),
            "wwid-changed": write("wwid", "eui.other\n"),
            "now-read-only": write("ro", "1\n"),
            "now-mounted": lambda: self.mountinfo.write_text("1 0 8:240 / /mnt rw - ext4 /dev/sdz rw\n"),
            "now-held": holder,
            "gone": lambda: shutil.rmtree(self.sysfs / "block/sdz"),
        }
        for name, change in rows.items():
            with self.subTest(change=name):
                cli = self.start(install_wrapper=self.gated("verify"))
                chosen = self.select_target()
                self.assertEqual(cli.request("confirm", token=chosen["confirm_token"]),
                                 {"ok": True, "state": "installing"})
                self.assertTrue(self.reached.wait(20))
                change()
                self.release.set()
                state = self.finish()
                self.assertEqual((state["state"], state["result"]["outcome"], state["result"]["stage"],
                                  state["result"]["code"], state["result"]["disk_state"]),
                                 ("failed", "failed", "preflight", "target_changed", "untouched"))
                self.assertEqual(base.file_sha(self.target_path), self.before)
                self.doCleanups()


class ScriptedTerminal:
    def __init__(self, lines):
        self.lines, self.output = list(lines), []

    def write(self, text):
        self.output.append(text)

    def read_line(self, prompt):
        self.output.append(prompt)
        return self.lines.pop(0) if self.lines else None

    def poll_line(self, timeout):
        time.sleep(min(timeout, 0.01))
        return None

    @property
    def text(self):
        return "".join(self.output)


class TextFrontendTests(BackendFixture):
    def test_install_then_remove_media_and_reboot(self):
        cli = self.start()
        term = ScriptedTerminal(["1", "ERASE", ""])
        self.assertEqual(textui.TextUI(cli, term, interval=0.01).run(), 0)
        self.assertIn("sdb  USB Stick", term.text)
        self.assertIn("[not available: This is the installation medium.]", term.text)
        self.assertIn("Serial: TASK-0001", term.text)
        self.assertIn(messages.STATUS["erase_warning"][1], term.text)
        self.assertIn(messages.RESULTS["ok"][1], term.text)
        self.assertIn(messages.STATUS["remove_media"][1], term.text)
        self.assertEqual(self.reboots, ["reboot"])
        self.assertEqual(self.backend.session.state, session.SUCCEEDED)

    def test_enter_alone_cancels_and_nothing_is_written(self):
        cli = self.start()
        for answer in ("", "erase", "yes", " ERAS"):
            with self.subTest(answer=answer):
                term = ScriptedTerminal(["1", answer, "reboot"])
                self.assertEqual(textui.TextUI(cli, term, interval=0.01).run(), 0)
                self.assertIn("Cancelled. Nothing was written.", term.text)
                self.assertEqual(base.file_sha(self.target_path), self.before)
        self.assertEqual(self.reboots, ["reboot"] * 4)

    def test_failure_is_reported_with_disk_state(self):
        cli = self.start(corrupt=True)
        term = ScriptedTerminal(["1", "ERASE", "reboot"])
        self.assertEqual(textui.TextUI(cli, term, interval=0.01).run(), 0)
        self.assertIn(messages.RESULTS["payload_hash_mismatch"][1], term.text)
        self.assertIn(messages.DISK_STATE["untouched"][1], term.text)
        self.assertNotIn(messages.RESULTS["ok"][1], term.text)

    def test_cancel_refused_while_committing_is_said(self):
        """Class B, text frontend: 'c' during the partition table write is answered with the
        too-late message, never 'Cancelling...', and the real (successful) result follows."""
        reached, release = threading.Event(), threading.Event()
        real_build = writer.gpt.build

        def build(*args):
            reached.set()
            release.wait(20)
            return real_build(*args)

        class Term(ScriptedTerminal):
            typed = False

            def poll_line(self, timeout):
                time.sleep(0.01)
                if reached.is_set() and not self.typed:
                    self.typed = True
                    return "c"
                if self.typed:
                    release.set()
                return None
        cli = self.start()
        term = Term(["1", "ERASE", ""])
        with mock.patch.object(writer.gpt, "build", build):
            self.assertEqual(textui.TextUI(cli, term, interval=0.01).run(), 0)
        self.assertIn(messages.STATUS["cancel_too_late"][1], term.text)
        self.assertNotIn(messages.STATUS["cancelling"][1], term.text)
        self.assertIn(messages.RESULTS["ok"][1], term.text)
        self.assertEqual(self.backend.session.state, session.SUCCEEDED)

    def test_backend_death_after_confirm_is_unknown_and_not_retried(self):
        """Class C, text frontend: the backend dies after 'confirm' is sent and before it
        answers (it may already be writing). The screen says the result is unknown and
        never reconnects to guess."""
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        path = self.root / "dying.sock"
        listener.bind(str(path))
        listener.listen(4)
        disk = {"name": "sdz", "model": "Task Disk", "vendor": "", "serial": "TASK-0001",
                "size_bytes": 64 << 30, "removable": False, "read_only": False}
        replies = {"state": {"ok": True, "medium": "ready", "state": "listing", "notice": None,
                             "progress": {"stage": None, "done": 0, "total": 0}, "result": None,
                             "rebooting": False},
                   "list": {"ok": True, "disks": [dict(disk, token="t1", reasons=[])]},
                   "select": {"ok": True, "confirm_token": "c1", "disk": disk}}
        seen = {"connections": 0, "actions": []}

        def serve_until_confirm():
            while True:
                try:
                    conn, _ = listener.accept()
                except OSError:
                    return
                seen["connections"] += 1
                with conn, conn.makefile("rb") as reader:
                    for line in reader:
                        action = json.loads(line)["action"]
                        seen["actions"].append(action)
                        if action == "confirm":
                            break             # dies without answering
                        conn.sendall(protocol.encode(replies[action]))
        threading.Thread(target=serve_until_confirm, daemon=True).start()
        term = ScriptedTerminal(["1", "ERASE", ""])
        self.assertEqual(textui.TextUI(client.Client(path, connect_timeout=2), term).run(), 1)
        listener.close()
        self.assertIn(messages.RESULTS["service_lost"][1], term.text)
        self.assertNotIn(messages.RESULTS["ok"][1], term.text)
        self.assertEqual(seen["actions"], ["state", "list", "select", "confirm"])
        self.assertEqual(seen["connections"], 1)

    def test_lost_backend_reports_unknown_result(self):
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        path = self.root / "dead.sock"
        listener.bind(str(path))
        listener.listen(1)

        def accept_and_close():
            conn, _ = listener.accept()
            conn.close()
        threading.Thread(target=accept_and_close, daemon=True).start()
        term = ScriptedTerminal([""])
        self.assertEqual(textui.TextUI(client.Client(path, connect_timeout=2), term).run(), 1)
        self.assertIn(messages.RESULTS["service_lost"][1], term.text)
        listener.close()


class MediumTests(base.Fixture):
    def layout(self):
        dev = self.path("dev")
        (dev / "disk/by-label").mkdir(parents=True)
        node = dev / "sdb"
        node.write_bytes(b"iso")
        (dev / "disk/by-label" / LABEL).symlink_to("../../sdb")
        return dev, self.path("mnt")

    def runner_creating(self, mount_point, *, code=0, link=False):
        calls = []

        def run(argv, **kwargs):
            calls.append(argv)
            if code == 0:
                payload = mount_point / "ditto/payload"
                if link:
                    (mount_point / "ditto").mkdir(parents=True)
                    payload.symlink_to(self.root)
                else:
                    payload.mkdir(parents=True)
            return subprocess.CompletedProcess(argv, code, b"", b"")
        return run, calls

    def test_found_mounted_and_excluded(self):
        dev, mnt = self.layout()
        run, calls = self.runner_creating(mnt)
        found = medium.find_medium(LABEL, by_label=dev / "disk/by-label", dev_root=dev, mount_point=mnt,
                                   runner=run, timeout=1, allow_regular_device=True)
        self.assertEqual(calls, [["mount", "-t", "iso9660", "-o", "ro,nosuid,nodev,noexec", str(dev / "sdb"),
                                  str(mnt)]])
        self.assertEqual(found.payload_dir, mnt / "ditto/payload")
        st = os.stat(mnt)
        self.assertEqual(found.devnums, frozenset({f"{os.major(st.st_dev)}:{os.minor(st.st_dev)}"}))

    def test_refusals(self):
        dev, mnt = self.layout()
        ticks = iter(range(1000))
        cases = {
            "bad-label": dict(label="ditto_install", runner=self.runner_creating(mnt)[0]),
            "absent": dict(label="DITTO_OTHER", runner=self.runner_creating(mnt)[0], clock=lambda: next(ticks),
                           sleep=lambda _: None),
            "mount-fails": dict(runner=self.runner_creating(mnt, code=32)[0]),
            "payload-link": dict(runner=self.runner_creating(mnt, link=True)[0]),
            "not-block": dict(runner=self.runner_creating(mnt)[0], allow_regular_device=False),
        }
        for name, kwargs in cases.items():
            with self.subTest(case=name):
                shutil.rmtree(mnt, ignore_errors=True)
                kwargs = {"label": LABEL, "allow_regular_device": True, **kwargs}
                with self.assertRaises(medium.MediumError) as caught:
                    medium.find_medium(kwargs.pop("label"), by_label=dev / "disk/by-label", dev_root=dev,
                                       mount_point=mnt, timeout=5, **kwargs)
                self.assertEqual(caught.exception.code, "medium_unavailable")
        outside = self.path("outside-node")
        outside.write_bytes(b"x")
        (dev / "disk/by-label/DITTO_ESCAPE").symlink_to(outside)
        with self.assertRaises(medium.MediumError):
            medium.find_medium("DITTO_ESCAPE", by_label=dev / "disk/by-label", dev_root=dev, mount_point=mnt,
                               runner=self.runner_creating(mnt)[0], timeout=1, allow_regular_device=True)


class ImageFileTests(unittest.TestCase):
    IMAGE = HERE.parent / "image"

    def unit(self, name):
        parser = configparser.ConfigParser(strict=False, interpolation=None)
        parser.optionxform = str
        parser.read(self.IMAGE / "units" / name)
        return parser

    def test_units_users_and_launchers(self):
        back = self.unit("ditto-installer-backend.service")
        self.assertNotIn("User", back["Service"])
        self.assertEqual(back["Service"]["ExecStart"], "/usr/lib/ditto-installer/ditto-installer-backend")
        self.assertEqual(back["Service"]["Restart"], "no")
        self.assertEqual(back["Service"]["RuntimeDirectory"], "ditto-installer")
        ui = self.unit("ditto-installer-ui.service")
        self.assertEqual((ui["Service"]["User"], ui["Service"]["TTYPath"], ui["Service"]["StandardInput"],
                          ui["Service"]["PAMName"]), ("ditto-installer", "/dev/tty1", "tty-fail", "ditto-installer"))
        self.assertIn("getty@tty1.service", ui["Unit"]["Conflicts"])
        self.assertIn("ditto-installer-backend.service", ui["Unit"]["Requires"])
        self.assertEqual(ui["Service"]["ExecStart"], "/usr/lib/ditto-installer/ditto-installer-ui")
        self.assertEqual(ui["Service"]["ExecStartPre"], "-/usr/lib/ditto-installer/wait-drm")
        self.assertEqual(ui["Service"]["CapabilityBoundingSet"], "")
        self.assertFalse((self.IMAGE / "units/ditto-installer-text.service").exists())
        pam = [line.split() for line in (self.IMAGE / "pam.d/ditto-installer").read_text().splitlines()
               if line and not line.startswith("#")]
        self.assertEqual([row[0] for row in pam], ["account", "session", "session"])
        self.assertFalse(any(row[0] == "auth" or "pam_unix.so" in row for row in pam))
        self.assertIn("pam_systemd.so", pam[-1])
        ini = configparser.ConfigParser(interpolation=None)
        ini.read(self.IMAGE / "wayfire-installer.ini")
        self.assertEqual(ini["autostart"]["installer"], "/usr/lib/ditto-installer/ditto-installer-ui --session")
        self.assertEqual(ini["core"]["xwayland"], "false")
        sysusers = (self.IMAGE / "sysusers.d/ditto-installer.conf").read_text().split("\n")
        rows = [line.split() for line in sysusers if line and not line.startswith("#")]
        self.assertEqual(rows[0][:3], ["u", "ditto-installer", "-"])
        self.assertEqual(rows[0][-1], "/usr/sbin/nologin")
        for name, module in (("ditto-installer-backend", "service"), ("ditto-installer-text", "textui")):
            path = self.IMAGE / name
            self.assertTrue(os.access(path, os.X_OK))
            text = path.read_text()
            self.assertTrue(text.startswith("#!/usr/bin/python3 -I\n"))
            self.assertIn(f"from ditto_installer.{module} import main", text)
            self.assertIn('sys.path.insert(0, "/usr/lib/ditto-installer")', text)

    def test_config_parser(self):
        good = {"schema": 1, "manifest_sha256": "a" * 64, "medium_label": LABEL, "payload_dir": "ditto/payload",
                "frontend_user": "ditto-installer"}
        self.assertEqual(service.parse_config(json.dumps(good)), good)
        for change in ({"schema": True}, {"manifest_sha256": "A" * 64}, {"medium_label": "ditto"},
                       {"payload_dir": "/"}, {"frontend_user": "root"}, {"extra": 1}):
            with self.subTest(change=change), self.assertRaises(service.ConfigError):
                service.parse_config(json.dumps(good | change))
        with self.assertRaises(service.ConfigError):
            service.parse_config("{")


if __name__ == "__main__":
    unittest.main()

"""TEST ONLY temp-dir logic evidence. No network, OS stress or provider calls.

Fakes model file/systemd readbacks exclusively in TemporaryDirectory. Their
receipts are labelled TEST_ONLY and must never be used as physical evidence.
"""
import hashlib
from contextlib import closing
import importlib.util
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import tempfile
import unittest
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1] / "g3_ops.py"
spec = importlib.util.spec_from_file_location("g3_ops", MODULE)
ops = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ops)
REPO = MODULE.parents[2]
REAL_WITNESS = ops.witness


def database(path, version=4):
    path.parent.mkdir(parents=True, exist_ok=True)
    with closing(sqlite3.connect(path)) as db, db:
        db.execute(f"PRAGMA user_version={version}")
        db.execute("CREATE TABLE agent_preferences (singleton INTEGER, settings_json TEXT)")
        db.execute("CREATE TABLE agent_turns (state TEXT)")
        db.execute("CREATE TABLE jobs (state TEXT)")
        db.execute("INSERT INTO agent_preferences VALUES (1,?)", (json.dumps({"provider": "codex-app-server", "auth": None}),))


class TestOnlyHost:
    def __init__(self, root, before):
        self.root, self.before = root, before
        self.events = []
        self.runner = "inactive"
        self.fail_at = None

    def event(self, name):
        self.events.append(name)
        if self.fail_at == name:
            raise ops.Refused("TEST_ONLY injected failure")

    def restore_private(self, state):
        self.event("private")

    def needs_relogin(self):
        return True

    def remove_override(self):
        self.event("remove")
        (self.root / "override").unlink(missing_ok=True)
        return True

    def relogin(self):
        self.event("relogin")
        assert not (self.root / "override").exists()

    def restore_gdm(self):
        self.event("gdm")

    def normal(self):
        self.event("readback")
        return self.before

    def system(self, *args, check=True):
        self.event(args[0])
        if args[0] == "start":
            self.runner = "active"
        return self.runner

    def workers(self):
        return []

    def resume_listener(self, state):
        self.event("resume_listener")

    def command(self, args, **kw):
        self.event("command")
        return subprocess.CompletedProcess(args, 1, "", "")


class Boundaries(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="TEST_ONLY_g3_ops_")
        self.addCleanup(self.temp.cleanup)
        self.origin_witness = patch.object(ops, "witness", return_value=None)
        self.origin_witness.start()
        self.addCleanup(self.origin_witness.stop)
        self.root = Path(self.temp.name)
        self.candidate = self.root / "candidate"
        self.store = self.root / "private"
        self.normal = self.root / "normal/core.db"
        database(self.normal)
        self.installed = self.root / "installed"
        # Exact known production template bytes are sanitized and contain no
        # credential values. Re-root them only for TEST ONLY file logic.
        pinned = (MODULE.parent / "tests/verification-relay.txt").read_text()
        self.assertEqual(hashlib.sha256(pinned.encode()).hexdigest(), ops.TEMPLATE_SHA)
        self.text = pinned.replace(str(ops.INSTALLED), str(self.installed))
        self.pin = hashlib.sha256(self.text.encode()).hexdigest()

    def rewrite(self, binaries=None, text=None, **kw):
        return ops.rewrite_template(text if text is not None else self.text, self.candidate,
                                    binaries or self.candidate / "target/release", self.store,
                                    template_sha=self.pin, installed=self.installed, normal=self.normal, **kw)

    def test_full_template_rewrites_every_installed_path(self):
        result = self.rewrite()
        self.assertNotIn(str(self.installed) + "/", result)
        self.assertIn(str(self.candidate / "target/release/ditto-core"), result)
        self.assertIn(str(self.candidate / "target/ditto-packages-verification"), result)
        self.assertIn(str(self.candidate / "shell/shell.qml"), result)
        self.assertIn(str(self.candidate / "tests/g1/lib/relay.mjs"), result)
        self.assertIn("Environment=DITTO_DATA_DIR=" + str(self.store), result)

    def test_all_fault_binary_paths(self):
        for mode in ops.MODES[1:]:
            with self.subTest(mode=mode):
                binaries = self.root / "contexts" / mode
                result = self.rewrite(binaries)
                self.assertIn(str(binaries / "ditto-core"), result)
                self.assertNotIn(str(self.candidate / "target/release/ditto-core"), result)

    def test_protocols_and_codex_pin_unchanged(self):
        before = next(x for x in self.text.splitlines() if "--agent-backend" in x)
        self.assertIn(before, self.rewrite())
        for version in ("quickshell 0.3.1", "hostd 0.2.0", "agent 0.3.0", "dittoctl 0.2.0"):
            self.assertIn(version, self.rewrite())

    def test_unknown_template_hash_refused(self):
        with self.assertRaisesRegex(ops.Refused, "hash"):
            self.rewrite(text=self.text + "# changed\n")

    def test_unknown_template_root_refused(self):
        changed = self.text.replace(str(self.installed), "/unknown")
        with self.assertRaisesRegex(ops.Refused, "root"):
            ops.rewrite_template(changed, self.candidate, self.candidate / "target/release", self.store,
                                 template_sha=hashlib.sha256(changed.encode()).hexdigest(), installed=self.installed)

    def test_arbitrary_binary_refused(self):
        with self.assertRaisesRegex(ops.Refused, "binaries"):
            self.rewrite(self.root / "arbitrary")

    def test_normal_store_override_refused(self):
        self.store = self.normal.parent
        with self.assertRaisesRegex(ops.Refused, "normal-store"):
            self.rewrite()

    def test_normal_store_symlink_refused(self):
        self.store.symlink_to(self.normal.parent, target_is_directory=True)
        with self.assertRaisesRegex(ops.Refused, "normal-store"):
            self.rewrite()

    def test_canonical_copy_retains_guards_tests_and_order(self):
        original = (REPO / "tests/g3/reference/seat.sh").read_text()
        changed = ops.adapt_seat(original, self.candidate, self.root / "ops/g3_ops.py", "123456789")
        script = self.root / "seat-copy.sh"
        script.write_text(changed)
        subprocess.run(["bash", "-n", str(script)], check=True)
        self.assertIn('pgrep -f', changed)
        self.assertIn('timeout 900s node tests/g3/reference/driver.mjs', changed)
        self.assertIn('tests/g3/host/driver.py', changed)
        self.assertIn('tests/g3/native-failures/driver.py', changed)
        self.assertNotIn('systemctl --user start github-actions', changed)
        restore = changed[changed.index("restore() {"):changed.index('started="$(date')]
        self.assertLess(restore.index(" leave --id "), restore.index('rm -f "$dropin"'))
        self.assertLess(restore.index('rm -f "$dropin"'), restore.index("ditto-relogin"))
        self.assertIn(f'cd "{self.candidate}"', changed)
        self.assertEqual(changed.count(" override --id "), 1)

    def test_modified_canonical_refused(self):
        with self.assertRaises(ops.Refused):
            ops.adapt_seat("#!/bin/bash\n", self.candidate, MODULE, "123456789")

    def test_origin_worker_waits_exact_witness(self):
        origin = {"pid": 21, "starttime": "900", "worker": True}
        with patch.object(ops, "witness", return_value=origin):
            self.assertFalse(ops.worker_gate(origin, [origin]))
        with patch.object(ops, "witness", return_value=None):
            self.assertTrue(ops.worker_gate(origin, []))

    def test_different_worker_refused(self):
        with patch.object(ops, "witness", return_value=None), self.assertRaisesRegex(ops.Refused, "other active"):
            ops.worker_gate({"pid": 21, "starttime": "900"}, [{"pid": 22, "starttime": "900"}])

    def test_pid_reuse_refused(self):
        with patch.object(ops, "witness", return_value=None), self.assertRaisesRegex(ops.Refused, "PID reuse"):
            ops.worker_gate({"pid": 21, "starttime": "900"}, [{"pid": 21, "starttime": "901"}])

    def pause_fixture(self, workers):
        host = ops.Host(self.root)
        state = {"test_only": True, "origin": {"pid": 21, "starttime": "900"}}
        events = []
        def system(*args, **kw):
            events.append(args[0])
            return "/user.slice/user-1000.slice/user@1000.service/app.slice/TEST_ONLY" if args[0] == "show" else "inactive"
        host.system = system
        host.workers = lambda: workers
        host.listener_signal = lambda saved, signum: events.append(signum)
        host.freeze_listener = lambda saved: events.append(signal.SIGSTOP)
        return host, state, events

    def test_listener_freeze_closes_pause_race(self):
        host, state, events = self.pause_fixture([])
        with patch.object(ops.Path, "read_text", return_value="111"), patch.object(ops.Path, "resolve", return_value=Path("/home/neil/actions-runner-ditto-ref/bin/Runner.Listener")), patch.object(ops, "witness", side_effect=lambda pid: {"pid": 111, "starttime": "55", "worker": False} if int(pid) == 111 else None):
            host.pause_runner(state)
        self.assertEqual(events, ["show", signal.SIGSTOP, "--no-block", "is-active", signal.SIGCONT])
        self.assertEqual(ops.read(self.root / "state.json")["listener"]["pid"], 111)

    def test_worker_arrives_during_pause_refuses_stop_and_resumes_listener(self):
        host, state, events = self.pause_fixture([{"pid": 99, "starttime": "666"}])
        with patch.object(ops.Path, "read_text", return_value="111"), patch.object(ops.Path, "resolve", return_value=Path("/home/neil/actions-runner-ditto-ref/bin/Runner.Listener")), patch.object(ops, "witness", side_effect=lambda pid: {"pid": 111, "starttime": "55", "worker": False} if int(pid) == 111 else None):
            with self.assertRaises(ops.Refused):
                host.pause_runner(state)
        self.assertNotIn("--no-block", events)
        self.assertEqual(events[-1], signal.SIGCONT)

    def test_unknown_listener_refused(self):
        host, state, events = self.pause_fixture([])
        with patch.object(ops.Path, "read_text", return_value="111"), patch.object(ops.Path, "resolve", return_value=Path("/unknown/bin/Runner.Listener")):
            with self.assertRaisesRegex(ops.Refused, "known runner Listener"):
                host.pause_runner(state)
        self.assertEqual(events, ["show"])

    def test_listener_pid_reuse_never_signalled(self):
        host = ops.Host(self.root)
        with patch.object(ops, "witness", return_value={"pid": 111, "starttime": "56", "worker": False}), patch.object(ops.os, "pidfd_open") as pidfd:
            with self.assertRaisesRegex(ops.Refused, "PID reused"):
                host.listener_signal({"pid": 111, "starttime": "55"}, signal.SIGCONT)
            pidfd.assert_not_called()

    def test_listener_freeze_requires_actual_stopped_readback(self):
        host = ops.Host(self.root)
        with patch.object(host, "listener_signal") as send, patch.object(ops.Path, "read_text", side_effect=["State:\tR (running)\n", "State:\tT (stopped)\n"]), patch.object(ops.time, "sleep") as wait:
            host.freeze_listener({"pid": 111, "starttime": "55"})
            send.assert_called_once_with({"pid": 111, "starttime": "55"}, signal.SIGSTOP)
            wait.assert_called_once()

    def test_stat_comm_parentheses_witness(self):
        proc = self.root / "proc/21"
        proc.mkdir(parents=True)
        proc.joinpath("stat").write_text("21 (weird ) name) " + " ".join(["0"] * 19 + ["777", "0"]))
        proc.joinpath("cmdline").write_bytes(b"/task/bin/Runner.Worker\0spawnclient\0")
        self.assertEqual(REAL_WITNESS(21, self.root / "proc"), {"pid": 21, "starttime": "777", "worker": True})

    def selection(self):
        self.home = self.root / "home"
        root = self.home / "funlab/Ditto/artifacts/g3/private-test"
        database(root / "data/core.db")
        return {"source": ops.SOURCE, "stores": [{"root": str(root), "codex_home": str(root / "state/agent/backend/codex"),
                "existing_subscription_proved": True, "test_content_only": True, "database_sha256": ops.sha(root / "data/core.db")}]}

    def test_single_proved_private_store_original_path(self):
        selection = self.selection()
        root = ops.select_store(selection, self.normal, self.home)
        self.assertEqual(str(root), selection["stores"][0]["root"])
        self.assertEqual(ops.schema(root / "data/core.db"), 4)

    def test_absent_private_store_refused(self):
        with self.assertRaisesRegex(ops.Refused, "absent or multiple"):
            ops.select_store({"source": ops.SOURCE, "stores": []}, self.normal)

    def test_multiple_private_stores_refused(self):
        selection = self.selection()
        selection["stores"] *= 2
        with self.assertRaisesRegex(ops.Refused, "absent or multiple"):
            ops.select_store(selection, self.normal, self.home)

    def test_auth_ref_null_does_not_infer_authentication(self):
        selection = self.selection()
        selection["stores"][0]["existing_subscription_proved"] = False
        with self.assertRaisesRegex(ops.Refused, "METADATA"):
            ops.select_store(selection, self.normal, self.home)

    def test_copied_codex_home_refused(self):
        selection = self.selection()
        selection["stores"][0]["codex_home"] = str(self.root / "different/codex")
        with self.assertRaisesRegex(ops.Refused, "CODEX_HOME"):
            ops.select_store(selection, self.normal, self.home)

    def test_stale_store_receipt_refused(self):
        selection = self.selection()
        selection["stores"][0]["database_sha256"] = "0" * 64
        with self.assertRaisesRegex(ops.Refused, "stale"):
            ops.select_store(selection, self.normal, self.home)

    def test_outstanding_private_turn_refused_without_model_call(self):
        selection = self.selection()
        db = Path(selection["stores"][0]["root"]) / "data/core.db"
        with closing(sqlite3.connect(db)) as conn, conn:
            conn.execute("INSERT INTO agent_turns VALUES ('queued')")
        selection["stores"][0]["database_sha256"] = ops.sha(db)
        with self.assertRaisesRegex(ops.Refused, "outstanding turns"):
            ops.select_store(selection, self.normal, self.home)

    def test_outstanding_private_job_refused(self):
        selection = self.selection()
        db = Path(selection["stores"][0]["root"]) / "data/core.db"
        with closing(sqlite3.connect(db)) as conn, conn:
            conn.execute("INSERT INTO jobs VALUES ('running')")
        selection["stores"][0]["database_sha256"] = ops.sha(db)
        with self.assertRaisesRegex(ops.Refused, "outstanding jobs"):
            ops.select_store(selection, self.normal, self.home)

    def test_normal_db_hardlink_refused(self):
        selection = self.selection()
        db = Path(selection["stores"][0]["root"]) / "data/core.db"
        db.unlink()
        os.link(self.normal, db)
        with self.assertRaisesRegex(ops.Refused, "aliased"):
            ops.select_store(selection, self.normal, self.home)

    def test_private_state_symlink_refused(self):
        selection = self.selection()
        root = Path(selection["stores"][0]["root"])
        root.joinpath("state").symlink_to(self.normal.parent, target_is_directory=True)
        with self.assertRaisesRegex(ops.Refused, "state/cache alias"):
            ops.select_store(selection, self.normal, self.home)

    def test_selection_source_mismatch_refused(self):
        selection = self.selection()
        selection["source"] = "0" * 40
        with self.assertRaisesRegex(ops.Refused, "source mismatch"):
            ops.select_store(selection, self.normal, self.home)

    def test_source_receipt_mismatch_refused(self):
        with patch.object(ops.subprocess, "check_output", side_effect=[ops.SOURCE + "\n", b""]):
            with self.assertRaisesRegex(ops.Refused, "receipt mismatch"):
                ops.assert_source(self.candidate, {"source": "0" * 40})

    def test_source_dirty_refused(self):
        with patch.object(ops.subprocess, "check_output", side_effect=[ops.SOURCE + "\n", b"M candidate"]):
            with self.assertRaisesRegex(ops.Refused, "candidate changed"):
                ops.assert_source(self.candidate)

    def recovery_state(self):
        before = {"schema": 4, "exe_sha256": "1" * 64, "profile": {"profile_id": "TEST_ONLY", "sha256": "2" * 64}}
        state = {"test_only": True, "source": ops.SOURCE, "mode": "full", "pause_armed": True, "disruption_armed": True,
                 "normal_before": before, "runner_before": "active", "recovery_complete": False,
                 "origin": {"pid": 21, "starttime": "900"}, "modes": {m: "not_run" for m in ops.MODES}}
        ops.write(self.root / "state.json", state)
        self.root.joinpath("override").write_text("TEST_ONLY")
        return TestOnlyHost(self.root, before), state

    def test_restore_order_and_no_early_ci_restart(self):
        host, state = self.recovery_state()
        result = ops.recover(self.root, host)
        self.assertEqual(result["recovery_status"], "verified")
        self.assertEqual(host.events, ["private", "remove", "relogin", "gdm", "readback", "resume_listener", "start", "is-active"])

    def test_recovery_idempotency(self):
        host, state = self.recovery_state()
        ops.recover(self.root, host)
        first = list(host.events)
        ops.recover(self.root, host)
        self.assertEqual(host.events, first)

    def test_every_recovery_failure_kept_and_later_steps_attempted(self):
        for failure in ("private", "remove", "relogin", "gdm", "readback", "resume_listener", "start"):
            with self.subTest(failure=failure):
                host, state = self.recovery_state()
                host.fail_at = failure
                result = ops.recover(self.root, host)
                self.assertEqual(result["recovery_status"], "needs_human")
                self.assertIn("is-active", host.events)
                first = list(host.events)
                ops.recover(self.root, host)
                self.assertEqual(host.events, first)

    def test_normal_profile_mismatch_detected(self):
        host, state = self.recovery_state()
        host.before = {**host.before, "profile": {"profile_id": "TEST_ONLY_OTHER", "sha256": "3" * 64}}
        self.assertIn("normal_provenance_readback", ops.recover(self.root, host)["recovery_errors"])

    def test_normal_exe_mismatch_detected(self):
        host, state = self.recovery_state()
        host.before = {**host.before, "exe_sha256": "f" * 64}
        self.assertIn("normal_provenance_readback", ops.recover(self.root, host)["recovery_errors"])

    def test_normal_schema_mismatch_detected(self):
        host, state = self.recovery_state()
        host.before = {**host.before, "schema": 5}
        self.assertIn("normal_provenance_readback", ops.recover(self.root, host)["recovery_errors"])

    def test_inactive_original_runner_is_not_started(self):
        host, state = self.recovery_state()
        state["runner_before"] = "inactive"
        ops.write(self.root / "state.json", state)
        ops.recover(self.root, host)
        self.assertNotIn("start", host.events)

    def test_deadline_child_is_terminated_without_os_stress(self):
        script = self.root / "TEST_ONLY_sleep.sh"
        script.write_text("#!/bin/bash\nsleep 10\n")
        with self.assertRaises(subprocess.TimeoutExpired):
            ops.run_seat(script, {"PATH": "/usr/bin:/bin"}, self.root / "TEST_ONLY.log", .05)

    def test_control_failure_always_runs_shared_recovery(self):
        host, state = self.recovery_state()
        with patch.object(ops, "verify_stage", side_effect=ops.Refused("TEST_ONLY early failure")):
            with self.assertRaises(ops.Refused):
                ops.control(self.root, host)
        result = ops.read(self.root / "state.json")
        self.assertEqual(result["failure"], "Refused")
        self.assertEqual(result["recovery_status"], "verified")
        self.assertNotIn("command", host.events)  # no dispatch after failure

    def test_control_signal_runs_shared_recovery(self):
        host, state = self.recovery_state()
        previous = signal.getsignal(signal.SIGTERM)
        def handler(signum, frame):
            raise ops.Refused("TEST_ONLY signal")
        signal.signal(signal.SIGTERM, handler)
        try:
            with patch.object(ops, "verify_stage", side_effect=lambda root: signal.raise_signal(signal.SIGTERM)):
                with self.assertRaises(ops.Refused):
                    ops.control(self.root, host)
        finally:
            signal.signal(signal.SIGTERM, previous)
        self.assertEqual(ops.read(self.root / "state.json")["recovery_status"], "verified")
        self.assertFalse(self.root.joinpath("override").exists())

    def test_deadline_shared_recovery_marks_unfinished_mode_failed(self):
        host, state = self.recovery_state()
        state["modes"]["full"] = "running"
        ops.write(self.root / "state.json", state)
        result = ops.recover(self.root, host)
        self.assertEqual(result["modes"]["full"], "failed")
        self.assertEqual(result["modes"]["faults"], "not_run")
        self.assertEqual(result["failure"], "interrupted_or_deadline")
        self.assertEqual(result["recovery_status"], "verified")
        first = list(host.events)
        ops.recover(self.root, host)
        self.assertEqual(first, host.events)

    def test_private_restore_never_applies_snapshot_to_normal(self):
        host = ops.Host(self.root)
        directory = self.root / "evidence/full"
        directory.mkdir(parents=True)
        ops.write(directory / "private-before.json", {"test_only": True})
        with patch.object(host, "private_live", side_effect=ops.Refused("normal runtime")), patch.object(host, "relay") as rpc:
            with self.assertRaises(ops.Refused):
                host.restore_private({"mode": "full"})
            rpc.assert_not_called()

    def test_private_restore_verified_receipt_is_idempotent(self):
        host = ops.Host(self.root)
        directory = self.root / "evidence/full"
        directory.mkdir(parents=True)
        ops.write(directory / "private-recovery.json", {"test_only": True, "status": "verified"})
        with patch.object(host, "private_live") as live, patch.object(host, "relay") as rpc:
            host.restore_private({"mode": "full"})
            live.assert_not_called()
            rpc.assert_not_called()

    def test_dispatch_refused_before_restore(self):
        host, state = self.recovery_state()
        with self.assertRaisesRegex(ops.Refused, "before verified"):
            ops.dispatch(self.root, host)
        self.assertEqual(host.events, [])

    def test_dispatch_absent_auth_blocked_after_restore(self):
        host, state = self.recovery_state()
        state.update(recovery_complete=True, recovery_status="verified", modes={m: "passed" for m in ops.MODES})
        ops.write(self.root / "state.json", state)
        ops.dispatch(self.root, host)
        self.assertEqual(ops.read(self.root / "state.json")["delivery"], "BLOCKED_AUTO_DELIVERY")
        self.assertEqual(host.events, ["command"])

    def test_dispatch_never_retries_ambiguous_intent(self):
        host, state = self.recovery_state()
        state.update(recovery_complete=True, recovery_status="verified", delivery="dispatch_intent", modes={m: "passed" for m in ops.MODES})
        ops.write(self.root / "state.json", state)
        ops.dispatch(self.root, host)
        self.assertEqual(host.events, [])

    def test_dispatch_exact_pinned_collector_only_after_restore(self):
        host, state = self.recovery_state()
        state.update(recovery_complete=True, recovery_status="verified", modes={m: "passed" for m in ops.MODES})
        ops.write(self.root / "state.json", state)
        ops.write(self.root / "stage.json", {"test_only": True, "ops_sha": "a" * 40})
        calls = []
        def command(argv, **kw):
            calls.append(argv)
            result = json.dumps({"object": {"sha": "a" * 40}}) if argv[1] == "api" else ""
            if argv[1] == "workflow":
                self.assertEqual(ops.read(self.root / "state.json")["delivery"], "dispatch_intent")
            return subprocess.CompletedProcess(argv, 0, result, "")
        host.command = command
        ops.dispatch(self.root, host)
        self.assertEqual(len(calls), 3)
        self.assertEqual(calls[-1][:4], ["gh", "workflow", "run", "nightly-refmachine.yml"])
        self.assertIn("phase=collect", calls[-1])
        self.assertEqual(calls[-1][calls[-1].index("--ref") + 1], ops.BRANCH)
        self.assertEqual(ops.read(self.root / "state.json")["delivery"], "dispatched")
        ops.dispatch(self.root, host)
        self.assertEqual(len(calls), 3)

    def test_changed_ops_branch_refuses_auto_dispatch(self):
        host, state = self.recovery_state()
        state.update(recovery_complete=True, recovery_status="verified", modes={m: "passed" for m in ops.MODES})
        ops.write(self.root / "state.json", state)
        ops.write(self.root / "stage.json", {"test_only": True, "ops_sha": "a" * 40})
        calls = []
        def command(argv, **kw):
            calls.append(argv)
            return subprocess.CompletedProcess(argv, 0, json.dumps({"object": {"sha": "b" * 40}}), "")
        host.command = command
        ops.dispatch(self.root, host)
        self.assertEqual(len(calls), 2)
        self.assertEqual(ops.read(self.root / "state.json")["delivery"], "BLOCKED_AUTO_DELIVERY")

    def publish_state(self):
        host, state = self.recovery_state()
        state.update(recovery_complete=True, recovery_status="verified", modes={m: "not_run" for m in ops.MODES})
        ops.write(self.root / "state.json", state)
        self.root.joinpath("evidence/full").mkdir(parents=True)
        return {"source": ops.SOURCE, "ops_sha": "a" * 40}

    def test_publish_allowlist_does_not_copy_private_values(self):
        stage = self.publish_state()
        ops.write(self.root / "evidence/full/summary.json", {"test_only": True, "account_email": "synthetic-private@example.invalid"})
        self.root.joinpath("evidence/full/core.journal.log").write_text("SECRET_SENTINEL")
        self.root.joinpath("evidence/full/arbitrary.db").write_text("SECRET_SENTINEL")
        with patch.object(ops, "verify_stage", return_value=stage):
            ops.publish(self.root, self.root / "public")
        output = (self.root / "public/receipt.json").read_text()
        self.assertNotIn("synthetic-private", output)
        self.assertNotIn("SECRET_SENTINEL", output)
        self.assertEqual(len(list((self.root / "public").iterdir())), 1)
        self.assertEqual(json.loads(output)["modes"]["full"], "not_run")

    def test_publish_secret_sentinel_refused(self):
        stage = self.publish_state()
        ops.write(self.root / "evidence/full/summary.json", {"test_only": True, "value": "SECRET_SENTINEL"})
        with patch.object(ops, "verify_stage", return_value=stage):
            with self.assertRaisesRegex(ops.Refused, "secret sentinel"):
                ops.publish(self.root, self.root / "public")
        self.assertFalse(self.root.joinpath("public").exists())

    def test_publish_credential_marker_refused(self):
        stage = self.publish_state()
        ops.write(self.root / "evidence/full/summary.json", {"test_only": True, "value": "Bearer synthetic"})
        with patch.object(ops, "verify_stage", return_value=stage):
            with self.assertRaises(ops.Refused):
                ops.publish(self.root, self.root / "public")

    def test_publish_failed_recovery_refused(self):
        stage = self.publish_state()
        state = ops.read(self.root / "state.json")
        state["recovery_status"] = "needs_human"
        ops.write(self.root / "state.json", state)
        with patch.object(ops, "verify_stage", return_value=stage):
            with self.assertRaisesRegex(ops.Refused, "verified recovery"):
                ops.publish(self.root, self.root / "public")

    def test_publish_incomplete_mode_refused(self):
        stage = self.publish_state()
        state = ops.read(self.root / "state.json")
        state["modes"]["full"] = "running"
        ops.write(self.root / "state.json", state)
        with patch.object(ops, "verify_stage", return_value=stage):
            with self.assertRaisesRegex(ops.Refused, "incomplete"):
                ops.publish(self.root, self.root / "public")

    def test_native_source_receipt_mismatch_refused(self):
        directory = self.root / "evidence/full"
        directory.mkdir(parents=True)
        ops.write(self.root / "stage.json", {"test_only": True, "source_facts": {"commit": ops.SOURCE, "dirty": False, "source_tree_sha256": "a" * 64}})
        ops.write(directory / "physical-context.json", {"test_only": True, "source": {"commit": ops.SOURCE, "dirty": False, "source_tree_sha256": "b" * 64}})
        with self.assertRaisesRegex(ops.Refused, "source/receipt mismatch"):
            ops.check_mode(self.root, "full")

    def test_task_id_injection_refused(self):
        for value in ("../normal", "1; rm", "1", "123456\n", "$(id)", "0" * 9):
            with self.subTest(value=value), self.assertRaises(ops.Refused):
                ops.run_root(value)

    def test_workflow_manual_fixed_inputs_and_no_permissions_expansion(self):
        text = (REPO / ".github/workflows/nightly-refmachine.yml").read_text()
        self.assertIn("workflow_dispatch:", text)
        self.assertNotIn("schedule:", text)
        self.assertNotIn("push:", text)
        self.assertIn("contents: read", text)
        self.assertNotIn("write", text)
        self.assertIn("options: [inventory, preflight, stage, auth_prepare, auth_login, auth_status, auth_reason, bridge_probe_prepare, bridge_probe, launch, collect]", text)
        self.assertIn("refs/heads/" + ops.BRANCH, text)
        self.assertIn("persist-credentials: false", text)
        self.assertIn("cancel-in-progress: false", text)
        self.assertNotIn("inputs.source", text)
        self.assertNotIn("inputs.command", text)
        self.assertNotIn("inputs.store", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)

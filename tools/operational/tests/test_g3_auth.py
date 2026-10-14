"""TEST ONLY auth logic. No real provider, keyring credential or message.

Core command/native receipt contracts are source-bound static checks and
mock logic only; no fixture result is admitted by the actual launch gate.
"""
from contextlib import closing, redirect_stdout, redirect_stderr
import io
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import g3_auth as a
import g3_ops as ops
import g3_device_bridge as b

ID, FLOW, CODE = "123456789", "a" * 32, "TEST-1234"


class TestOnlyCore:
    def __init__(self):
        self.calls = []
        self.status_count = 0
        self.login = {"login_id": "TEST_ONLY_LOGIN", "auth_url": "https://auth.openai.com/codex/device", "user_code": CODE, "expires_at_ms": b.now_ms() + 90_000}

    def ready(self):
        return {"test_only": True}

    def call(self, method, params=None, **kw):
        self.calls.append((method, params))
        if method == "agent.providers.status":
            self.status_count += 1
            return {"available": True, "provider": "codex-app-server", "authenticated": self.status_count > 1,
                    "account_label": "TEST_ONLY_ACCOUNT", "models": [{"id": a.MODEL, "reasoning_efforts": [a.EFFORT]}]}
        if method == "agent.providers.login":
            return self.login
        return {"completed": True}


class TestOnlyTransport:
    def __init__(self, fail=False):
        self.fail = fail
        self.paths = []

    def post(self, path, value):
        self.paths.append(path)
        if self.fail:
            raise RuntimeError("TEST ONLY secret exception " + CODE)


class AuthLogic(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="TEST_ONLY_auth_")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name) / "home"
        self.root = Path(self.temp.name) / ("q" + ID)
        self.root.mkdir(mode=0o700)
        self.normal = Path(self.temp.name) / "normal/core.db"
        self.database(self.normal, 4)

    def database(self, path, version):
        path.parent.mkdir(parents=True, exist_ok=True)
        with closing(sqlite3.connect(path)) as db, db:
            db.execute("PRAGMA user_version=" + str(version))
            db.execute("CREATE TABLE TEST_ONLY (value TEXT)")

    def realm(self):
        realm = a.realm_path(ID, self.home)
        realm.mkdir(parents=True, mode=0o700)
        self.database(realm / "data/core.db", 5)
        return realm

    def receipt(self):
        return {"qualification_id": ID, "flow_id": FLOW, "expires_at_ms": b.now_ms() + 180_000, "test_only": True}

    def test_realm_exact_final_path(self):
        self.assertEqual(a.realm_path(ID, self.home), self.home / ".cache/ditto" / ("g3-auth-q" + ID))

    def test_realm_ancestor_symlink_refused(self):
        self.home.joinpath(".cache").mkdir(parents=True)
        destination = Path(self.temp.name) / "elsewhere"
        destination.mkdir()
        self.home.joinpath(".cache/ditto").symlink_to(destination)
        with self.assertRaises(ops.Refused):
            a.realm_path(ID, self.home)

    def test_realm_normal_db_alias_refused(self):
        realm = self.realm()
        db = realm / "data/core.db"
        db.unlink()
        db.symlink_to(self.normal)
        with self.assertRaises(ops.Refused):
            a.realm_guard(realm, self.normal)

    def test_realm_same_final_codex_home_alias_refused(self):
        realm = self.realm()
        realm.joinpath("state/agent/backend").mkdir(parents=True)
        realm.joinpath("state/agent/backend/codex").symlink_to(self.normal.parent)
        with self.assertRaises(ops.Refused):
            a.realm_guard(realm, self.normal)

    def test_schema_mismatch_refused(self):
        realm = self.realm()
        with closing(sqlite3.connect(realm / "data/core.db")) as db:
            db.execute("PRAGMA user_version=4")
        with self.assertRaises(ops.Refused):
            a.realm_guard(realm, self.normal)

    def test_plaintext_auth_fallback_refused(self):
        realm = self.realm()
        path = realm / "state/agent/backend/codex/auth.json"
        path.parent.mkdir(parents=True)
        path.write_text("TEST ONLY forbidden credential file")
        with self.assertRaisesRegex(ops.Refused, "PLAINTEXT"):
            a.realm_guard(realm, self.normal)

    def test_private_checks_do_not_mutate_normal_database(self):
        realm = self.realm()
        before = ops.sha(self.normal)
        a.realm_guard(realm, self.normal)
        self.assertEqual(ops.sha(self.normal), before)
        self.assertEqual(ops.schema(self.normal), 4)

    def test_init_command_is_real_core_contract_not_database_rows(self):
        realm = a.realm_path(ID, self.home)
        argv, env, runtime = a.core_contract(self.root, realm, ID)
        self.assertEqual(argv[:4], [str(self.root / "candidate/target/release/ditto-core"), "serve", "--compositor", "fixture"])
        self.assertNotIn("--development", argv)
        self.assertNotIn("--agent-backend-test-provider", argv)
        self.assertEqual(env["DITTO_DATA_DIR"], str(realm))
        self.assertEqual(env["DITTO_SYSTEM"], "none")
        self.assertEqual(env["DITTO_REQUIRE_QUOTA"], "1")
        self.assertEqual(env["DITTO_LAUNCH_SCOPE_PREFIX"], "ditto-g3-auth-q" + ID)
        self.assertNotEqual(runtime, ops.RUNTIME / "ditto")
        self.assertNotIn("GH_TOKEN", env)
        self.assertNotIn("GITHUB_TOKEN", env)
        self.assertNotIn("OPENAI_API_KEY", env)

    def test_static_pinned_keyring_and_device_api_contract(self):
        repo = Path(__file__).resolve().parents[3]
        backend = repo.joinpath("crates/ditto-core/src/agent_backend.rs").read_text()
        adapter = repo.joinpath("packages/agent-runtime/src/codex.ts").read_text()
        routes = repo.joinpath("crates/ditto-core/src/agent_routes.rs").read_text()
        self.assertIn('cli_auth_credentials_store=\\"keyring\\"', backend)
        self.assertIn('root.join("home"), root.join("codex")', backend)
        self.assertIn("{type:'chatgptDeviceCode'}", adapter)
        self.assertIn("identity?.type==='chatgpt'", adapter)
        self.assertIn("agent.providers.cancel_login", routes)
        self.assertIn("600_000", routes)

    def test_wrong_provider_unknown_status_refused(self):
        for value in ({"provider": "direct-model", "available": True, "authenticated": True},
                      {"provider": "codex-app-server", "available": True, "authenticated": "yes"},
                      {"provider": "codex-app-server", "available": False, "authenticated": True}):
            with self.assertRaises(ops.Refused):
                a.status_guard(value)

    def test_required_model_and_effort_no_substitution(self):
        for value in ({"models": [{"id": "gpt-6-sol", "reasoning_efforts": ["high"]}]},
                      {"models": [{"id": a.MODEL, "reasoning_efforts": ["low"]}]}, {"models": []}):
            with self.assertRaises(ops.Refused):
                a.model_guard(value)

    def test_tool_trace_must_be_observed_zero(self):
        events = {"events": [{"type": "model/selection", "data": {"model": a.MODEL, "provider": "codex-app-server"}}]}
        a.probe_guard({"state": "succeeded", "tool_calls": 0}, {"tools": []}, events)
        with self.assertRaises(ops.Refused):
            a.probe_guard({"state": "succeeded", "tool_calls": 1}, {"tools": []}, events)
        with self.assertRaises(ops.Refused):
            a.probe_guard({"state": "succeeded", "tool_calls": 0}, {"tools": [{"test_only": True}]}, events)

    def test_probe_unknown_or_failed_result_refused(self):
        with self.assertRaises(ops.Refused):
            a.probe_guard({"state": "unknown", "tool_calls": 0}, {"tools": []}, {"events": []})

    def test_probe_wrong_actual_model_refused(self):
        with self.assertRaises(ops.Refused):
            a.probe_guard({"state": "succeeded", "tool_calls": 0}, {"tools": []}, {"events": [{"type": "model/selection", "data": {"model": "other", "provider": "codex-app-server"}}]})

    def test_transport_failure_cancels_exact_login_and_stops_before_return(self):
        core, transport = TestOnlyCore(), TestOnlyTransport(fail=True)
        updates, out, err = [], io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            with self.assertRaises(ops.Refused) as result:
                a.device_flow(core, transport, self.receipt(), lambda **value: updates.append(value))
        self.assertNotIn(CODE, str(result.exception) + out.getvalue() + err.getvalue() + json.dumps(updates))
        self.assertIn(("agent.providers.cancel_login", {"provider": "codex-app-server", "login_id": "TEST_ONLY_LOGIN"}), core.calls)
        self.assertEqual(core.calls[-1][0], "agent.runtime.stop")
        self.assertEqual(sum(m == "agent.providers.login" for m, p in core.calls), 1)

    def test_expired_code_cancels_before_transport(self):
        core, transport = TestOnlyCore(), TestOnlyTransport()
        core.login["expires_at_ms"] = b.now_ms() - 1
        with self.assertRaises(ops.Refused):
            a.device_flow(core, transport, self.receipt(), lambda **v: None)
        self.assertEqual(transport.paths, [])
        self.assertEqual(core.calls[-1][0], "agent.runtime.stop")

    def test_unknown_login_method_cancelled_and_refused(self):
        core, transport = TestOnlyCore(), TestOnlyTransport()
        core.login["method"] = "api_key"
        with self.assertRaises(ops.Refused):
            a.device_flow(core, transport, self.receipt(), lambda **v: None)
        self.assertEqual(transport.paths, [])

    def test_scalar_login_response_still_stops_service(self):
        core, transport = TestOnlyCore(), TestOnlyTransport()
        core.login = CODE
        with self.assertRaises(ops.Refused):
            a.device_flow(core, transport, self.receipt(), lambda **v: None)
        self.assertEqual(core.calls[-1][0], "agent.runtime.stop")
        self.assertEqual(transport.paths, [])

    def test_fixture_auth_supervisor_cleanup_is_idempotent_and_erases_keys_first(self):
        directory = self.root / "auth-bridge"
        directory.mkdir(mode=0o700)
        directory.joinpath("client.key").write_text("TEST ONLY local key marker")
        directory.joinpath("client.pem").write_text("TEST ONLY local certificate")
        ops.write(self.root / "auth-state.json", {"test_only": True, "status": "awaiting_browser", "normal_before": {"test_only": True}})
        class Host:
            def system(inner, *args, **kw):
                return ""
            def normal(inner):
                self.assertFalse(directory.joinpath("client.key").exists())
                return {"test_only": True}
        with patch.object(a, "stop_scopes"):
            first = a.cleanup(self.root, Host())
            second = a.cleanup(self.root, Host())
        self.assertEqual(first, second)
        self.assertEqual(first["status"], "blocked")
        self.assertTrue(first["native_stopped"])

    def test_cleanup_failure_preserves_needs_human(self):
        self.root.joinpath("auth-bridge").mkdir(mode=0o700)
        ops.write(self.root / "auth-state.json", {"test_only": True, "status": "starting", "normal_before": {"test_only": True}})
        with patch.object(a, "stop_scopes", side_effect=ops.Refused("TEST ONLY cleanup failure")):
            result = a.cleanup(self.root, object())
        self.assertEqual(result["status"], "needs_human")
        self.assertFalse(result["native_stopped"])

    def test_launch_requires_stopped_service_and_complete_native_proof(self):
        # Static real entry point check: no legacy assertion is reachable.
        source = Path(ops.__file__).read_text()
        launch = source[source.index("def launch("):source.index("def enter(")]
        self.assertIn("verified_realm(root, host)", launch)
        self.assertNotIn("selection.json", launch)
        self.assertNotIn("existing_subscription_proved", launch)
        gate = Path(a.__file__).read_text().split("def verified_realm(", 1)[1].split("def public_status(", 1)[0]
        for expected in ("native_stopped", "stopped_guard(root, state, host)", "chatgpt_subscription"):
            self.assertIn(expected, gate)

    def test_stopped_guard_refuses_live_core(self):
        state = {"test_only": True, "native_stopped": True, "core_witness": {"pid": 999}}
        with patch.object(ops, "witness", return_value={"pid": 999}):
            with self.assertRaisesRegex(ops.Refused, "CORE_STILL_RUNNING"):
                a.stopped_guard(self.root, state)

    def test_stopped_guard_refuses_active_or_deactivating_service(self):
        state = {"test_only": True, "native_stopped": True, "core_witness": {"pid": 999}}
        class Host:
            def system(inner, *args, **kw):
                return inner.status
        host = Host()
        for status in ("active", "activating", "deactivating"):
            host.status = status
            with patch.object(ops, "witness", return_value=None), self.assertRaisesRegex(ops.Refused, "SERVICE_STILL_RUNNING"):
                a.stopped_guard(self.root, state, host)

    def test_stopped_guard_refuses_unknown_cleanup_proof(self):
        with self.assertRaisesRegex(ops.Refused, "AUTH_CLEANUP"):
            a.stopped_guard(self.root, {"test_only": True, "native_stopped": False})

    def test_auth_service_has_independent_cleanup_no_secret_logging(self):
        source = Path(a.__file__).read_text()
        service = source.split("def start_login(", 1)[1].split("def cleanup(", 1)[0]
        for field in ("ExecStopPost", "auth_cleanup", "RuntimeMaxSec=900", "StandardOutput=null", "StandardError=null", "LimitCORE=0"):
            self.assertIn(field, service)
        self.assertNotIn("user_code", service)
        self.assertNotIn("login_id", service)

    def test_prepare_itself_has_bounded_cleanup_no_actions_query(self):
        source = Path(a.__file__).read_text()
        prepare = source.split("def prepare(", 1)[1].split("def minimal_probe(", 1)[0]
        self.assertIn("--on-active=890", prepare)
        self.assertIn("auth_cleanup", prepare)
        self.assertNotIn("gh", prepare)

    def test_login_success_separate_from_failed_model_verification(self):
        core, transport = TestOnlyCore(), TestOnlyTransport()
        updates = []
        with patch.object(a, "minimal_probe", side_effect=ops.Refused("TEST_ONLY_PROBE_FAILURE")):
            with self.assertRaises(ops.Refused):
                a.device_flow(core, transport, self.receipt(), lambda **v: updates.append(v))
        self.assertIn({"status": "login_complete", "login_complete": True}, updates)
        self.assertIn("/status", transport.paths)
        self.assertNotIn(CODE, json.dumps(updates))

    def test_logic_fake_probe_is_not_native_receipt(self):
        core, transport = TestOnlyCore(), TestOnlyTransport()
        updates = []
        with patch.object(a, "minimal_probe", return_value={"test_only": True, "tool_calls_observed": 0}):
            result = a.device_flow(core, transport, self.receipt(), lambda **v: updates.append(v))
        self.assertTrue(result["test_only"])
        self.assertNotIn("evidence_class", result)
        self.assertNotIn(CODE, json.dumps(result) + json.dumps(updates))

    def test_launch_gate_rejects_fixture_auth_receipt(self):
        ops.write(self.root / "auth-state.json", {"test_only": True, "evidence_class": "native-core-auth-verified"})
        with patch.object(ops, "verify_stage", return_value={"ops_sha": "b" * 40}):
            with self.assertRaisesRegex(ops.Refused, "NON_NATIVE"):
                a.verified_realm(self.root)

    def test_launch_gate_rejects_non_native_evidence_class(self):
        ops.write(self.root / "auth-state.json", {"evidence_class": "TEST_ONLY"})
        with patch.object(ops, "verify_stage", return_value={"ops_sha": "b" * 40}):
            with self.assertRaisesRegex(ops.Refused, "NON_NATIVE"):
                a.verified_realm(self.root)

    def test_safe_status_never_emits_extra_state_values(self):
        ops.write(self.root / "auth-state.json", {"test_only": True, "status": "awaiting_browser", "login_complete": False, "model_verified": False, "native_stopped": False,
                                                 "forbidden_test_sentinel": CODE})
        self.assertNotIn(CODE, json.dumps(a.public_status(self.root)))

    def test_safe_unknown_status_refused(self):
        ops.write(self.root / "auth-state.json", {"test_only": True, "status": "run_arbitrary_command"})
        with self.assertRaises(ops.Refused):
            a.public_status(self.root)

    def test_missing_native_receipt_keeps_launch_closed(self):
        with patch.object(ops, "verify_stage", return_value={}):
            with self.assertRaises(FileNotFoundError):
                a.verified_realm(self.root)

    def test_new_workflow_transport_input_is_public_only_no_shell_interpolation(self):
        repo = Path(__file__).resolve().parents[3]
        text = repo.joinpath(".github/workflows/nightly-refmachine.yml").read_text()
        self.assertIn("auth_prepare, auth_login, auth_status", text)
        self.assertIn("DITTO_G3_AUTH_TRANSPORT: ${{ inputs.auth_transport }}", text)
        self.assertNotIn("inputs.user_code", text)
        self.assertNotIn("inputs.private_key", text)
        self.assertIn('"old_store_discovery":"not_run"', text)


if __name__ == "__main__":
    unittest.main(verbosity=2)

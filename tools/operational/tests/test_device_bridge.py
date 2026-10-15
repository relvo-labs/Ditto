"""TEST ONLY: real loopback TLS, ephemeral certificates, in-memory sender.

No LAN connection, actual Home route, account, credential or provider call.
"""
from contextlib import redirect_stdout, redirect_stderr
import http.client
import io
import json
import os
from pathlib import Path
import socket
import ssl
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import g3_device_bridge as b

IDENTIFIER, FLOW, CODE = "123456789", "a" * 32, "TEST-1234"


class LoopbackBridge(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="TEST_ONLY_tls_")
        cls.root = Path(cls.temp.name)
        cls.certs = {}
        for name, role in (("client", "client"), ("server", "server"), ("wrong-client", "client"), ("wrong-server", "server")):
            directory = cls.root / name
            directory.mkdir(mode=0o700)
            cls.certs[name] = b.certificate(directory, role, "127.0.0.1")

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.messages = []
        self.state = b.ReceiverState(IDENTIFIER, FLOW, self.certs["client"]["sha256"], b.now_ms() + 300_000, self.messages.append)
        # Port zero is confined to the actual test server's bind. Public
        # transport requires a high task port, so choose within its range.
        context = b.server_context(self.root / "server", self.certs["client"]["certificate"])
        for port in range(51000, 51100):
            try:
                self.server = b.QuietServer(("127.0.0.1", port), context, self.state)
                break
            except OSError:
                pass
        else:
            self.fail("TEST ONLY loopback ports unavailable")
        self.config = {"qualification_id": IDENTIFIER, "flow_id": FLOW, "host": "127.0.0.1", "port": port,
                       "server_certificate": self.certs["server"]["certificate"], "server_sha256": self.certs["server"]["sha256"],
                       "client_sha256": self.certs["client"]["sha256"], "expires_at_ms": self.state.deadline}
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.run_server, daemon=True)
        self.thread.start()
        self.client = b.Client(self.root / "client", self.config, IDENTIFIER, FLOW, loopback=True)

    def run_server(self):
        while not self.stop.is_set():
            self.server.handle_request()

    def tearDown(self):
        self.stop.set()
        self.thread.join(timeout=4)
        self.server.server_close()
        self.assertFalse(self.thread.is_alive())

    def payload(self):
        return {"qualification_id": IDENTIFIER, "flow_id": FLOW, "auth_url": "https://auth.openai.com/codex/device", "user_code": CODE, "expires_at_ms": b.now_ms() + 120_000}

    def test_probe_phase_real_client_receipt_proves_key_cleanup(self):
        import shutil
        import g3_ops as ops
        import g3_bridge_probe as probe
        self.server.state=b.ProbeReceiverState(IDENTIFIER,FLOW,self.certs["client"]["sha256"],self.config["expires_at_ms"])
        with tempfile.TemporaryDirectory(prefix="TEST_ONLY_probe_phase_") as temp:
            root=Path(temp)/("p"+IDENTIFIER);root.mkdir(mode=0o700)
            (root/"client").mkdir(mode=0o700);(root/"ops").mkdir(mode=0o700)
            for name in ("client.key","client.pem"):
                shutil.copyfile(self.root/"client"/name,root/"client"/name);(root/"client"/name).chmod(0o600)
            hashes={}
            for name in probe.FILES:
                shutil.copyfile(ops.HERE/name,root/"ops"/name);hashes[name]=ops.sha(root/"ops"/name)
            ops.write(root/"probe-state.json",{"test_only":True,"qualification_id":IDENTIFIER,"flow_id":FLOW,"source":ops.SOURCE,"ops_sha":"a"*40,"status":"prepared","attempted":False,"expires_at_ms":self.config["expires_at_ms"],"ops_files":hashes})
            ops.write(root/"probe-prepare.json",{"client_sha256":self.config["client_sha256"]})
            real=b.Client
            with patch.dict(os.environ,{"GITHUB_SHA":"a"*40}),patch.object(b,"Client",side_effect=lambda *args,**kw: real(*args,**kw,loopback=True)),patch.object(b,"send_home") as sender:
                result=probe.run(root,ops.Host(root),json.dumps(self.config))
            self.assertEqual(result["result"],"PROBE_OK");self.assertTrue(result["keys_erased"])
            self.assertFalse((root/"client/client.key").exists());sender.assert_not_called()
            self.assertFalse(result["provider_called"]);self.assertFalse(result["home_called"])
            with self.assertRaises(ops.Refused):probe.run(root,ops.Host(root),json.dumps(self.config))

    def test_probe_receiver_terminal_cleanup_receipt_logic(self):
        # TEST ONLY accept loop; real TLS/peer exchange covered by the other
        # loopback tests. No bind to parent/LAN address and no actual sender.
        import shutil
        with tempfile.TemporaryDirectory(prefix="TEST_ONLY_parent_probe_") as temp:
            directory=Path(temp);directory.chmod(0o700)
            for name in ("server.key","server.pem"):
                shutil.copyfile(self.root/"server"/name,directory/name);(directory/name).chmod(0o600)
            (directory/"client.pem").write_text(self.certs["client"]["certificate"])
            (directory/"purpose.json").write_text('{"purpose":"probe"}')
            (directory/"transport.json").write_text(json.dumps({**self.config,"host":b.PARENT_IP}))
            class TestOnlyServer:
                def __init__(inner,address,context,state):inner.state=state
                def handle_request(inner):inner.state.accept("/probe",self.certs["client"]["sha256"],json.dumps(self.probe_body()).encode())
                def server_close(inner):pass
            with patch.object(b,"QuietServer",TestOnlyServer),patch.object(b,"send_home") as sender,redirect_stdout(io.StringIO()):
                result=b.serve_receiver(directory,probe=True)
            self.assertEqual(result,{"result":"PROBE_OK","keys_erased":True});sender.assert_not_called()
            self.assertFalse((directory/"server.key").exists())

    def probe_client(self):
        return b.Client(self.root / "client", self.config, IDENTIFIER, FLOW, loopback=True, probe=True)

    def probe_body(self):
        return {"qualification_id": IDENTIFIER, "flow_id": FLOW, "probe": "reachability-v1"}

    def test_probe_real_mtls_never_calls_sender(self):
        self.server.state = b.ProbeReceiverState(IDENTIFIER,FLOW,self.certs["client"]["sha256"],self.config["expires_at_ms"])
        with patch.object(b,"send_home") as sender:
            result=self.probe_client().post("/probe",self.probe_body())
        self.assertEqual(result,{"status":"PROBE_OK"})
        sender.assert_not_called();self.assertEqual(self.messages,[])
        self.assertTrue(self.server.state.done)

    def test_normal_receiver_refuses_probe_path_over_mtls(self):
        with self.assertRaisesRegex(b.BridgeRefused,"BLOCKED_RECEIVER_REFUSED"):
            self.probe_client().post("/probe",self.probe_body())
        self.assertEqual(self.messages,[])

    def test_probe_receiver_refuses_login_and_status_over_mtls(self):
        self.server.state=b.ProbeReceiverState(IDENTIFIER,FLOW,self.certs["client"]["sha256"],self.config["expires_at_ms"])
        for path,value in (("/login_code",self.payload()),("/status",{"qualification_id":IDENTIFIER,"flow_id":FLOW,"status":"blocked"})):
            with self.subTest(path=path),self.assertRaisesRegex(b.BridgeRefused,"BLOCKED_RECEIVER_REFUSED"):
                self.client.post(path,value)
        self.assertFalse(self.server.state.done);self.assertEqual(self.messages,[])

    def test_probe_mtls_flow_mismatch_and_replay_refused(self):
        self.server.state=b.ProbeReceiverState(IDENTIFIER,FLOW,self.certs["client"]["sha256"],self.config["expires_at_ms"])
        client=self.probe_client()
        with self.assertRaises(b.BridgeRefused):client.post("/probe",{**self.probe_body(),"flow_id":"b"*32})
        self.assertEqual(client.post("/probe",self.probe_body()),{"status":"PROBE_OK"})
        with self.assertRaises(b.BridgeRefused):client.post("/probe",self.probe_body())
        self.assertEqual(self.messages,[])

    def test_probe_untrusted_client_refused(self):
        self.server.state=b.ProbeReceiverState(IDENTIFIER,FLOW,self.certs["client"]["sha256"],self.config["expires_at_ms"])
        client=b.Client(self.root/"wrong-client",{**self.config,"client_sha256":self.certs["wrong-client"]["sha256"]},IDENTIFIER,FLOW,loopback=True,probe=True)
        with self.assertRaises(b.BridgeRefused) as refusal:client.post("/probe",self.probe_body())
        self.assertIn(refusal.exception.args[0], {"BLOCKED_MTLS_HANDSHAKE", "BLOCKED_RECEIVER_REFUSED"})
        self.assertFalse(self.server.state.done)
        self.assertEqual(self.messages,[])

    def test_probe_expiry_and_fields_refused(self):
        self.server.state=b.ProbeReceiverState(IDENTIFIER,FLOW,self.certs["client"]["sha256"],self.config["expires_at_ms"])
        client=self.probe_client()
        with self.assertRaises(b.BridgeRefused):client.post("/probe",{**self.probe_body(),"recipient":"SECRET_SENTINEL"})
        self.server.state.deadline=b.now_ms()-1
        with self.assertRaises(b.BridgeRefused):client.post("/probe",self.probe_body())
        self.assertEqual(self.messages,[])

    def test_client_handshake_reason_and_peer_pin_reason(self):
        config={**self.config,"server_certificate":self.certs["wrong-server"]["certificate"],"server_sha256":self.certs["wrong-server"]["sha256"]}
        client=b.Client(self.root/"client",config,IDENTIFIER,FLOW,loopback=True)
        with self.assertRaisesRegex(b.BridgeRefused,"BLOCKED_MTLS_HANDSHAKE"):client.post("/login_code",self.payload())
        self.client.config={**self.config,"server_sha256":"f"*64}
        with self.assertRaisesRegex(b.BridgeRefused,"BLOCKED_MTLS_PEER_MISMATCH"):self.client.post("/login_code",self.payload())

    def test_actual_correct_mtls_handshake_and_private_delivery(self):
        self.client.post("/login_code", self.payload())
        self.assertEqual(len(self.messages), 1)
        self.assertIn(CODE, self.messages[0])
        self.assertTrue(self.state.delivered)
        self.assertNotIn(CODE, repr(vars(self.state)))

    def test_actual_untrusted_client_handshake_denied(self):
        config = {**self.config, "client_sha256": self.certs["wrong-client"]["sha256"]}
        client = b.Client(self.root / "wrong-client", config, IDENTIFIER, FLOW, loopback=True)
        with self.assertRaises(b.BridgeRefused):
            client.post("/login_code", self.payload())
        self.assertEqual(self.messages, [])

    def test_actual_wrong_server_handshake_denied(self):
        config = {**self.config, "server_certificate": self.certs["wrong-server"]["certificate"], "server_sha256": self.certs["wrong-server"]["sha256"]}
        client = b.Client(self.root / "client", config, IDENTIFIER, FLOW, loopback=True)
        with self.assertRaises(b.BridgeRefused):
            client.post("/login_code", self.payload())
        self.assertEqual(self.messages, [])

    def test_actual_missing_client_certificate_denied(self):
        context = ssl.create_default_context(cadata=self.certs["server"]["certificate"])
        connection = http.client.HTTPSConnection("127.0.0.1", self.config["port"], context=context, timeout=3)
        try:
            with self.assertRaises((ssl.SSLError, OSError, http.client.HTTPException)):
                connection.request("POST", "/login_code", body=json.dumps(self.payload()), headers={"Content-Type": "application/json"})
                connection.getresponse()
        finally:
            connection.close()
        self.assertEqual(self.messages, [])

    def test_peer_fingerprint_checked_after_real_handshake(self):
        self.state.client_sha = "f" * 64
        with self.assertRaises(b.BridgeRefused):
            self.client.post("/login_code", self.payload())
        self.assertEqual(self.messages, [])

    def test_flow_mismatch_refused(self):
        value = {**self.payload(), "flow_id": "b" * 32}
        with self.assertRaises(b.BridgeRefused):
            self.client.post("/login_code", value)
        self.assertEqual(self.messages, [])

    def test_qualification_mismatch_refused(self):
        with self.assertRaises(b.BridgeRefused):
            self.client.post("/login_code", {**self.payload(), "qualification_id": "223456789"})

    def test_replay_never_sends_twice(self):
        self.client.post("/login_code", self.payload())
        with self.assertRaises(b.BridgeRefused):
            self.client.post("/login_code", self.payload())
        self.assertEqual(len(self.messages), 1)

    def test_expired_flow_refused(self):
        self.state.deadline = b.now_ms() - 1
        with self.assertRaises(b.BridgeRefused):
            self.client.post("/login_code", self.payload())

    def test_monotonic_expiry_also_refused(self):
        self.state.monotonic_deadline = time.monotonic() - 1
        with self.assertRaises(b.BridgeRefused):
            self.client.post("/login_code", self.payload())

    def test_expired_code_refused(self):
        with self.assertRaises(b.BridgeRefused):
            self.client.post("/login_code", {**self.payload(), "expires_at_ms": b.now_ms() - 1})

    def test_code_expiry_cannot_exceed_flow(self):
        with self.assertRaises(b.BridgeRefused):
            self.client.post("/login_code", {**self.payload(), "expires_at_ms": self.state.deadline + 1})

    def test_official_url_allowlist(self):
        for url in ("http://auth.openai.com/codex/device", "https://auth.openai.com.evil.invalid/codex/device", "https://x@auth.openai.com/codex/device", "https://auth.openai.com/codex/device?code=" + CODE, "https://auth.openai.com/admin", "https://auth.openai.com:443/codex/device"):
            with self.subTest(url=url), self.assertRaises(b.BridgeRefused):
                self.client.post("/login_code", {**self.payload(), "auth_url": url})
        self.assertEqual(self.messages, [])

    def test_user_code_syntax_and_size(self):
        for code in ("abc-1234", "ABC", "A" * 17, "ABC\nDEF", "ABC_1234"):
            with self.subTest(code=code), self.assertRaises(b.BridgeRefused):
                self.client.post("/login_code", {**self.payload(), "user_code": code})

    def test_arbitrary_recipient_or_command_field_refused(self):
        for name in ("recipient", "command", "file", "token", "account"):
            with self.subTest(name=name), self.assertRaises(b.BridgeRefused):
                self.client.post("/login_code", {**self.payload(), name: "TEST ONLY"})

    def test_arbitrary_admin_path_and_queries_refused(self):
        for path in ("/exec", "/file", "/admin", "/login_code?code=" + CODE):
            with self.subTest(path=path), self.assertRaises(b.BridgeRefused):
                self.client.post(path, self.payload())

    def test_oversized_body_refused(self):
        with self.assertRaises(b.BridgeRefused):
            self.client.post("/login_code", {**self.payload(), "padding": "x" * b.MAX_BODY})

    def test_malformed_payload_and_sender_error_never_echo_code(self):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            with self.assertRaises(b.BridgeRefused) as result:
                self.client.post("/login_code", {**self.payload(), "command": CODE})
            self.assertNotIn(CODE, str(result.exception))
            def bad_sender(message):
                raise RuntimeError("TEST ONLY sender failure " + message)
            self.state.sender = bad_sender
            with self.assertRaises(b.BridgeRefused) as result:
                self.client.post("/login_code", self.payload())
            self.assertNotIn(CODE, str(result.exception))
        self.assertNotIn(CODE, out.getvalue() + err.getvalue() + repr(vars(self.state)))
        self.assertTrue(self.state.done)

    def test_only_safe_status_sequence(self):
        self.client.post("/login_code", self.payload())
        value = {"qualification_id": IDENTIFIER, "flow_id": FLOW, "status": "verified"}
        with self.assertRaises(b.BridgeRefused):
            self.client.post("/status", value)
        self.client.post("/status", {**value, "status": "login_complete"})
        self.client.post("/status", value)
        self.assertTrue(self.state.done)
        self.assertEqual(len(self.messages), 3)
        self.assertNotIn(CODE, self.messages[1] + self.messages[2])

    def test_unknown_status_and_code_in_status_refused(self):
        self.client.post("/login_code", self.payload())
        for value in ({"qualification_id": IDENTIFIER, "flow_id": FLOW, "status": "execute"},
                      {"qualification_id": IDENTIFIER, "flow_id": FLOW, "status": "blocked", "user_code": CODE}):
            with self.assertRaises(b.BridgeRefused):
                self.client.post("/status", value)

    def test_public_certificates_do_not_expose_keys(self):
        data = json.dumps(self.config)
        self.assertNotIn("PRIVATE", data)
        for name in ("client", "server"):
            self.assertEqual((self.root / name / (name + ".key")).stat().st_mode & 0o777, 0o600)
        self.assertGreaterEqual(self.client.context.minimum_version, ssl.TLSVersion.TLSv1_2)
        self.assertEqual(self.client.context.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(self.client.context.check_hostname)

    def test_no_real_sender_during_tls_tests(self):
        with patch.object(b.subprocess, "run", side_effect=AssertionError("no real sender permitted")):
            self.client.post("/login_code", self.payload())

    def test_hermes_command_is_fixed_stdin_no_outputs(self):
        with patch.object(b.subprocess, "run") as run:
            run.return_value.returncode = 0
            b.send_home("TEST ONLY " + CODE)
        args, kw = run.call_args
        self.assertEqual(args[0], b.HOME_SENDER)
        self.assertNotIn(CODE, repr(args))
        self.assertIn(CODE.encode(), kw["input"])
        self.assertEqual(kw["stdout"], b.subprocess.DEVNULL)
        self.assertEqual(kw["stderr"], b.subprocess.DEVNULL)

    def test_public_transport_cannot_select_lan_or_arbitrary_host_in_test(self):
        for value in ("example.invalid", "10.0.1.234", "192.168.1.102"):
            with self.assertRaises(b.BridgeRefused):
                b.validate_transport({**self.config, "host": value}, IDENTIFIER, FLOW, loopback=True)

    def test_production_transport_accepts_only_exact_parent(self):
        b.validate_transport({**self.config, "host": b.PARENT_IP}, IDENTIFIER, FLOW)
        with self.assertRaises(b.BridgeRefused):
            b.validate_transport(self.config, IDENTIFIER, FLOW)

    def test_duplicate_json_keys_refused(self):
        with self.assertRaises(b.BridgeRefused):
            b.strict_json(b'{"status":"blocked","status":"verified"}')

    def raw_post(self, path, body, headers=None, method="POST"):
        connection = http.client.HTTPSConnection("127.0.0.1", self.config["port"], context=self.client.context, timeout=3)
        try:
            connection.request(method, path, body=body, headers=headers or {"Content-Type": "application/json"})
            reply = connection.getresponse()
            return reply.status, reply.read(256)
        finally:
            connection.close()

    def test_actual_server_admin_path_and_get_refused_without_echo(self):
        for method, path in (("POST", "/exec"), ("GET", "/login_code"), ("POST", "/login_code?code=" + CODE)):
            status, raw = self.raw_post(path, json.dumps(self.payload()), method=method)
            self.assertEqual(status, 400)
            self.assertNotIn(CODE.encode(), raw)
        self.assertEqual(self.messages, [])

    def test_actual_server_oversized_body_and_malformed_json_refused(self):
        for body in (b"x" * (b.MAX_BODY + 1), b'{"user_code":"' + CODE.encode() + b'", bad-json}', b'{"a":1,"a":2}'):
            status, raw = self.raw_post("/login_code", body)
            self.assertEqual(status, 400)
            self.assertNotIn(CODE.encode(), raw)
        self.assertEqual(self.messages, [])

    def test_actual_server_no_chunked_or_other_content_type(self):
        for headers in ({"Content-Type": "text/plain"}, {"Content-Type": "application/json", "Transfer-Encoding": "chunked"}):
            status, raw = self.raw_post("/login_code", json.dumps(self.payload()), headers=headers)
            self.assertEqual(status, 400)
        self.assertEqual(self.messages, [])

    def test_terminal_route_failure_is_not_receiver_success(self):
        def fail(message):
            raise RuntimeError(CODE)
        self.state.sender = fail
        with self.assertRaises(b.BridgeRefused):
            self.client.post("/login_code", self.payload())
        self.assertTrue(self.state.done)
        self.assertTrue(self.state.failed)

    def test_authenticated_cancel_before_code_tears_down_one_flow(self):
        self.client.post("/status", {"qualification_id": IDENTIFIER, "flow_id": FLOW, "status": "cancelled"})
        self.assertTrue(self.state.done)
        self.assertFalse(self.state.delivered)
        self.assertNotIn(CODE, self.messages[0])

    def test_certificate_disposal_removes_only_own_keys(self):
        directory = self.root / "TEST_ONLY_disposal"
        directory.mkdir(mode=0o700, exist_ok=True)
        for name in ("client.key", "client.pem", "keep.txt"):
            (directory / name).write_text("TEST ONLY")
        b.erase_keys(directory, "client")
        b.erase_keys(directory, "client")
        self.assertEqual([p.name for p in directory.iterdir()], ["keep.txt"])

    def test_abandoned_prepare_expiry_cleans_keys_even_if_already_expired(self):
        directory = self.root / "TEST_ONLY_expired"
        directory.mkdir(mode=0o700, exist_ok=True)
        for name in ("server.key", "server.pem", "client.pem", "disposal.json"):
            (directory / name).write_text("TEST ONLY")
        (directory / "transport.json").write_text(json.dumps({**self.config, "host": b.PARENT_IP, "expires_at_ms": b.now_ms() - 1}))
        with self.assertRaises(b.BridgeRefused):
            b.expire_preparation(directory)
        self.assertEqual(list(directory.iterdir()), [])

    def test_actual_short_prepare_deadline_erases_keys(self):
        directory = self.root / "TEST_ONLY_short_deadline"
        directory.mkdir(mode=0o700, exist_ok=True)
        for name in ("server.key", "server.pem", "client.pem", "disposal.json"):
            (directory / name).write_text("TEST ONLY")
        (directory / "transport.json").write_text(json.dumps({**self.config, "host": b.PARENT_IP, "expires_at_ms": b.now_ms() + 200}))
        b.expire_preparation(directory)  # no listener/network/sender
        self.assertEqual(list(directory.iterdir()), [])

    def test_fixture_prepare_receipt_refused_by_receiver(self):
        receipt = {"qualification_id": IDENTIFIER, "flow_id": FLOW, "source": "17f5d76dc043d7d8117f1e99458a9a0c9255354b", "ops_sha": "b" * 40,
                   "evidence_class": "TEST_ONLY", "client_certificate": self.certs["client"]["certificate"], "client_sha256": self.certs["client"]["sha256"], "expires_at_ms": self.state.deadline}
        with self.assertRaises(b.BridgeRefused):
            b.prepare_receiver(receipt, self.root / "must-not-exist")
        self.assertFalse((self.root / "must-not-exist").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)

#!/usr/bin/env python3
"""One flow, two pinned TLS peers, one private Home. Never an admin API.

The receiver is started ONLY by the parent. Tests bind only loopback and
inject a TEST ONLY sender; no test invokes Hermes. Secret bodies stay in RAM.
"""
import argparse
import errno
import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
import re
import secrets
import signal
import socket
import ssl
import subprocess
import sys
import time
from urllib.parse import urlsplit

PARENT_IP = "192.168.1.102"
MAX_BODY = 4096
MAX_LIFE_MS = 900_000
HOME_SENDER = ("/home/neil/.local/bin/hermes", "send", "--to", "telegram:8016167934", "--quiet", "--file", "-")
STATUSES = {"login_complete", "verified", "blocked", "cancelled"}


class BridgeRefused(RuntimeError):
    """All messages are constant; never put body/exception values here."""


def need(ok, reason="BLOCKED_BRIDGE_INPUT_OR_STATE"):
    if not ok:
        raise BridgeRefused(reason)


def now_ms():
    return int(time.time() * 1000)


def fields(value, names):
    need(type(value) is dict and set(value) == set(names))


def qualification(value):
    need(type(value) is str and re.fullmatch(r"[1-9][0-9]{5,19}", value))
    return value


def flow(value):
    need(type(value) is str and re.fullmatch(r"[a-f0-9]{32}", value))
    return value


def lifetime(expiry, maximum=MAX_LIFE_MS):
    need(type(expiry) is int and 0 < expiry - now_ms() <= maximum)


def fingerprint(pem):
    need(type(pem) is str and len(pem) < 8192 and "PRIVATE" not in pem)
    try:
        der = ssl.PEM_cert_to_DER_cert(pem)
    except Exception:
        raise BridgeRefused("BLOCKED_BRIDGE_CERTIFICATE") from None
    return hashlib.sha256(der).hexdigest()


def private_directory(path, create=False):
    path = Path(path)
    need(path.is_absolute() and path == path.resolve())
    if create:
        path.mkdir(mode=0o700, parents=True, exist_ok=False)
    need(path.is_dir() and path.stat().st_mode & 0o777 == 0o700)
    return path


def certificate(directory, role, ip):
    """OpenSSL is only a local key generator. No private key bytes read out."""
    directory = private_directory(directory)
    need(role in ("client", "server") and ip in (PARENT_IP, "10.0.1.234", "127.0.0.1"))
    key, cert = directory / (role + ".key"), directory / (role + ".pem")
    need(not key.exists() and not cert.exists())
    try:
        result = subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "1",
                             "-keyout", str(key), "-out", str(cert), "-subj", "/CN=ditto-g3-device-" + role,
                             "-addext", "subjectAltName=IP:" + ip,
                             "-addext", "extendedKeyUsage=" + ("clientAuth" if role == "client" else "serverAuth")],
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
        need(result.returncode == 0)
        key.chmod(0o600)
        cert.chmod(0o600)
        # Encoding validity is not the application authorization lifetime.
        return {"certificate": cert.read_text(), "sha256": fingerprint(cert.read_text())}
    except BaseException:
        erase_keys(directory, role)
        raise BridgeRefused("BLOCKED_BRIDGE_KEY_GENERATION") from None


def erase_keys(directory, role):
    for name in (role + ".key", role + ".pem"):
        (Path(directory) / name).unlink(missing_ok=True)


def key_guard(directory, role):
    private_directory(directory)
    key = Path(directory) / (role + ".key")
    need(key == key.resolve() and key.is_file() and key.stat().st_nlink == 1 and key.stat().st_mode & 0o777 == 0o600)


def strict_json(raw):
    need(type(raw) is bytes and 0 < len(raw) <= MAX_BODY)
    def pairs(items):
        result = {}
        for key, value in items:
            need(key not in result)
            result[key] = value
        return result
    try:
        return json.loads(raw, object_pairs_hook=pairs)
    except Exception:
        raise BridgeRefused("BLOCKED_BRIDGE_BODY") from None


def login_payload(value, identifier, flow_id):
    need(type(value) is dict and set(value) == {"qualification_id", "flow_id", "auth_url", "user_code", "expires_at_ms"}, "BLOCKED_DEVICE_PAYLOAD_SHAPE")
    need(value["qualification_id"] == identifier and value["flow_id"] == flow_id, "BLOCKED_DEVICE_PAYLOAD_SHAPE")
    need(type(value["auth_url"]) is str and len(value["auth_url"]) <= 256, "BLOCKED_DEVICE_PAYLOAD_URL")
    try:
        url = urlsplit(value["auth_url"])
        valid = url.scheme == "https" and url.netloc == "auth.openai.com" and url.path == "/codex/device" and not url.query and not url.fragment
    except (ValueError, TypeError):
        valid = False
    need(valid, "BLOCKED_DEVICE_PAYLOAD_URL")
    need(type(value["user_code"]) is str and re.fullmatch(r"[A-Z0-9-]{4,16}", value["user_code"]), "BLOCKED_DEVICE_PAYLOAD_CODE")
    need(type(value["expires_at_ms"]) is int and 0 < value["expires_at_ms"] - now_ms() <= 600_000, "BLOCKED_DEVICE_PAYLOAD_EXPIRY")


def validate_transport(config, identifier, flow_id, *, loopback=False):
    fields(config, {"qualification_id", "flow_id", "host", "port", "server_certificate", "server_sha256", "client_sha256", "expires_at_ms"})
    need(config["qualification_id"] == qualification(identifier) and config["flow_id"] == flow(flow_id))
    need(config["host"] == ("127.0.0.1" if loopback else PARENT_IP))
    need(type(config["port"]) is int and 49152 <= config["port"] <= 65535)
    need(fingerprint(config["server_certificate"]) == config["server_sha256"])
    need(type(config["client_sha256"]) is str and re.fullmatch(r"[a-f0-9]{64}", config["client_sha256"]))
    need(type(config["expires_at_ms"]) is int and 0 < config["expires_at_ms"] - now_ms() <= MAX_LIFE_MS, "BLOCKED_TRANSPORT_EXPIRED")
    return config


def send_home(message):
    """Only this fixed stdin route. No message bytes in argv or outputs."""
    result = subprocess.run(HOME_SENDER, input=message.encode(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    need(result.returncode == 0)


class ReceiverState:
    paths = frozenset({"/login_code", "/status"})
    def __init__(self, identifier, flow_id, client_sha, expiry, sender):
        self.identifier, self.flow_id, self.client_sha = qualification(identifier), flow(flow_id), client_sha
        lifetime(expiry)
        self.deadline = expiry
        self.monotonic_deadline = time.monotonic() + (expiry - now_ms()) / 1000
        self.sender = sender
        self.delivered = False
        self.login_complete = False
        self.done = False
        self.failed = False

    def accept(self, path, peer_sha, raw):
        # No raw body, code, code hash or account identity enters state.
        need(not self.done and peer_sha == self.client_sha and now_ms() < self.deadline and time.monotonic() < self.monotonic_deadline)
        value = strict_json(raw)
        if path == "/login_code":
            need(not self.delivered)
            login_payload(value, self.identifier, self.flow_id)
            need(value["expires_at_ms"] <= self.deadline)
            # Commit once before sending. A route timeout must never retry.
            self.delivered = True
            self.deadline = value["expires_at_ms"]
            self.monotonic_deadline = min(self.monotonic_deadline, time.monotonic() + (self.deadline - now_ms()) / 1000)
            try:
                self.sender("Ditto G3 官方裝置登入（僅本次測試）：\n" + value["auth_url"] + "\n代碼：" + value["user_code"] + "\n請直接在 OpenAI 頁面完成；不要把密碼或 token 回傳。")
            except Exception:
                self.done = True
                self.failed = True
                raise BridgeRefused("BLOCKED_PRIVATE_HOME_ROUTE") from None
            return {"status": "delivered"}
        need(path == "/status")
        fields(value, {"qualification_id", "flow_id", "status"})
        need(value["qualification_id"] == self.identifier and value["flow_id"] == self.flow_id and value["status"] in STATUSES)
        status = value["status"]
        need((self.delivered or status in ("blocked", "cancelled")) and (status != "verified" or self.login_complete))
        need(status != "login_complete" or not self.login_complete)
        if status == "login_complete":
            self.login_complete = True
        else:
            self.done = True
        try:
            self.sender({"login_complete": "Ditto G3：登入已完成；模型驗證尚未完成。", "verified": "Ditto G3：限定模型驗證完成；實體驗收尚未執行。",
                         "blocked": "Ditto G3：本次登入或模型驗證受阻，已停止。", "cancelled": "Ditto G3：本次登入已取消。"}[status])
        except Exception:
            self.done = True
            self.failed = True
            raise BridgeRefused("BLOCKED_PRIVATE_HOME_ROUTE") from None
        return {"status": "delivered"}


class QuietServer(http.server.HTTPServer):
    def __init__(self, address, context, state):
        self.context, self.state = context, state
        super().__init__(address, Handler)
        self.timeout = .25

    def get_request(self):
        sock, address = super().get_request()
        sock.settimeout(3)
        try:
            return self.context.wrap_socket(sock, server_side=True), address
        except Exception:
            sock.close()
            raise OSError("TLS refused") from None

    def handle_error(self, request, client_address):
        pass  # Never print request data/tracebacks to a parent log.


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "DittoDeviceBridge"
    sys_version = ""

    def log_message(self, *args):
        pass

    def send_error(self, code, message=None, explain=None):
        self.reply(400, {"status": "refused"})

    def reply(self, code, value):
        self.close_connection = True
        raw = json.dumps(value).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self):
        try:
            need(self.path in self.server.state.paths)
            need(not self.headers.get("Transfer-Encoding") and self.headers.get("Content-Type") == "application/json")
            sizes = self.headers.get_all("Content-Length", [])
            need(len(sizes) == 1 and sizes[0].isdigit() and 0 < int(sizes[0]) <= MAX_BODY)
            raw = self.rfile.read(int(sizes[0]))
            need(len(raw) == int(sizes[0]))
            peer = hashlib.sha256(self.connection.getpeercert(binary_form=True)).hexdigest()
            value = self.server.state.accept(self.path, peer, raw)
            self.reply(200, value)
        except Exception:
            self.reply(400, {"status": "refused"})


def server_context(directory, client_certificate):
    key_guard(directory, "server")
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(str(Path(directory) / "server.pem"), str(Path(directory) / "server.key"))
    fingerprint(client_certificate)
    ctx.load_verify_locations(cadata=client_certificate)
    ctx.verify_mode = ssl.CERT_REQUIRED
    return ctx


class Client:
    def __init__(self, directory, config, identifier, flow_id, *, loopback=False, probe=False):
        self.probe = probe
        try:
            self._initialize(directory, config, identifier, flow_id, loopback=loopback)
        except BridgeRefused:
            raise
        except (ssl.SSLError, ValueError, OSError, TypeError):
            raise BridgeRefused("BLOCKED_BRIDGE_CERTIFICATE") from None

    def _initialize(self, directory, config, identifier, flow_id, *, loopback=False):
        self.config = validate_transport(config, identifier, flow_id, loopback=loopback)
        self.directory = private_directory(directory)
        key_guard(self.directory, "client")
        need(fingerprint((self.directory / "client.pem").read_text()) == config["client_sha256"], "BLOCKED_MTLS_PEER_MISMATCH")
        ctx = ssl.create_default_context(cadata=config["server_certificate"])
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(str(self.directory / "client.pem"), str(self.directory / "client.key"))
        # Mark handshake failures at the actual wrap boundary. This retains
        # SSLContext certificate/hostname verification and TLS>=1.2; a socket
        # timeout here must not be misreported as a TCP-route timeout.
        wrap = ctx.wrap_socket
        def handshake(*args, **kwargs):
            try:
                return wrap(*args, **kwargs)
            except Exception:
                raise BridgeRefused("BLOCKED_MTLS_HANDSHAKE") from None
        ctx.wrap_socket = handshake
        self.context = ctx

    def post(self, path, value):
        probe = getattr(self, "probe", False)
        need(path in (("/probe",) if probe else ("/login_code", "/status")), "BLOCKED_RECEIVER_REFUSED")
        need(now_ms() < self.config["expires_at_ms"], "BLOCKED_TRANSPORT_EXPIRED")
        raw = json.dumps(value).encode()
        need(len(raw) <= MAX_BODY, "BLOCKED_BRIDGE_BODY")
        connection = http.client.HTTPSConnection(self.config["host"], self.config["port"], context=self.context, timeout=5)
        try:
            try:
                connection.connect()
            except BridgeRefused:
                raise
            except ssl.SSLError:
                raise BridgeRefused("BLOCKED_MTLS_HANDSHAKE") from None
            except (TimeoutError, socket.timeout):
                raise BridgeRefused("BLOCKED_MTLS_TCP_TIMEOUT") from None
            except ConnectionRefusedError:
                raise BridgeRefused("BLOCKED_MTLS_TCP_REFUSED") from None
            except OSError as error:
                code = {errno.ECONNREFUSED: "BLOCKED_MTLS_TCP_REFUSED", errno.ENETUNREACH: "BLOCKED_MTLS_NO_ROUTE", errno.EHOSTUNREACH: "BLOCKED_MTLS_NO_ROUTE", errno.ETIMEDOUT: "BLOCKED_MTLS_TCP_TIMEOUT"}.get(error.errno, "BLOCKED_MTLS_TCP_OTHER")
                raise BridgeRefused(code) from None
            need(hashlib.sha256(connection.sock.getpeercert(binary_form=True)).hexdigest() == self.config["server_sha256"], "BLOCKED_MTLS_PEER_MISMATCH")
            connection.request("POST", path, body=raw, headers={"Content-Type": "application/json"})
            reply = connection.getresponse()
            try:
                answer = strict_json(reply.read(128))
            except BridgeRefused:
                raise BridgeRefused("BLOCKED_RECEIVER_REFUSED") from None
            need(reply.status == 200 and answer == {"status": "PROBE_OK" if probe else "delivered"}, "BLOCKED_RECEIVER_REFUSED")
            return answer
        except BridgeRefused:
            raise
        except ssl.SSLError:
            raise BridgeRefused("BLOCKED_MTLS_HANDSHAKE") from None
        except Exception:
            raise BridgeRefused("BLOCKED_RECEIVER_REFUSED") from None
        finally:
            try:
                connection.close()
            except Exception:
                pass  # never overwrite the original transport refusal


class ProbeReceiverState:
    paths = frozenset({"/probe"})
    def __init__(self, identifier, flow_id, client_sha, expiry):
        self.identifier, self.flow_id = qualification(identifier), flow(flow_id)
        lifetime(expiry, 300_000)
        self.client_sha, self.deadline = client_sha, expiry
        self.monotonic_deadline = time.monotonic() + (expiry - now_ms()) / 1000
        self.done = self.failed = False

    def accept(self, path, peer_sha, raw):
        need(path == "/probe" and not self.done and peer_sha == self.client_sha and now_ms() < self.deadline and time.monotonic() < self.monotonic_deadline)
        value = strict_json(raw)
        fields(value, {"qualification_id", "flow_id", "probe"})
        need(value == {"qualification_id": self.identifier, "flow_id": self.flow_id, "probe": "reachability-v1"})
        self.done = True
        return {"status": "PROBE_OK"}


def prepare_receiver(receipt, directory, *, probe=False):
    # Receipt must arrive via parent-authenticated runner artifact, not from
    # an unknown endpoint. No private key or account/code fields admitted.
    fields(receipt, {"qualification_id", "flow_id", "source", "ops_sha", "evidence_class", "client_certificate", "client_sha256", "expires_at_ms"})
    need(receipt["evidence_class"] == ("mtls-probe-prepare" if probe else "native-core-auth-prepare"))
    need(receipt["source"] == "17f5d76dc043d7d8117f1e99458a9a0c9255354b" and re.fullmatch(r"[a-f0-9]{40}", receipt["ops_sha"]))
    identifier, flow_id = qualification(receipt["qualification_id"]), flow(receipt["flow_id"])
    lifetime(receipt["expires_at_ms"], 300_000 if probe else MAX_LIFE_MS)
    need(fingerprint(receipt["client_certificate"]) == receipt["client_sha256"])
    directory = private_directory(directory, create=True)
    public = certificate(directory, "server", PARENT_IP)
    config = {"qualification_id": identifier, "flow_id": flow_id, "host": PARENT_IP, "port": 49152 + secrets.randbelow(16384),
              "server_certificate": public["certificate"], "server_sha256": public["sha256"], "client_sha256": receipt["client_sha256"], "expires_at_ms": receipt["expires_at_ms"]}
    try:
        (directory / "purpose.json").write_text(json.dumps({"purpose": "probe" if probe else "auth"}))
        (directory / "purpose.json").chmod(0o600)
        (directory / "client.pem").write_text(receipt["client_certificate"])
        (directory / "client.pem").chmod(0o600)
        (directory / "transport.json").write_text(json.dumps(config))
        (directory / "transport.json").chmod(0o600)
        # A task-only disposal child covers abandoned preparation too. It has
        # no listener, sender, provider, generic path operation or remote API.
        child = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "expire", "--directory", str(directory)],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        (directory / "disposal.json").write_text(json.dumps({"pid": child.pid, "starttime": process_start(child.pid)}))
        (directory / "disposal.json").chmod(0o600)
        return config
    except BaseException:
        erase_keys(directory, "server")
        for name in ("client.pem", "transport.json"):
            (directory / name).unlink(missing_ok=True)
        raise BridgeRefused("BLOCKED_BRIDGE_PREPARE") from None


def process_start(pid):
    try:
        return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19]
    except OSError:
        return None


def stop_disposal(directory):
    receipt = Path(directory) / "disposal.json"
    if receipt.exists():
        saved = json.loads(receipt.read_text())
        if saved["starttime"] is not None and process_start(saved["pid"]) == saved["starttime"]:
            fd = os.pidfd_open(saved["pid"])
            try:
                need(process_start(saved["pid"]) == saved["starttime"])
                signal.pidfd_send_signal(fd, signal.SIGTERM)
            finally:
                os.close(fd)
        receipt.unlink(missing_ok=True)


def expire_preparation(directory):
    directory = private_directory(directory)
    try:
        config = json.loads((directory / "transport.json").read_text())
        validate_transport(config, config["qualification_id"], config["flow_id"])
        end = time.monotonic() + min(900, (config["expires_at_ms"] - now_ms()) / 1000)
        while time.monotonic() < end and now_ms() < config["expires_at_ms"]:
            time.sleep(min(1, max(.01, end - time.monotonic())))
    finally:
        erase_keys(directory, "server")
        for name in ("client.pem", "transport.json", "disposal.json"):
            (directory / name).unlink(missing_ok=True)


def serve_receiver(directory, *, probe=False):
    directory = private_directory(directory)
    purpose = json.loads((directory / "purpose.json").read_text()) if (directory / "purpose.json").exists() else {"purpose": "auth"}
    need(purpose == {"purpose": "probe" if probe else "auth"})
    server = None
    try:
        config = json.loads((directory / "transport.json").read_text())
        validate_transport(config, config["qualification_id"], config["flow_id"])
        client = (directory / "client.pem").read_text()
        need(fingerprint(client) == config["client_sha256"])
        state = ProbeReceiverState(config["qualification_id"], config["flow_id"], config["client_sha256"], config["expires_at_ms"]) if probe else ReceiverState(config["qualification_id"], config["flow_id"], config["client_sha256"], config["expires_at_ms"], send_home)
        server = QuietServer((PARENT_IP, config["port"]), server_context(directory, client), state)
        print(json.dumps({"status": "listening", "qualification_id": config["qualification_id"]}), flush=True)
        while not state.done and now_ms() < state.deadline and time.monotonic() < state.monotonic_deadline:
            server.handle_request()  # bounded TLS/body timeouts; no CI query
    finally:
        if server:
            server.server_close()
        erase_keys(directory, "server")
        (directory / "client.pem").unlink(missing_ok=True)
        (directory / "transport.json").unlink(missing_ok=True)
        stop_disposal(directory)
    need(state.done and not state.failed)
    if probe:
        erased = all(not (directory / name).exists() and not (directory / name).is_symlink() for name in ("server.key", "server.pem", "client.pem", "transport.json"))
        need(erased, "BLOCKED_PROBE_CLEANUP")
        return {"result": "PROBE_OK", "keys_erased": True}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("command", choices=("prepare", "serve", "prepare-probe", "serve-probe", "selftest", "expire"))
    ap.add_argument("--directory")
    ap.add_argument("--client-receipt")
    args = ap.parse_args()
    if args.command == "selftest":
        # Test-only command cannot select a LAN address or real sender.
        import unittest
        suite = unittest.defaultTestLoader.discover(str(Path(__file__).parent / "tests"), pattern="test_device_bridge.py")
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        need(result.wasSuccessful())
    elif args.command in ("prepare", "prepare-probe"):
        need(not os.environ.get("GITHUB_ACTIONS") and not Path.cwd().is_relative_to(Path(__file__).resolve().parents[2]))
        need(args.directory and args.client_receipt)
        print(json.dumps(prepare_receiver(json.loads(Path(args.client_receipt).read_text()), Path(args.directory), probe=args.command == "prepare-probe")))
    elif args.command == "expire":
        need(args.directory and not args.client_receipt)
        def dispose(signum, frame):
            raise BridgeRefused("BLOCKED_BRIDGE_CANCELLED")
        signal.signal(signal.SIGTERM, dispose)
        signal.signal(signal.SIGINT, dispose)
        expire_preparation(Path(args.directory))
    else:
        need(not os.environ.get("GITHUB_ACTIONS") and not Path.cwd().is_relative_to(Path(__file__).resolve().parents[2]))
        need(args.directory and not args.client_receipt)
        def stop(signum, frame):
            raise BridgeRefused("BLOCKED_BRIDGE_CANCELLED")
        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        signal.signal(signal.SIGALRM, stop)
        signal.alarm(900)
        try:
            result = serve_receiver(Path(args.directory), probe=args.command == "serve-probe")
            if result is not None:
                print(json.dumps(result))
        finally:
            signal.alarm(0)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        from g3_diagnostics import exception_reason
        print(json.dumps({"status": "BLOCKED_BRIDGE", "reason": exception_reason(error, "BLOCKED_BRIDGE_INPUT_OR_STATE")}))
        sys.exit(2)

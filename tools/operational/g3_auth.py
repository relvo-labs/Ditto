"""Fixed fresh realm + Core-managed device flow. No live auth in local tests.

Only the real CLI constructs NativeCore. TEST ONLY adapters may exercise the
protocol but never produce a launch-admissible native receipt. Device replies
remain memory-only; every diagnostic and receipt uses closed safe states.
"""
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import signal
import socket
import subprocess
import time

import g3_ops as ops
import g3_device_bridge as bridge

MODEL, EFFORT = "gpt-6.1-sol", "high"
PROVIDER = {"provider": "codex-app-server"}
STATES = {"prepared", "starting", "awaiting_browser", "login_complete", "verified", "blocked", "needs_human"}


def realm_path(identifier, home=Path("/home/neil")):
    bridge.qualification(identifier)
    path = home / ".cache/ditto" / ("g3-auth-q" + identifier)
    ops.require(path == path.resolve() and not path.is_symlink(), "BLOCKED_REALM_ALIAS")
    ops.require(not ops.NORMAL.resolve().is_relative_to(path), "BLOCKED_NORMAL_STORE_ALIAS")
    return path


def realm_guard(realm, normal=ops.NORMAL):
    ops.require(realm == realm.resolve(), "BLOCKED_REALM_ALIAS")
    for suffix in ("data", "state", "cache", "state/agent", "state/agent/backend/home", "state/agent/backend/codex"):
        path = realm / suffix
        ops.require(path == path.resolve(), "BLOCKED_REALM_ALIAS")
    db = realm / "data/core.db"
    ops.require(db.is_file() and db.stat().st_nlink == 1 and db == db.resolve(), "BLOCKED_REALM_DATABASE_ALIAS")
    ops.require(not db.samefile(normal) and ops.schema(db) == 5, "BLOCKED_REALM_SCHEMA_OR_NORMAL_ALIAS")
    ops.require(not (realm / "state/agent/backend/codex/auth.json").exists(), "BLOCKED_PLAINTEXT_AUTH")


def status_guard(value):
    ops.require(type(value) is dict and value.get("available") is True and value.get("provider") == "codex-app-server" and type(value.get("authenticated")) is bool,
                "BLOCKED_PROVIDER_METHOD_OR_STATUS")
    # Native pinned CodexBackend.status authenticates only identity.type==
    # chatgpt; the fixture Core has NO test-provider flag or API-key input.
    return value["authenticated"]


def model_guard(value):
    matches = [m for m in value.get("models", []) if m.get("id") == MODEL and EFFORT in m.get("reasoning_efforts", [])]
    ops.require(len(matches) == 1, "BLOCKED_REQUIRED_MODEL_OR_EFFORT")


def probe_guard(turn, trace, events):
    ops.require(turn.get("state") == "succeeded" and turn.get("tool_calls") == 0 and trace.get("tools") == [], "BLOCKED_MINIMAL_PROBE_TOOLS_OR_RESULT")
    selected = [e["data"] for e in events.get("events", []) if e.get("type") == "model/selection"]
    ops.require(len(selected) == 1 and selected[0].get("model") == MODEL and selected[0].get("provider") == "codex-app-server", "BLOCKED_MINIMAL_PROBE_MODEL")
    ops.require(not any(e.get("type") in ("tool/call", "tool/result", "tool/intent") for e in events.get("events", [])), "BLOCKED_MINIMAL_PROBE_TOOLS_OR_RESULT")


def core_contract(root, realm, identifier):
    """Commands are derived only from pinned source/native paths; no input spec."""
    candidate = root / "candidate"
    node = Path("/home/neil/.nvm/versions/node/v22.23.2/bin/node")
    runtime = ops.RUNTIME / ("ditto-g3-auth-q" + identifier)
    argv = [str(candidate / "target/release/ditto-core"), "serve", "--compositor", "fixture",
            "--builtin-packages", str(candidate / "target/ditto-packages-verification"),
            "--agent", f"agent 0.3.0 {node} {candidate}/packages/agent-runtime/dist/ditto-agentd.mjs",
            "--agent-backend", f"codex-app-server 0.160.0 {ops.CODEX_SHA} {ops.CODEX}",
            "--launch", f"dittoctl 0.2.0 {node} {candidate}/tests/g1/lib/relay.mjs {runtime}/relay.sock"]
    env = dict(ops.Host(root).env, DITTO_DATA_DIR=str(realm), DITTO_RUNTIME_DIR=str(runtime), DITTO_SYSTEM="none",
               DITTO_REQUIRE_QUOTA="1", DITTO_LAUNCH_SCOPE_PREFIX="ditto-g3-auth-q" + identifier)
    return argv, env, runtime


class NativeCore:
    def __init__(self, root, realm, identifier):
        self.root, self.realm, self.identifier = root, realm, identifier
        self.argv, self.env, self.runtime = core_contract(root, realm, identifier)
        self.child = None
        ops.require(self.runtime == self.runtime.resolve(), "BLOCKED_AUTH_RUNTIME_ALIAS")
        self.runtime.mkdir(mode=0o700, exist_ok=True)
        ops.require(self.runtime.stat().st_mode & 0o777 == 0o700 and not any((self.runtime / n).exists() for n in ("core.sock", "relay.sock")), "BLOCKED_AUTH_RUNTIME_IN_USE")

    def __enter__(self):
        self.child = subprocess.Popen(self.argv, cwd=self.root / "candidate", env=self.env,
                                      stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        self.saved = ops.witness(self.child.pid)
        state = ops.read(self.root / "auth-state.json")
        state["core_witness"] = self.saved
        ops.write(self.root / "auth-state.json", state)
        try:
            end = time.monotonic() + 30
            while time.monotonic() < end:
                ops.require(self.child.poll() is None, "BLOCKED_NATIVE_CORE_START")
                if (self.runtime / "relay.sock").is_socket():
                    return self
                time.sleep(.1)
            raise ops.Refused("BLOCKED_NATIVE_CORE_START")
        except BaseException:
            self.stop()
            raise

    def call(self, method, params=None, timeout=20):
        # Only a task-owned Unix socket. No shell, provider body, or code in
        # argv, file, journal, exceptions or Agent transcript.
        with socket.socket(socket.AF_UNIX) as sock:
            sock.settimeout(timeout)
            sock.connect(str(self.runtime / "relay.sock"))
            sock.sendall(json.dumps({"method": method, "params": params or {}}).encode() + b"\n")
            raw = b""
            while b"\n" not in raw:
                part = sock.recv(65536)
                ops.require(part and len(raw) + len(part) <= 1024 * 1024, "BLOCKED_NATIVE_RPC_SIZE_OR_DISCONNECT")
                raw += part
        try:
            reply = json.loads(raw.split(b"\n", 1)[0])
            ops.require("error" not in reply and "result" in reply, "BLOCKED_NATIVE_MANAGED_API")
            return reply["result"]
        except (ValueError, TypeError):
            raise ops.Refused("BLOCKED_NATIVE_MANAGED_API") from None

    def ready(self):
        self.call("agent.runtime.ensure")
        end = time.monotonic() + 30
        while time.monotonic() < end:
            runtime = self.call("agent.runtime.get")
            if runtime.get("phase") == "ready":
                ops.require(runtime.get("isolation_verified") is True, "BLOCKED_NATIVE_BACKEND_BOUNDARY")
                pid = runtime["backend_pid"]
                ops.require(Path(f"/proc/{pid}/exe").resolve(strict=True) == ops.CODEX and ops.sha(ops.CODEX) == ops.CODEX_SHA, "BLOCKED_NATIVE_BACKEND_BINARY")
                entries = Path(f"/proc/{pid}/environ").read_bytes().split(b"\0")
                for name, path in {"HOME": self.realm / "state/agent/backend/home", "CODEX_HOME": self.realm / "state/agent/backend/codex"}.items():
                    ops.require((name + "=" + str(path)).encode() in entries, "BLOCKED_NATIVE_AUTH_PATH")
                args = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
                ops.require(b'cli_auth_credentials_store="keyring"' in args and b"--strict-config" in args and not any(b"ditto_test" in a for a in args), "BLOCKED_NATIVE_AUTH_METHOD")
                group = next(x.split("::", 1)[1] for x in Path(f"/proc/{pid}/cgroup").read_text().splitlines() if x.startswith("0::"))
                ops.require(("ditto-g3-auth-q" + self.identifier + "-agent-backend.scope") in group, "BLOCKED_NATIVE_BACKEND_SCOPE")
                cgroup = Path("/sys/fs/cgroup") / group.lstrip("/")
                limits = {n: (cgroup / n).read_text().strip() for n in ("memory.max", "cpu.max", "pids.max", "memory.swap.max")}
                cpu = limits["cpu.max"].split()
                ops.require(limits["memory.max"] == "1073741824" and limits["pids.max"] == "256" and cpu[0] != "max" and int(cpu[0]) == 2 * int(cpu[1]), "BLOCKED_NATIVE_BACKEND_QUOTA")
                realm_guard(self.realm)
                return {"backend_witness": ops.witness(pid), "limits": limits, "isolation_verified": True}
            ops.require(runtime.get("phase") != "failed", "BLOCKED_NATIVE_BACKEND_START")
            time.sleep(.2)
        raise ops.Refused("BLOCKED_NATIVE_BACKEND_START")

    def stop(self):
        try:
            self.call("agent.runtime.stop", timeout=5)
        except Exception:
            pass
        # Stop only this realm's known, prefix-bound child scopes. This also
        # covers abrupt Core death; no normal desktop/runner unit is touched.
        stop_scopes(self.root, self.identifier)
        if self.child and self.child.poll() is None:
            self.child.terminate()
            try:
                self.child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.child.kill()
                self.child.wait(timeout=5)
        for name in ("relay.sock", "core.sock"):
            (self.runtime / name).unlink(missing_ok=True)
        # Core may have other task-only runtime state: preserve it privately.

    def __exit__(self, *args):
        self.stop()


def stop_scopes(root, identifier):
    host = ops.Host(root)
    for kind in ("agent", "agent-backend", "dittoctl"):
        unit = "ditto-g3-auth-q" + identifier + "-" + kind + ".scope"
        host.system("stop", unit, check=False)
        group = host.system("show", unit, "-p", "ControlGroup", "--value", check=False)
        if group:
            procs = Path("/sys/fs/cgroup") / group.lstrip("/") / "cgroup.procs"
            ops.require(not procs.exists() or not procs.read_text().strip(), "BLOCKED_AUTH_SCOPE_CLEANUP")


def prepare(root, host):
    built = ops.verify_stage(root)
    identifier = root.name[1:]
    ops.require(not (root / "auth-state.json").exists(), "BLOCKED_AUTH_SINGLE_USE")
    before = host.normal()
    ops.require(ops.sha(ops.CODEX) == ops.CODEX_SHA, "BLOCKED_PINNED_MANAGED_API_BINARY")
    ops.require(host.command(["busctl", "--user", "get-property", "org.freedesktop.secrets", "/org/freedesktop/secrets/collection/login", "org.freedesktop.Secret.Collection", "Locked"]).stdout.strip() == "b false", "BLOCKED_KEYRING_LOCKED")
    realm = realm_path(identifier)
    realm.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    realm.mkdir(mode=0o700, exist_ok=False)
    directory = root / "auth-bridge"
    directory.mkdir(mode=0o700)
    state = {"source": ops.SOURCE, "ops_sha": built["ops_sha"], "qualification_id": identifier, "flow_id": secrets.token_hex(16),
             "realm": str(realm), "backend_home": str(realm / "state/agent/backend/home"), "codex_home": str(realm / "state/agent/backend/codex"),
             "status": "starting", "login_complete": False, "model_verified": False, "native_stopped": False, "normal_before": before}
    ops.write(root / "auth-state.json", state)
    try:
        # No-auth controls against the exact pinned binary. No credential
        # discovery and no direct login CLI (which writes login diagnostics).
        empty = root / "auth-help"
        empty.mkdir(mode=0o700)
        env = dict(host.env, HOME=str(empty), CODEX_HOME=str(empty))
        version = host.command([str(ops.CODEX), "--version"], env=env).stdout.strip()
        help_text = host.command([str(ops.CODEX), "app-server", "--help"], env=env).stdout
        ops.require(version == "codex-cli 0.160.0" and "--listen" in help_text, "BLOCKED_PINNED_MANAGED_API_HELP")
        state["pinned_help_sha256"] = hashlib.sha256(help_text.encode()).hexdigest()
        with NativeCore(root, realm, identifier) as core:
            state.update(ops.read(root / "auth-state.json"))
            settings = core.call("agent.settings.describe")
            settings.pop("_meta", None)
            settings.update(provider="codex-app-server", model=MODEL, reasoning_effort=EFFORT, enabled=False)
            core.call("agent.settings.patch", {"expected_revision": settings["revision"], "settings": settings})
            core.call("desktop.profiles.get")
            realm_guard(realm)
        ops.require(host.normal() == before, "BLOCKED_NORMAL_PROVENANCE_CHANGED")
        cert = bridge.certificate(directory, "client", "10.0.1.234")
        state.update(status="prepared", initialized_schema=ops.schema(realm / "data/core.db"), native_stopped=True,
                     core_binary_sha256=ops.sha(root / "candidate/target/release/ditto-core"), pinned_help_checked=True)
        ops.write(root / "auth-state.json", state)
        receipt = {"qualification_id": identifier, "flow_id": state["flow_id"], "source": ops.SOURCE, "ops_sha": built["ops_sha"],
                   "evidence_class": "native-core-auth-prepare", "client_certificate": cert["certificate"], "client_sha256": cert["sha256"], "expires_at_ms": bridge.now_ms() + bridge.MAX_LIFE_MS}
        ops.write(root / "auth-prepare.json", receipt)
        # Preparation itself owns a deadline, even if parent never starts
        # login. This timer performs cleanup only; it never queries Actions.
        helper = root / "ops/g3_ops.py"
        host.command(["systemd-run", "--user", "--unit=ditto-g3-auth-lease-q" + identifier, "--on-active=890", "--timer-property=AccuracySec=1",
                      "--property=Type=oneshot", "--property=RuntimeMaxSec=180", "--property=StandardOutput=null", "--property=StandardError=null",
                      "/usr/bin/python3", str(helper), "auth_cleanup", "--id", identifier])
        return receipt
    except Exception:
        state.update(status="blocked", reason="BLOCKED_AUTH_PREPARE")
        ops.write(root / "auth-state.json", state)
        bridge.erase_keys(directory, "client")
        raise ops.Refused("BLOCKED_AUTH_PREPARE") from None


def minimal_probe(core):
    original = core.call("agent.settings.describe")
    settings = {k: v for k, v in original.items() if k != "_meta"}
    settings.update(enabled=True, provider="codex-app-server", model=MODEL, reasoning_effort=EFFORT, turn_timeout_ms=30000, max_tool_calls=1, approval_mode="never")
    applied = core.call("agent.settings.patch", {"expected_revision": settings["revision"], "settings": settings})
    ops.require(applied.get("model") == MODEL and applied.get("reasoning_effort") == EFFORT, "BLOCKED_MINIMAL_PROBE_SETTINGS")
    before = core.call("desktop.profiles.get")
    session = core.call("agent.sessions.create", {"title": "G3 isolated subscription verification", "idempotency_key": "auth-probe"})
    turn = core.call("agent.turns.submit", {"session_id": session["session_id"], "client_message_id": "auth-probe-one",
                                         "text": "Reply only OK. Do not use tools, read files, or modify desktop state."})
    end = time.monotonic() + 45
    while time.monotonic() < end:
        finished = core.call("agent.turns.get", {"turn_id": turn["turn_id"]})
        if finished.get("state") in ("succeeded", "failed", "cancelled", "unknown", "partial"):
            break
        time.sleep(.25)
    else:
        core.call("agent.turns.cancel", {"turn_id": turn["turn_id"]})
        raise ops.Refused("BLOCKED_MINIMAL_PROBE_DEADLINE")
    trace = core.call("agent.turns.trace", {"turn_id": turn["turn_id"]})
    events = core.call("agent.sessions.read", {"session_id": session["session_id"], "offset": 0, "limit": 100})
    probe_guard(finished, trace, events)
    selection = next(e["data"] for e in events["events"] if e["type"] == "model/selection")
    ops.require(selection.get("settings_revision") == applied.get("revision"), "BLOCKED_MINIMAL_PROBE_SETTINGS_REVISION")
    after = core.call("desktop.profiles.get")
    ops.require(before["revision"]["document_sha256"] == after["revision"]["document_sha256"], "BLOCKED_MINIMAL_PROBE_DESKTOP_CHANGE")
    # Keep the requested model/high for physical acceptance, restore the
    # original budgets/enabled flag via Core (not a DB-row edit).
    settings = {k: v for k, v in original.items() if k != "_meta"}
    settings["revision"] = core.call("agent.settings.describe")["revision"]
    core.call("agent.settings.patch", {"expected_revision": settings["revision"], "settings": settings})
    return {"model": MODEL, "effort": EFFORT, "tool_calls_observed": 0, "no_tool_enforcement": "observed_only; prompt plus existing Core authorization/budgets", "request_count": 1}


def device_flow(core, transport, receipt, safe_update):
    """Secret-bearing login values live only in this function's memory."""
    login = None
    try:
        safe_update(native_runtime=core.ready())
        ops.require(not status_guard(core.call("agent.providers.status", PROVIDER)), "BLOCKED_FRESH_REALM_ALREADY_AUTHENTICATED")
        login = core.call("agent.providers.login", PROVIDER)
        ops.require(type(login) is dict and set(login) == {"login_id", "auth_url", "user_code", "expires_at_ms"} and type(login["login_id"]) is str and 0 < len(login["login_id"]) <= 128,
                    "BLOCKED_DEVICE_LOGIN_METHOD")
        payload = {"qualification_id": receipt["qualification_id"], "flow_id": receipt["flow_id"],
                   "auth_url": login["auth_url"], "user_code": login["user_code"], "expires_at_ms": login["expires_at_ms"]}
        bridge.login_payload(payload, receipt["qualification_id"], receipt["flow_id"])
        ops.require(payload["expires_at_ms"] <= receipt["expires_at_ms"], "BLOCKED_DEVICE_LOGIN_EXPIRY")
        transport.post("/login_code", payload)
        del payload
        safe_update(status="awaiting_browser")
        # Managed API offers no public login event stream through the relay;
        # bounded local status polling retains the original provider process.
        while bridge.now_ms() < login["expires_at_ms"] - 60_000:
            status = core.call("agent.providers.status", PROVIDER)
            if status_guard(status):
                safe_update(status="login_complete", login_complete=True)
                transport.post("/status", {"qualification_id": receipt["qualification_id"], "flow_id": receipt["flow_id"], "status": "login_complete"})
                model_guard(status)
                proof = minimal_probe(core)
                return proof
            time.sleep(3)
        raise ops.Refused("BLOCKED_DEVICE_LOGIN_EXPIRED")
    except BaseException as error:
        if type(login) is dict and type(login.get("login_id")) is str:
            try:
                core.call("agent.providers.cancel_login", {**PROVIDER, "login_id": login["login_id"]}, timeout=5)
            except Exception:
                pass  # stopping the exact backend/service is also mandatory
        try:
            core.call("agent.runtime.stop", timeout=5)
        except Exception:
            pass
        reason = str(error) if isinstance(error, ops.Refused) and str(error).startswith("BLOCKED_") else "BLOCKED_DEVICE_LOGIN_OR_PROBE"
        raise ops.Refused(reason) from None


def supervisor(root, host):
    built = ops.verify_stage(root)
    state = ops.read(root / "auth-state.json")
    receipt = ops.read(root / "auth-prepare.json")
    transport = bridge.Client(root / "auth-bridge", ops.read(root / "auth-transport.json"), root.name[1:], receipt["flow_id"])
    realm = realm_path(root.name[1:])
    ops.require(state["realm"] == str(realm) and state["ops_sha"] == built["ops_sha"] and state["status"] == "starting", "BLOCKED_AUTH_BINDING")
    def update(**safe):
        state.update(safe)
        ops.write(root / "auth-state.json", state)
    try:
        # Remove only prior, stopped initialization sockets before restart.
        runtime = ops.RUNTIME / ("ditto-g3-auth-q" + root.name[1:])
        if runtime.exists():
            ops.require(runtime == runtime.resolve(), "BLOCKED_AUTH_RUNTIME_ALIAS")
            ops.require(not any((runtime / name).exists() for name in ("relay.sock", "core.sock")), "BLOCKED_AUTH_RUNTIME_IN_USE")
        with NativeCore(root, realm, root.name[1:]) as core:
            state.update(ops.read(root / "auth-state.json"))
            proof = device_flow(core, transport, receipt, update)
            realm_guard(realm)
        ops.require(host.normal() == state["normal_before"], "BLOCKED_NORMAL_PROVENANCE_CHANGED")
        update(status="verified", model_verified=True, native_stopped=True, auth_method="chatgpt_subscription", probe=proof,
               database_sha256=ops.sha(realm / "data/core.db"), evidence_class="native-core-auth-verified")
        transport.post("/status", {"qualification_id": receipt["qualification_id"], "flow_id": receipt["flow_id"], "status": "verified"})
    except BaseException as error:
        reason = str(error) if isinstance(error, ops.Refused) and str(error).startswith("BLOCKED_") else "BLOCKED_AUTH_OR_MODEL_VERIFICATION"
        update(status="blocked", reason=reason)  # retain an actual probe PASS
        try:
            transport.post("/status", {"qualification_id": receipt["qualification_id"], "flow_id": receipt["flow_id"], "status": "blocked"})
        except Exception:
            pass
    finally:
        cleanup(root, host)


def start_login(root, host, public_config):
    ops.verify_stage(root)
    state = ops.read(root / "auth-state.json")
    receipt = ops.read(root / "auth-prepare.json")
    ops.require(state["status"] == "prepared" and state["native_stopped"] is True, "BLOCKED_AUTH_SINGLE_USE")
    bridge.validate_transport(public_config, root.name[1:], receipt["flow_id"])
    ops.require(public_config["client_sha256"] == receipt["client_sha256"] and public_config["expires_at_ms"] == receipt["expires_at_ms"], "BLOCKED_AUTH_TRANSPORT_BINDING")
    ops.write(root / "auth-transport.json", public_config)  # public cert metadata only
    state.update(status="starting", native_stopped=False)
    ops.write(root / "auth-state.json", state)
    helper = root / "ops/g3_ops.py"
    host.command(["systemd-run", "--user", "--unit=ditto-g3-auth-q" + root.name[1:], "--property=Type=exec", "--property=Restart=no",
                  "--property=RuntimeMaxSec=900", "--property=TimeoutStopSec=180", "--property=KillMode=control-group", "--property=UMask=0077",
                  "--property=LimitCORE=0", "--property=StandardOutput=null", "--property=StandardError=null", "--property=MemoryMax=1G", "--property=TasksMax=128",
                  "--property=ExecStopPost=/usr/bin/python3 " + str(helper) + " auth_cleanup --id " + root.name[1:],
                  "/usr/bin/python3", str(helper), "auth_supervise", "--id", root.name[1:]])


def cleanup(root, host):
    state = ops.read(root / "auth-state.json")
    errors = []
    # Certificate disposal cannot be delayed by a stalled native readback.
    bridge.erase_keys(root / "auth-bridge", "client")
    (root / "auth-transport.json").unlink(missing_ok=True)
    try:
        host.system("stop", "ditto-g3-auth-lease-q" + root.name[1:] + ".timer", check=False)
    except Exception:
        errors.append("prepare_deadline_timer")
    try:
        stop_scopes(root, root.name[1:])
        saved = state.get("core_witness")
        current = ops.witness(saved["pid"]) if saved else None
        if current:
            ops.require(current["starttime"] == saved["starttime"], "BLOCKED_AUTH_PID_REUSE")
            ops.require(Path(f"/proc/{saved['pid']}/exe").resolve() == root / "candidate/target/release/ditto-core", "BLOCKED_AUTH_CLEANUP_IDENTITY")
            fd = os.pidfd_open(saved["pid"])
            try:
                again = ops.witness(saved["pid"])
                ops.require(again and again["starttime"] == saved["starttime"], "BLOCKED_AUTH_PID_REUSE")
                signal.pidfd_send_signal(fd, signal.SIGTERM)
            finally:
                os.close(fd)
            end = time.monotonic() + 5
            while ops.witness(saved["pid"]) is not None and time.monotonic() < end:
                time.sleep(.1)
            ops.require(ops.witness(saved["pid"]) is None, "BLOCKED_AUTH_CORE_STILL_RUNNING")
        backend = state.get("native_runtime", {}).get("backend_witness")
        if backend:
            ops.require(ops.witness(backend["pid"]) is None, "BLOCKED_AUTH_BACKEND_STILL_RUNNING")
        ops.require(host.normal() == state["normal_before"], "BLOCKED_NORMAL_PROVENANCE_CHANGED")
    except Exception:
        errors.append("native_or_normal_cleanup")
    if state.get("status") not in ("verified", "blocked"):
        state.update(status="blocked", reason="BLOCKED_AUTH_INTERRUPTED_OR_EXPIRED")
    state.update(native_stopped=not errors, cleanup_errors=errors)
    if errors:
        state.update(status="needs_human", model_verified=False)
    ops.write(root / "auth-state.json", state)
    return state


def stopped_guard(root, state, host=None):
    ops.require(state.get("native_stopped") is True and not state.get("cleanup_errors"), "BLOCKED_AUTH_CLEANUP")
    ops.require(ops.witness(state["core_witness"]["pid"]) is None, "BLOCKED_AUTH_CORE_STILL_RUNNING")
    if host:
        ops.require(host.system("is-active", "ditto-g3-auth-q" + root.name[1:], check=False) in ("inactive", "failed", "unknown"), "BLOCKED_AUTH_SERVICE_STILL_RUNNING")


def verified_realm(root, host=None):
    built = ops.verify_stage(root)
    state = ops.read(root / "auth-state.json")
    realm = realm_path(root.name[1:])
    ops.require(not state.get("test_only") and state.get("evidence_class") == "native-core-auth-verified", "BLOCKED_NON_NATIVE_AUTH_RECEIPT")
    ops.require(state["source"] == ops.SOURCE and state["ops_sha"] == built["ops_sha"] and state["qualification_id"] == root.name[1:] and state["realm"] == str(realm)
                and state["codex_home"] == str(realm / "state/agent/backend/codex"), "BLOCKED_AUTH_BINDING")
    ops.require(state["status"] == "verified" and state["login_complete"] is True and state["model_verified"] is True and state["native_stopped"] is True
                and not state.get("cleanup_errors") and state.get("auth_method") == "chatgpt_subscription", "BLOCKED_AUTH_OR_MODEL_VERIFICATION")
    proof = state["probe"]
    ops.require(proof["model"] == MODEL and proof["effort"] == EFFORT and proof["tool_calls_observed"] == 0 and proof["request_count"] == 1, "BLOCKED_MINIMAL_PROBE_RECEIPT")
    ops.require(state["database_sha256"] == ops.sha(realm / "data/core.db"), "BLOCKED_AUTH_DATABASE_CHANGED")
    realm_guard(realm)
    with closing(ops.sqlite3.connect((realm / "data/core.db").as_uri() + "?mode=ro", uri=True)) as conn:
        prefs = json.loads(conn.execute("SELECT settings_json FROM agent_preferences WHERE singleton=1").fetchone()[0])
        ops.require(prefs.get("provider") == "codex-app-server" and prefs.get("model") == MODEL and prefs.get("reasoning_effort") == EFFORT, "BLOCKED_AUTH_PREFERENCES_CHANGED")
        ops.require(conn.execute("SELECT count(*) FROM agent_turns WHERE state IN ('queued','running','awaiting_approval','cancelling')").fetchone()[0] == 0, "BLOCKED_AUTH_PENDING_TURNS")
    stopped_guard(root, state, host)
    return realm


def public_status(root):
    state = ops.read(root / "auth-state.json")
    ops.require(state.get("status") in STATES, "BLOCKED_AUTH_UNKNOWN_STATE")
    return {"qualification_id": root.name[1:], "source": ops.SOURCE, "status": state["status"],
            "login_complete": state["login_complete"], "model_verified": state["model_verified"], "native_stopped": state["native_stopped"],
            "model": MODEL, "effort": EFFORT, "physical_success": False}

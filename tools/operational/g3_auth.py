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
import g3_diagnostics as diag

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


def record_failure(root, error, fallback):
    """Persist first closed cause before effects; cleanup has a separate field."""
    state = ops.read(root / "auth-state.json")
    if state.get("reason") is None:
        state["reason"] = diag.exception_reason(error, fallback)
    if isinstance(error, CleanupFailed):
        state["resource_errors"] = list(dict.fromkeys(state.get("resource_errors", []) + error.errors))
        state["status"] = "needs_human"
    ops.write(root / "auth-state.json", state)
    return diag.reason(state["reason"])


class NativeCore:
    def __init__(self, root, realm, identifier):
        self.root, self.realm, self.identifier = root, realm, identifier
        self.argv, self.env, self.runtime = core_contract(root, realm, identifier)
        self.child = None
        ops.require(self.runtime == self.runtime.resolve(), "BLOCKED_AUTH_RUNTIME_ALIAS")
        self.runtime.mkdir(mode=0o700, exist_ok=True)
        ops.require(self.runtime.stat().st_mode & 0o777 == 0o700 and not any((self.runtime / n).exists() for n in ("core.sock", "relay.sock")), "BLOCKED_AUTH_RUNTIME_IN_USE")

    def __enter__(self):
        try:
            self.child = subprocess.Popen(self.argv, cwd=self.root / "candidate", env=self.env,
                                          stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            self.saved = ops.witness(self.child.pid)
            state = ops.read(self.root / "auth-state.json")
            state["core_witness"] = self.saved
            ops.write(self.root / "auth-state.json", state)
            end = time.monotonic() + ops.bounded_timeout(30)
            while time.monotonic() < end:
                ops.require(self.child.poll() is None, "BLOCKED_NATIVE_CORE_START")
                if (self.runtime / "relay.sock").is_socket():
                    return self
                time.sleep(.1)
            raise ops.Refused("BLOCKED_NATIVE_CORE_START")
        except BaseException as error:
            reason = record_failure(self.root, error, "BLOCKED_NATIVE_CORE_START")
            try:
                self.stop()
            except CleanupFailed as cleanup_error:
                record_failure(self.root, cleanup_error, "BLOCKED_AUTH_CLEANUP")
            raise ops.Refused(reason) from None

    def call(self, method, params=None, timeout=20):
        # Only a task-owned Unix socket. No shell, provider body, or code in
        # argv, file, journal, exceptions or Agent transcript.
        end = time.monotonic() + ops.bounded_timeout(timeout)
        with socket.socket(socket.AF_UNIX) as sock:
            sock.settimeout(ops.bounded_timeout(max(0, end - time.monotonic())))
            sock.connect(str(self.runtime / "relay.sock"))
            sock.settimeout(ops.bounded_timeout(max(0, end - time.monotonic())))
            sock.sendall(json.dumps({"method": method, "params": params or {}}).encode() + b"\n")
            raw = b""
            while b"\n" not in raw:
                ops.require(time.monotonic() < end, "BLOCKED_NATIVE_RPC_DEADLINE")
                sock.settimeout(ops.bounded_timeout(end - time.monotonic()))
                part = sock.recv(65536)
                ops.require(part and len(raw) + len(part) <= 1024 * 1024, "BLOCKED_NATIVE_RPC_SIZE_OR_DISCONNECT")
                raw += part
        try:
            reply = json.loads(raw.split(b"\n", 1)[0])
            ops.require("error" not in reply and "result" in reply, "BLOCKED_DEVICE_LOGIN_PROVIDER" if method == "agent.providers.login" else "BLOCKED_NATIVE_MANAGED_API")
            return ops.core_result(reply["result"], "BLOCKED_DEVICE_LOGIN_METHOD" if method == "agent.providers.login" else "BLOCKED_NATIVE_MANAGED_API")
        except (ValueError, TypeError):
            raise ops.Refused("BLOCKED_NATIVE_MANAGED_API") from None

    def ready(self, *, for_revoke=False):
        runtime = ops.wait_ready(self.call, allow_draining=for_revoke)
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

    def stop(self):
        errors = []
        try:
            self.call("agent.runtime.stop", timeout=5)
        except Exception:
            errors.append("runtime_stop")
        try:
            errors.extend(stop_scopes(self.root, self.identifier) or [])
        except Exception:
            errors.append("scope_stop")
        # Popen owns its unreaped child; PID cannot be reused before wait.
        try:
            if self.child and self.child.poll() is None:
                self.child.terminate()
                try:
                    self.child.wait(timeout=ops.bounded_timeout(5))
                except subprocess.TimeoutExpired:
                    self.child.kill()
                    self.child.wait(timeout=ops.bounded_timeout(5))
        except Exception:
            errors.append("core_stop")
        try:
            errors.extend(scope_readbacks(self.root, self.identifier))
        except Exception:
            errors.append("scope_readback")
        try:
            ops.require(not self.child or self.child.poll() is not None, "BLOCKED_AUTH_CORE_STILL_RUNNING")
            for name in ("relay.sock", "core.sock"):
                (self.runtime / name).unlink(missing_ok=True)
        except Exception:
            errors.append("core_readback")
        if errors:
            raise CleanupFailed(errors)

    def __exit__(self, kind, error, traceback):
        if error is not None:
            record_failure(self.root, error, "BLOCKED_AUTH_OR_MODEL_VERIFICATION")
        try:
            self.stop()
        except CleanupFailed as cleanup_error:
            record_failure(self.root, cleanup_error, "BLOCKED_AUTH_CLEANUP")
            if error is None:
                raise
            # Returning false propagates the original failure, never stop's.
        return False


class CleanupFailed(ops.Refused):
    def __init__(self, errors):
        self.errors = errors
        super().__init__("BLOCKED_AUTH_CLEANUP")


def owned_units(identifier):
    bridge.qualification(identifier)
    return ["ditto-g3-auth-q" + identifier + "-" + kind + ".scope" for kind in ("agent", "agent-backend", "dittoctl")]


def scope_snapshot(host, unit):
    # Parse structured properties even when systemctl reports not-found with
    # nonzero status. Empty/error text alone never proves absence.
    result = host.command(["systemctl", "--user", "show", unit, "-p", "LoadState", "-p", "ActiveState", "-p", "ControlGroup", "--no-pager"], check=False)
    fields = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    ops.require(set(fields) == {"LoadState", "ActiveState", "ControlGroup"}, "BLOCKED_AUTH_SCOPE_READBACK")
    absent = fields["LoadState"] == "not-found"
    ops.require(result.returncode == 0 or absent, "BLOCKED_AUTH_SCOPE_READBACK")
    group = fields["ControlGroup"]
    if absent:
        ops.require(fields["ActiveState"] == "inactive" and not group, "BLOCKED_AUTH_SCOPE_ABSENCE_UNPROVED")
    if group:
        ops.require(group.startswith("/user.slice/user-1000.slice/user@1000.service/") and group.endswith("/" + unit), "BLOCKED_AUTH_SCOPE_IDENTITY")
        procs = Path("/sys/fs/cgroup") / group.lstrip("/") / "cgroup.procs"
        ops.require(not procs.exists() or not procs.read_text().strip(), "BLOCKED_AUTH_SCOPE_CLEANUP")
    ops.require(fields["ActiveState"] in ("inactive", "failed") and fields["LoadState"] in ("loaded", "not-found"), "BLOCKED_AUTH_SCOPE_STILL_ACTIVE")
    return absent


def scope_readbacks(root, identifier):
    host, errors = ops.Host(root), []
    for unit in owned_units(identifier):
        try:
            scope_snapshot(host, unit)
        except Exception as error:
            errors.append(unit + (":budget_exhausted" if isinstance(error, ops.Refused) and error.args == ("BLOCKED_AUTH_CLEANUP_BUDGET",) else ":readback"))
    return errors


def stop_scopes(root, identifier):
    host, errors = ops.Host(root), []
    # Each stop outcome has its own explicit final unit/process witness. A
    # reaped or never-created unit is idempotently clean; loaded stop failure
    # remains failure even when its cgroup happens to be empty.
    for unit in owned_units(identifier):
        failed = False
        try:
            failed = host.command(["systemctl", "--user", "stop", unit], check=False).returncode != 0
        except Exception:
            failed = True
        try:
            absent = scope_snapshot(host, unit)
            if failed and not absent:
                errors.append(unit + ":stop")
        except Exception as error:
            if failed:
                errors.append(unit + ":stop")
            errors.append(unit + (":budget_exhausted" if isinstance(error, ops.Refused) and error.args == ("BLOCKED_AUTH_CLEANUP_BUDGET",) else ":readback"))
    return errors


def stop_owned_core(root, saved):
    current = ops.witness(saved["pid"]) if saved else None
    if not current:
        return
    ops.require(current["starttime"] == saved["starttime"], "BLOCKED_AUTH_PID_REUSE")
    ops.require(Path(f"/proc/{saved['pid']}/exe").resolve() == root / "candidate/target/release/ditto-core", "BLOCKED_AUTH_CLEANUP_IDENTITY")
    fd = os.pidfd_open(saved["pid"])
    try:
        again = ops.witness(saved["pid"])
        ops.require(again and again["starttime"] == saved["starttime"], "BLOCKED_AUTH_PID_REUSE")
        signal.pidfd_send_signal(fd, signal.SIGTERM)
    finally:
        os.close(fd)
    end = time.monotonic() + ops.bounded_timeout(5)
    while ops.witness(saved["pid"]) is not None and time.monotonic() < end:
        time.sleep(ops.bounded_timeout(.1))
    ops.require(ops.witness(saved["pid"]) is None, "BLOCKED_AUTH_CORE_STILL_RUNNING")


def revoke(core, login=None):
    """Cancel pending, then logout and prove unauthenticated in sole realm.

    cancel:false and process exit never prove keyring revocation. Logout also
    clears the provider's pending flow. No normal/default backend is reachable.
    """
    core.ready(for_revoke=True)  # disabled old generation may still be draining
    if type(login) is dict and type(login.get("login_id")) is str:
        try:
            core.call("agent.providers.cancel_login", {**PROVIDER, "login_id": login["login_id"]}, timeout=5)
        except Exception:
            pass  # authoritative logout + status below must still succeed
    value = core.call("agent.providers.logout", PROVIDER, timeout=10)
    ops.require(value.get("completed") is True, "BLOCKED_AUTH_REVOCATION")
    ops.require(not status_guard(core.call("agent.providers.status", PROVIDER, timeout=10)), "BLOCKED_AUTH_REVOCATION")


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
             "status": "starting", "auth_lifecycle": "none", "login_complete": False, "model_verified": False, "native_stopped": False, "normal_before": before}
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
            settings = ops.core_result(core.call("agent.settings.describe"))
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
    except Exception as error:
        reason = record_failure(root, error, "BLOCKED_AUTH_PREPARE")
        try:
            bridge.erase_keys(directory, "client")
        except Exception:
            record_failure(root, CleanupFailed(["bridge_keys"]), "BLOCKED_AUTH_CLEANUP")
        state = ops.read(root / "auth-state.json")
        state["status"] = "needs_human" if state.get("resource_errors") else "blocked"
        ops.write(root / "auth-state.json", state)
        raise ops.Refused(reason) from None


def minimal_probe(core):
    original = ops.core_result(core.call("agent.settings.describe"))
    settings = dict(original)
    settings.update(enabled=True, provider="codex-app-server", model=MODEL, reasoning_effort=EFFORT, turn_timeout_ms=30000, max_tool_calls=1, approval_mode="never")
    turn = None
    original_failure = None
    try:
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
            raise ops.Refused("BLOCKED_MINIMAL_PROBE_DEADLINE")
        trace = core.call("agent.turns.trace", {"turn_id": turn["turn_id"]})
        events = core.call("agent.sessions.read", {"session_id": session["session_id"], "offset": 0, "limit": 100})
        probe_guard(finished, trace, events)
        selection = next(e["data"] for e in events["events"] if e["type"] == "model/selection")
        ops.require(selection.get("settings_revision") == applied.get("revision"), "BLOCKED_MINIMAL_PROBE_SETTINGS_REVISION")
        after = core.call("desktop.profiles.get")
        ops.require(before["revision"]["document_sha256"] == after["revision"]["document_sha256"], "BLOCKED_MINIMAL_PROBE_DESKTOP_CHANGE")
        return {"model": MODEL, "effort": EFFORT, "tool_calls_observed": 0, "no_tool_enforcement": "observed_only; prompt plus existing Core authorization/budgets", "request_count": 1}
    except BaseException as error:
        original_failure = error
        raise
    finally:
        cleanup_failed = False
        # Only the one synthetic turn; no broad session/global cancellation.
        if turn:
            try:
                current = core.call("agent.turns.get", {"turn_id": turn["turn_id"]})
                if current.get("state") not in ("succeeded", "failed", "cancelled", "unknown", "partial"):
                    core.call("agent.turns.cancel", {"turn_id": turn["turn_id"]})
                    end = time.monotonic() + 5
                    while time.monotonic() < end:
                        current = core.call("agent.turns.get", {"turn_id": turn["turn_id"]}, timeout=2)
                        if current.get("state") in ("succeeded", "failed", "cancelled", "unknown", "partial"):
                            break
                        time.sleep(.1)
                    else:
                        raise ops.Refused("BLOCKED_MINIMAL_PROBE_CANCEL")
            except Exception:
                cleanup_failed = True
        try:
            settings = ops.core_result(original)
            settings["revision"] = core.call("agent.settings.describe")["revision"]
            core.call("agent.settings.patch", {"expected_revision": settings["revision"], "settings": settings})
        except Exception:
            cleanup_failed = True
        if cleanup_failed and original_failure is None:
            raise ops.Refused("BLOCKED_MINIMAL_PROBE_CLEANUP")


def device_flow(core, transport, receipt, safe_update):
    """Secret-bearing login values live only in this function's memory."""
    login = None
    lifecycle = "unknown"
    try:
        safe_update(auth_lifecycle=lifecycle)
        safe_update(native_runtime=core.ready(), last_marker="native_ready")
        ops.require(not status_guard(core.call("agent.providers.status", PROVIDER)), "BLOCKED_FRESH_REALM_ALREADY_AUTHENTICATED")
        safe_update(last_marker="preauth_checked")
        safe_update(auth_lifecycle="pending", last_marker="login_requested")
        login = ops.core_result(core.call("agent.providers.login", PROVIDER), "BLOCKED_DEVICE_LOGIN_METHOD")
        ops.require(type(login) is dict and set(login) == {"login_id", "auth_url", "user_code", "expires_at_ms"} and type(login["login_id"]) is str and 0 < len(login["login_id"]) <= 128,
                    "BLOCKED_DEVICE_LOGIN_METHOD")
        payload = {"qualification_id": receipt["qualification_id"], "flow_id": receipt["flow_id"],
                   "auth_url": login["auth_url"], "user_code": login["user_code"], "expires_at_ms": login["expires_at_ms"]}
        bridge.login_payload(payload, receipt["qualification_id"], receipt["flow_id"])
        ops.require(payload["expires_at_ms"] <= receipt["expires_at_ms"], "BLOCKED_DEVICE_PAYLOAD_EXPIRY")
        safe_update(last_marker="payload_validated")
        transport.post("/login_code", payload)
        del payload
        safe_update(last_marker="code_forwarded")
        safe_update(status="awaiting_browser", last_marker="awaiting_browser")
        # Managed API offers no public login event stream through the relay;
        # bounded local status polling retains the original provider process.
        while bridge.now_ms() < login["expires_at_ms"] - 60_000:
            status = core.call("agent.providers.status", PROVIDER)
            if status_guard(status):
                safe_update(status="login_complete", login_complete=True, auth_lifecycle="completed", last_marker="login_complete")
                transport.post("/status", {"qualification_id": receipt["qualification_id"], "flow_id": receipt["flow_id"], "status": "login_complete"})
                model_guard(status)
                proof = minimal_probe(core)
                safe_update(last_marker="probe_done")
                return proof
            time.sleep(3)
        raise ops.Refused("BLOCKED_DEVICE_LOGIN_EXPIRED")
    except BaseException as error:
        reason = diag.exception_reason(error, "BLOCKED_DEVICE_LOGIN_OR_PROBE")
        safe_update(reason=reason)
        try:
            revoke(core, login)
            safe_update(auth_lifecycle="revoked")
        except BaseException:
            safe_update(auth_lifecycle="unknown", status="needs_human", revocation_error="BLOCKED_AUTH_REVOCATION")
        # Needed logout/readback happened before stopping the backend.
        try:
            core.call("agent.runtime.stop", timeout=5)
        except Exception:
            pass
        raise ops.Refused(reason) from None


def supervisor(root, host):
    state = ops.read(root / "auth-state.json")
    transport = receipt = None
    def update(**safe):
        # NativeCore may have recorded a start/exit failure independently.
        state.update(ops.read(root / "auth-state.json"))
        if "reason" in safe:
            if state.get("reason") is not None:
                safe.pop("reason")  # original first failure is sticky
            else:
                safe["reason"] = diag.reason(safe["reason"])
        if "last_marker" in safe:
            ops.require(safe["last_marker"] in diag.MARKERS, "BLOCKED_UNLISTED_REASON")
        state.update(safe)
        ops.write(root / "auth-state.json", state)
    try:
        update(last_marker="supervisor_started")
        built = ops.verify_stage(root)
        receipt = ops.read(root / "auth-prepare.json")
        transport = bridge.Client(root / "auth-bridge", ops.read(root / "auth-transport.json"), root.name[1:], receipt["flow_id"])
        update(last_marker="transport_ready")
        realm = realm_path(root.name[1:])
        ops.require(state["realm"] == str(realm) and state["ops_sha"] == built["ops_sha"] and state["status"] == "starting", "BLOCKED_AUTH_BINDING")
        # Remove only prior, stopped initialization sockets before restart.
        runtime = ops.RUNTIME / ("ditto-g3-auth-q" + root.name[1:])
        if runtime.exists():
            ops.require(runtime == runtime.resolve(), "BLOCKED_AUTH_RUNTIME_ALIAS")
            ops.require(not any((runtime / name).exists() for name in ("relay.sock", "core.sock")), "BLOCKED_AUTH_RUNTIME_IN_USE")
        with NativeCore(root, realm, root.name[1:]) as core:
            state.update(ops.read(root / "auth-state.json"))
            try:
                proof = device_flow(core, transport, receipt, update)
                update(model_verified=True, probe=proof)
                realm_guard(realm)
                ops.require(host.normal() == state["normal_before"], "BLOCKED_NORMAL_PROVENANCE_CHANGED")
                transport.post("/status", {"qualification_id": receipt["qualification_id"], "flow_id": receipt["flow_id"], "status": "verified"})
            except BaseException as error:
                update(reason=diag.exception_reason(error, "BLOCKED_AUTH_OR_MODEL_VERIFICATION"))
                if state.get("auth_lifecycle") != "revoked":
                    try:
                        revoke(core)
                        update(auth_lifecycle="revoked")
                    except BaseException:
                        update(auth_lifecycle="unknown", revocation_error="BLOCKED_AUTH_REVOCATION", status="needs_human")
                raise
        update(status="verified", native_stopped=True, auth_method="chatgpt_subscription",
               database_sha256=ops.sha(realm / "data/core.db"), evidence_class="native-core-auth-verified")
    except BaseException as error:
        record_failure(root, error, "BLOCKED_AUTH_OR_MODEL_VERIFICATION")
        state.update(ops.read(root / "auth-state.json"))
        reason = diag.exception_reason(error, "BLOCKED_AUTH_OR_MODEL_VERIFICATION")
        update(status="needs_human" if state.get("revocation_error") or state.get("resource_errors") else "blocked", reason=state.get("reason", reason))  # original failure retained
        try:
            if transport is not None and receipt is not None:
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


def revoke_live_core(root, state):
    """Attach only to the saved task Core; do not spawn over a live runtime."""
    saved = state.get("core_witness")
    current = ops.witness(saved["pid"]) if saved else None
    if current is None:
        return False  # a proved-dead Core needs same-realm recovery below
    ops.require(current["starttime"] == saved["starttime"], "BLOCKED_AUTH_PID_REUSE")
    ops.require(Path(f"/proc/{saved['pid']}/exe").resolve() == root / "candidate/target/release/ditto-core", "BLOCKED_AUTH_CLEANUP_IDENTITY")
    built = ops.verify_stage(root)
    realm = realm_path(root.name[1:])
    ops.require(state.get("source") == ops.SOURCE and state.get("ops_sha") == built["ops_sha"] and state.get("realm") == str(realm), "BLOCKED_AUTH_BINDING")
    fields = Path(f"/proc/{saved['pid']}/environ").read_bytes().split(b"\0")
    ops.require(b"DITTO_DATA_DIR=" + str(realm).encode() in fields, "BLOCKED_AUTH_CLEANUP_IDENTITY")
    core = NativeCore.__new__(NativeCore)
    core.root, core.realm, core.identifier = root, realm, root.name[1:]
    core.argv, core.env, core.runtime = core_contract(root, realm, root.name[1:])
    revoke(core)  # same path/keyring readiness + logout + status before stop
    state.update(auth_lifecycle="revoked")
    ops.write(root / "auth-state.json", state)
    return True


# One deadline strictly inside the existing 180s ExecStopPost limit. Phase
# caps sum to140s; reserve10s for result writes and controller overhead. Slow
# I/O gets remaining time, never a fresh per-command180s allowance.
CLEANUP_SECONDS, CLEANUP_TAIL = 150, 10
CLEANUP_PHASES = {
    "bridge_keys": 1, "bridge_transport": 1, "prepare_deadline_timer": 2,
    "live_auth_revocation": 35, "scope_stop": 25, "core_stop": 7,
    "scope_final_readback": 15, "core_final_readback": 2,
    "backend_final_readback": 2, "auth_revocation": 35,
    "normal_final_readback": 15,
}


def cleanup(root, host):
    end = time.monotonic() + CLEANUP_SECONDS
    state = ops.read(root / "auth-state.json")
    errors = list(dict.fromkeys(state.get("cleanup_errors", []) + state.get("resource_errors", [])))
    pending = list(CLEANUP_PHASES)
    steps = {}
    # Initial write is fail-closed even if a kill interrupts the first action.
    def persist(in_progress=True):
        # Reopened NativeCore may record a failure during an attempt.
        recorded = ops.read(root / "auth-state.json")
        if state.get("reason") is None and recorded.get("reason") is not None:
            state["reason"] = recorded["reason"]
        errors.extend(v for v in recorded.get("resource_errors", []) if v not in errors)
        state.update(cleanup_in_progress=in_progress, cleanup_pending=list(pending), cleanup_steps=dict(steps),
                     native_stopped=False, cleanup_errors=list(dict.fromkeys(errors + (["cleanup_incomplete"] if in_progress else []))))
        ops.write(root / "auth-state.json", state)
    persist()

    def attempt(name, fn, enabled=True):
        if not enabled:
            steps[name] = "not_applicable"
        else:
            # Earlier auth/scope work cannot spend the independent cleanup
            # tail. Reopening/logout cannot spend the normal readback tail.
            reserve = 60 if name in ("bridge_keys", "bridge_transport", "prepare_deadline_timer", "live_auth_revocation", "scope_stop") else 25
            if name == "normal_final_readback":
                reserve = CLEANUP_TAIL
            phase_end = min(end - reserve, time.monotonic() + CLEANUP_PHASES[name])
            token = ops.AUTH_CLEANUP_END.set(phase_end)
            try:
                ops.bounded_timeout(1)
                result = fn()
                if isinstance(result, list):
                    errors.extend(result)
                steps[name] = "failed" if isinstance(result, list) and result else "passed"
            except Exception as error:
                errors.extend(error.errors if isinstance(error, CleanupFailed) else [name])
                steps[name] = "failed"
            finally:
                ops.AUTH_CLEANUP_END.reset(token)
            if time.monotonic() >= phase_end:
                errors.append(name + ":budget_exhausted")
                steps[name] = "budget_exhausted"
        pending.remove(name)
        persist()  # never lose an earlier failure to a later hung step

    if state.get("auth_lifecycle", "none") not in ("none", "pending", "completed", "unknown", "revoked"):
        errors.append("auth_lifecycle_unknown")
    def needs_revocation():
        return state.get("status") != "verified" and state.get("auth_lifecycle") in ("pending", "completed", "unknown")
    attempt("bridge_keys", lambda: bridge.erase_keys(root / "auth-bridge", "client"))
    attempt("bridge_transport", lambda: (root / "auth-transport.json").unlink(missing_ok=True))
    attempt("prepare_deadline_timer", lambda: host.system("stop", "ditto-g3-auth-lease-q" + root.name[1:] + ".timer", check=False))
    attempt("live_auth_revocation", lambda: revoke_live_core(root, state), needs_revocation())
    attempt("scope_stop", lambda: stop_scopes(root, root.name[1:]))
    attempt("core_stop", lambda: stop_owned_core(root, state.get("core_witness")))
    attempt("scope_final_readback", lambda: scope_readbacks(root, root.name[1:]))
    saved = state.get("core_witness")
    attempt("core_final_readback", lambda: ops.require(ops.witness(saved["pid"]) is None, "BLOCKED_AUTH_CORE_STILL_RUNNING"), bool(saved))
    backend = state.get("native_runtime", {}).get("backend_witness")
    attempt("backend_final_readback", lambda: ops.require(ops.witness(backend["pid"]) is None, "BLOCKED_AUTH_BACKEND_STILL_RUNNING"), bool(backend))

    def revoke_stopped_realm():
        ops.require(not errors, "BLOCKED_AUTH_REVOCATION_UNPROVED")
        built = ops.verify_stage(root)
        ops.require(state.get("source") == ops.SOURCE and state.get("ops_sha") == built["ops_sha"], "BLOCKED_AUTH_BINDING")
        realm = realm_path(root.name[1:])
        ops.require(state.get("realm") == str(realm), "BLOCKED_AUTH_BINDING")
        realm_guard(realm)
        runtime = ops.RUNTIME / ("ditto-g3-auth-q" + root.name[1:])
        ops.require(runtime == runtime.resolve(), "BLOCKED_AUTH_RUNTIME_ALIAS")
        for name in ("relay.sock", "core.sock"):
            (runtime / name).unlink(missing_ok=True)
        with NativeCore(root, realm, root.name[1:]) as core:
            revoke(core)
            state.update(auth_lifecycle="revoked")
        state["core_witness"] = ops.read(root / "auth-state.json")["core_witness"]
    attempt("auth_revocation", revoke_stopped_realm, needs_revocation())
    if state.get("revocation_error"):
        errors.append("auth_revocation_failed")
    attempt("normal_final_readback", lambda: ops.require(host.normal() == state["normal_before"], "BLOCKED_NORMAL_PROVENANCE_CHANGED"))
    if state.get("status") not in ("verified", "blocked", "needs_human"):
        state.update(status="blocked")
        state.setdefault("reason", "BLOCKED_AUTH_INTERRUPTED_OR_EXPIRED")
    errors = list(dict.fromkeys(errors))
    persist(False)
    state.update(native_stopped=not errors)
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
                and not state.get("cleanup_errors") and state.get("auth_lifecycle") == "completed" and state.get("auth_method") == "chatgpt_subscription", "BLOCKED_AUTH_OR_MODEL_VERIFICATION")
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


def public_status(root, *, binding=None):
    # Only the selected auth-state; no auth-prepare/transport, database,
    # backend home, environment or provider request is opened here.
    path = root / "auth-state.json"
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd) as stream:
        ops.require(os.fstat(stream.fileno()).st_size <= 1024 * 1024, "BLOCKED_AUTH_UNKNOWN_STATE")
        state = json.load(stream)
    if binding is not None:
        ops.require(state.get("source") == ops.SOURCE and state.get("ops_sha") == binding["ops_sha"] and state.get("qualification_id") == root.name[1:], "BLOCKED_AUTH_BINDING")
    ops.require(state.get("status") in STATES, "BLOCKED_AUTH_UNKNOWN_STATE")
    result = {"qualification_id": root.name[1:], "source": ops.SOURCE, "status": state["status"],
              "model": MODEL, "effort": EFFORT, "physical_success": False}
    for key in ("login_complete", "model_verified", "native_stopped"):
        ops.require(type(state.get(key)) is bool, "BLOCKED_AUTH_UNKNOWN_STATE")
        result[key] = state[key]
    result["reason"] = diag.reason(state.get("reason"))
    marker = state.get("last_marker", "not_recorded")
    lifecycle = state.get("auth_lifecycle", "not_recorded")
    result["last_marker"] = marker if type(marker) is str and marker in diag.MARKERS else "BLOCKED_UNLISTED_REASON"
    result["auth_lifecycle"] = lifecycle if type(lifecycle) is str and lifecycle in diag.LIFECYCLES else "BLOCKED_UNLISTED_REASON"
    errors = state.get("cleanup_errors", [])
    result["cleanup_errors"] = sorted(set(diag.cleanup_code(v, root.name[1:]) for v in errors)) if type(errors) is list and len(errors) <= 128 else ["BLOCKED_UNLISTED_REASON"]
    ops.require(not ops.SECRET.search(json.dumps(result)), "BLOCKED_UNLISTED_REASON")
    return result


def auth_reason(root):
    # Deliberately no workflow-SHA equality, mutation, normal readback, auth
    # discovery or lock. Selected staged hashes/source are still mandatory.
    binding = ops.verify_stage(root, read_only=True)
    return public_status(root, binding=binding)

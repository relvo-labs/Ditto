#!/usr/bin/env python3
"""Bounded G3 operational qualification; never a product installer.

Production CLI has fixed host, source, tools, units and command vectors.
Tests inject a TEST ONLY Host in temporary directories, never OS stress.
Private state/logs stay host-local; publish() constructs a small typed receipt.
"""
import argparse
from contextlib import closing
from contextvars import ContextVar
import difflib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import time

SOURCE = "17f5d76dc043d7d8117f1e99458a9a0c9255354b"
BRANCH = "hermes/g3-physical-qualification"
INSTALLED = Path("/home/neil/funlab/Ditto")
NORMAL = Path("/home/neil/.local/share/ditto/core.db")
BASE = Path("/home/neil/.local/state/ditto-g3-qualification")
TEMPLATE = Path("/etc/systemd/user/ditto-core.service.d/verification-relay.conf")
TEMPLATE_SHA = "c81e6f47736da4ba21a62090a37591369cba2dc936f707217df3a80b2d6c2fc7"
GDM = Path("/etc/gdm3/custom.conf")
GDM_SHA = "ceee968ce021213814ef4f87e19f6e76fcb0333170786dd0c006760ad61810af"
CODEX = Path("/home/neil/.codex/packages/standalone/releases/0.160.0-x86_64-unknown-linux-musl/bin/codex")
CODEX_SHA = "12eb3e81114588aca3b7998f4f19e8997b056aca08e57a7ca7c8a3ec8c652aad"
SEAT_SHA = "b34879ef9a8b3dedf308afd1183c9fb42183fe2faff8399b6e2af9ccec89f18d"
RUNTIME = Path("/run/user/1000")
DROPIN = RUNTIME / "systemd/user/ditto-core.service.d/zz-g3-reference-test.conf"
RUNNER = "github-actions-ditto-ref.service"
MODES = ("full", "faults", "partial", "unavailable")
HERE = Path(__file__).resolve().parent
SECRET = re.compile(r"(?i)(SECRET_SENTINEL|BEGIN .*PRIVATE KEY|Bearer\s|sk-[a-z0-9]|gh[pousr]_|authorization\s*:|access_token|refresh_token)")


# Set only during this task's auth cleanup/readiness. Never exported to child
# environments or persisted as a credential/configuration override.
AUTH_CLEANUP_END = ContextVar("g3_auth_cleanup_end", default=None)


def bounded_timeout(cap):
    require(cap > 0, "BLOCKED_AUTH_CLEANUP_BUDGET")
    end = AUTH_CLEANUP_END.get()
    if end is None:
        return cap
    remaining = end - time.monotonic()
    require(remaining > 0, "BLOCKED_AUTH_CLEANUP_BUDGET")
    return min(cap, remaining)


class Refused(RuntimeError):
    pass


def require(ok, reason):
    if not ok:
        raise Refused(reason)


def core_result(value, reason="BLOCKED_NATIVE_MANAGED_API"):
    """Remove only Core's top-level ResultMeta, never application fields."""
    if type(value) is not dict:
        return value  # the caller's existing shape guard remains authoritative
    require("_meta" not in value or type(value["_meta"]) is dict, reason)
    return {key: item for key, item in value.items() if key != "_meta"}


def sha(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            bounded_timeout(1)  # fail closed if task cleanup budget expired
            h.update(block)
    return h.hexdigest()


def write(path, value):
    """Private atomic journal, before the side effect it describes."""
    path = Path(path)
    temp = path.with_suffix(path.suffix + ".new")
    with temp.open("w") as stream:
        os.chmod(temp, 0o600)
        json.dump(value, stream, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    temp.replace(path)
    fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def read(path):
    return json.loads(Path(path).read_text())


def run_root(identifier):
    require(re.fullmatch(r"[1-9][0-9]{5,19}", identifier), "invalid qualification ID")
    require(not (BASE / "bridge-probes" / ("p" + identifier)).exists(), "BLOCKED_PROBE_COLLISION")
    root = BASE / ("q" + identifier)
    require(not BASE.is_symlink() and not root.is_symlink(), "task root alias")
    return root


def schema(database):
    with closing(sqlite3.connect(Path(database).as_uri() + "?mode=ro", uri=True, timeout=bounded_timeout(5))) as conn:
        return conn.execute("PRAGMA user_version").fetchone()[0]


def assert_source(root, receipt=None, *, read_only=False):
    source_env = dict(os.environ, GIT_OPTIONAL_LOCKS="0") if read_only else None
    head = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True, timeout=bounded_timeout(10) if AUTH_CLEANUP_END.get() is not None else None, env=source_env, stderr=subprocess.DEVNULL if read_only else None).strip()
    dirty = subprocess.check_output(["git", "-C", str(root), "status", "--porcelain"], timeout=bounded_timeout(10) if AUTH_CLEANUP_END.get() is not None else None, env=source_env, stderr=subprocess.DEVNULL if read_only else None)
    require(head == SOURCE and not dirty, "source mismatch or candidate changed")
    require(receipt is None or receipt.get("source") == head, "source/receipt mismatch")


def select_store(selection, normal=NORMAL, home=Path("/home/neil")):
    """Explicit parent metadata selection, never infer auth from auth_ref.

    Selection denotes DITTO_DATA_DIR, not its data/ subdirectory. Same
    backend CODEX_HOME is retained. A later live providers.status is mandatory.
    """
    require(selection.get("source") == SOURCE, "selection/source mismatch")
    stores = selection.get("stores", [])
    require(len(stores) == 1, "BLOCKED_PRIVATE_STORE_SELECTION: absent or multiple")
    item = stores[0]
    root = Path(item.get("root", ""))
    require(root.is_absolute() and root == root.resolve(), "private store alias")
    require(re.fullmatch(r"/[A-Za-z0-9_./-]+", str(root)), "unsafe private path")
    allowed = [home / "funlab/Ditto/artifacts/g3", home / ".cache/ditto"]
    # Other task directories require the third preflight's exact inventory;
    # this scaffold deliberately admits only the already inspected roots.
    require(any(root.is_relative_to(base) and root != base for base in allowed), "BLOCKED_UNPROVED_TASK_ROOT")
    db = root / "data/core.db"
    require(db.is_file() and not db.is_symlink() and db.stat().st_nlink == 1, "missing/aliased private database")
    require(db == db.resolve(), "private data directory alias")
    for name in ("data", "state", "cache", "state/agent", "state/agent/backend", "state/agent/backend/codex"):
        path = root / name
        require(path == path.resolve(), "private state/cache alias")
    require(not db.samefile(normal), "normal-store alias")
    require(not normal.resolve().is_relative_to(root), "normal store inside selection")
    codex = root / "state/agent/backend/codex"
    require(item.get("codex_home") == str(codex), "CODEX_HOME path mismatch")
    require(item.get("existing_subscription_proved") is True and item.get("test_content_only") is True,
            "BLOCKED_PRIVATE_STORE_METADATA: parent proof/selection required")
    require(schema(db) in (4, 5), "unsupported private schema")
    with closing(sqlite3.connect(db.as_uri() + "?mode=ro", uri=True)) as conn:
        prefs = json.loads(conn.execute("SELECT settings_json FROM agent_preferences WHERE singleton=1").fetchone()[0])
        require(conn.execute("SELECT count(*) FROM agent_turns WHERE state IN ('queued','running','awaiting_approval','cancelling')").fetchone()[0] == 0, "private store has outstanding turns")
        require(conn.execute("SELECT count(*) FROM jobs WHERE state IN ('queued','running','cancelling')").fetchone()[0] == 0, "private store has outstanding jobs")
    require(prefs.get("provider") == "codex-app-server", "private provider mismatch")
    # No auth value or reference is emitted, copied or used to guess login.
    require(item.get("database_sha256") == sha(db), "private database selection stale")
    return root


def rewrite_template(text, candidate, binaries, store, template_sha=TEMPLATE_SHA, installed=INSTALLED, normal=NORMAL):
    require(hashlib.sha256(text.encode()).hexdigest() == template_sha, "unknown template hash")
    require(str(installed) + "/target/release/ditto-core serve " in text, "unknown template root")
    require(text.count("ExecStart=\n") == 1 and text.count("ExecStart=/") == 1, "unknown ExecStart")
    require("DITTO_DATA_DIR" not in text, "template already overrides database")
    require(store.resolve() != normal.parent.resolve() and not normal.resolve().is_relative_to(store.resolve()), "normal-store alias")
    for path in (candidate, binaries, store):
        require(path.is_absolute() and re.fullmatch(r"/[A-Za-z0-9_./-]+", str(path)), "unsafe runtime path")
    require(binaries == candidate / "target/release" or binaries.parent.name == "contexts" and binaries.name in MODES[1:], "unbounded binaries")
    rewritten = text.replace(str(installed) + "/", str(candidate) + "/")
    rewritten = rewritten.replace(str(candidate / "target/release/ditto-core"), str(binaries / "ditto-core"))
    require(str(installed) + "/" not in rewritten, "installed root survived")
    # Preserve every unrelated argument/version and pinned Codex executable.
    return rewritten + f"Environment=DITTO_DATA_DIR={store}\n"


def adapt_seat(text, candidate, helper, identifier):
    require(hashlib.sha256(text.encode()).hexdigest() == SEAT_SHA, "unknown canonical seat script")
    changed = text.replace('cd "$(dirname "$0")/../../.."', f'cd "{candidate}"', 1)
    start = changed.index('printf \'[Service]\\nEnvironment=DITTO_DATA_DIR=')
    end = changed.index("systemctl --user daemon-reload", start)
    changed = changed[:start] + f'python3 "{helper}" override --id {identifier}\n' + changed[end:]
    # All original worker guards, limits/tests and restoration stay. Outer
    # controller owns runner state; mode finally must never restart CI early.
    line = '    if [[ "$runner_was_active" == active ]]; then systemctl --user start github-actions-ditto-ref.service || restored=1; fi'
    require(changed.count(line) == 1, "canonical runner restore changed")
    changed = changed.replace(line, "    # Outer controller restores the runner once after every mode.")
    # Add readback/auth and preferences snapshots after the private login,
    # before any test/provider request. Recovery uses the canonical APIs.
    anchor = 'wait_login "$old"\nfoot '
    require(changed.count(anchor) == 1, "canonical login changed")
    changed = changed.replace(anchor, f'wait_login "$old"\npython3 "{helper}" enter --id {identifier}\nfoot ')
    changed = changed.replace('    rm -f "$dropin"', f'    local private_restored=0\n    python3 "{helper}" leave --id {identifier} || private_restored=1\n    rm -f "$dropin"', 1)
    restore_block = '    rm -f "$dropin"\n    systemctl --user daemon-reload\n    old="${XDG_SESSION_ID:-}"\n    sudo -n /usr/local/libexec/ditto-relogin\n    wait_login "$old"\n    local restored=$?'
    guarded = '    local restored=1\n    if rm -f "$dropin" && [[ ! -e "$dropin" && ! -L "$dropin" ]] && systemctl --user daemon-reload; then\n        old="${XDG_SESSION_ID:-}"\n        if sudo -n /usr/local/libexec/ditto-relogin && wait_login "$old"; then restored=0; fi\n    fi\n    [[ "$private_restored" == 0 ]] || restored=1'
    require(changed.count(restore_block) == 1, "canonical recovery block changed")
    changed = changed.replace(restore_block, guarded, 1)
    return changed


def witness(pid, proc=Path("/proc")):
    p = proc / str(pid)
    try:
        raw = p.joinpath("stat").read_text()
    except (FileNotFoundError, ProcessLookupError):
        require(not p.exists(), "PID witness partially unreadable")
        return None
    start = raw.rsplit(")", 1)[1].split()[19]
    try:
        cmd = p.joinpath("cmdline").read_bytes().split(b"\0")
    except (FileNotFoundError, ProcessLookupError):
        require(not p.exists(), "PID command witness unreadable")
        return None
    return {"pid": int(pid), "starttime": start, "worker": any(x.endswith(b"/bin/Runner.Worker") for x in cmd) and b"spawnclient" in cmd}


def worker_gate(origin, workers):
    """Read original identity independently of its current executable/name."""
    try:
        current = witness(origin["pid"])
    except (OSError, ValueError, IndexError):
        raise Refused("origin PID witness unreadable") from None
    if current:
        require(current["starttime"] == origin["starttime"], "origin PID reuse")
    for worker in workers:
        require(worker["pid"] == origin["pid"] and worker["starttime"] == origin["starttime"], "other active Runner.Worker or PID reuse")
    return current is None and not workers


def wait_ready(call, timeout=30, *, allow_draining=False):
    """Only revocation may finish a disabled old generation before ensure.

    The public relay has no readiness event. This is one bounded transition,
    not a login/model retry. A second ensure is legal only after old stopped.
    """
    end = time.monotonic() + bounded_timeout(timeout)
    token = AUTH_CLEANUP_END.set(end)
    try:
        initial = call("agent.runtime.ensure")
        draining = initial.get("phase") == "draining"
        require(not draining or allow_draining, "Agent draining before ready")
        restarted = False
        while time.monotonic() < end:
            runtime = call("agent.runtime.get")
            phase = runtime.get("phase")
            if phase == "ready":
                require(not draining, "old draining generation did not stop")
                return runtime
            if phase == "draining":
                require(allow_draining and not restarted, "Agent draining before ready")
                draining = True
            elif phase == "stopped":
                require(allow_draining and draining and not restarted, "Agent stopped before ready")
                # Core ensure preserves the fixed specification/realm and
                # increments its generation. No alternate process/ref input.
                call("agent.runtime.ensure")
                restarted, draining = True, False
            else:
                require(phase == "starting" and not draining, "Agent failed/cancelled/unknown before ready")
            time.sleep(min(.2, bounded_timeout(.2)))
        raise Refused("Agent readiness deadline")
    except Refused as error:
        if str(error) == "BLOCKED_AUTH_CLEANUP_BUDGET":
            raise Refused("Agent readiness deadline") from None
        raise
    finally:
        AUTH_CLEANUP_END.reset(token)


BOOTSTRAP_HASHES = {
    "tests/g1/lib/gui.py": "7b3e76242fe188958aef87494bf5a4ee39d47a197b3196a9e5d79e4b29126a4f",
    "tools/compositor-probe/g1/wfipc.py": "90f18b9546b2cb54dce1d339195dd5d6c3179cc520f64edb0523c02ffb117376",
}

def normal_helper():
    # Exact unchanged17f helper and its import frozen with ops; available
    # before candidate exists and after Actions clears its checkout.
    base = HERE / "bootstrap"
    for name, expected in BOOTSTRAP_HASHES.items():
        require(sha(base / name) == expected, "normal bootstrap helper changed")
    return base / "tests/g1/lib/gui.py"


class Host:
    def __init__(self, root):
        self.root = root
        # No workflow token/raw job environment is forwarded to controller.
        self.env = {"HOME": "/home/neil", "USER": "neil", "LANG": "C.UTF-8",
                    "PATH": "/home/neil/.nvm/versions/node/v22.23.2/bin:/home/neil/.cargo/bin:/home/neil/Qt/6.10.2/gcc_64/bin:/home/neil/wayfire/bin:/home/neil/.local/bin:/usr/bin:/bin",
                    "XDG_RUNTIME_DIR": str(RUNTIME), "DBUS_SESSION_BUS_ADDRESS": f"unix:path={RUNTIME}/bus",
                    "COREPACK_ENABLE_NETWORK": "0", "npm_config_offline": "true", "CARGO_NET_OFFLINE": "true",
                    "DITTO_RUNTIME_DIR": str(RUNTIME / "ditto"), "DITTO_G1_RELAY": str(RUNTIME / "ditto/verify-relay.sock")}

    def command(self, argv, timeout=10, check=True, env=None):
        try:
            result = subprocess.run(argv, env=env or self.env, text=True, capture_output=True, timeout=bounded_timeout(timeout))
        except OSError:
            if check:
                raise Refused("required command unavailable: " + Path(argv[0]).name)
            return subprocess.CompletedProcess(argv, 127, "", "")
        if check:
            require(result.returncode == 0, "command failed: " + Path(argv[0]).name)
        return result

    def system(self, *args, check=True):
        return self.command(["systemctl", "--user", *args], check=check).stdout.strip()

    def relay(self, method, params=None, *, private=False):
        helper = self.root / "candidate/tests/g1/lib/gui.py" if private else normal_helper()
        if private:
            require(sha(helper) == BOOTSTRAP_HASHES["tests/g1/lib/gui.py"], "private relay helper changed")
        budget = min(15, getattr(self, "private_recovery_deadline", time.monotonic() + 15) - time.monotonic())
        require(budget > 0, "private recovery API budget exhausted")
        result = self.command(["python3", str(helper), "relay", method, json.dumps(params or {})], timeout=budget)
        reply = json.loads(result.stdout)
        require("error" not in reply, "relay refused " + method)
        return core_result(reply["result"])

    def private_relay(self, method, params=None):
        state = read(self.root / "state.json")
        self.private_live(state)
        return self.relay(method, params, private=True)

    def profile(self):
        p = self.relay("desktop.profiles.get")
        return {"profile_id": p["profile"]["profile_id"], "sha256": p["revision"]["document_sha256"]}

    def normal(self):
        session = next((x[15:] for x in self.system("show-environment").splitlines() if x.startswith("XDG_SESSION_ID=")), "")
        require(session, "normal active session missing")
        props = self.command(["loginctl", "show-session", session, "-p", "User", "-p", "Active", "-p", "Type", "-p", "Seat"]).stdout.splitlines()
        require(all(x in props for x in ("User=1000", "Active=yes", "Type=wayland", "Seat=seat0")), "normal intended seat unavailable")
        pid = int(self.system("show", "ditto-core.service", "-p", "MainPID", "--value"))
        exe = Path(f"/proc/{pid}/exe").resolve(strict=True)
        require(exe == INSTALLED / "target/release/ditto-core", "normal executable mismatch")
        require(schema(NORMAL) == 4, "normal store schema is not 4")
        # Read only the selected env key, never publish/raw-save environments.
        fields = Path(f"/proc/{pid}/environ").read_bytes().split(b"\0")
        require(not any(x.startswith(b"DITTO_DATA_DIR=") for x in fields), "normal runtime has data override")
        head = self.command(["git", "-C", str(INSTALLED), "rev-parse", "HEAD"]).stdout.strip()
        require(head == "d49387f94cea3f37207224463895be1b4e95d8ec" and not self.command(["git", "-C", str(INSTALLED), "status", "--porcelain"]).stdout.strip(), "installed source changed")
        binary_hash = sha(Path(f"/proc/{pid}/exe"))
        require(binary_hash == sha(exe), "installed executable changed on disk")
        permissions = lambda p: {"mode": p.stat().st_mode & 0o777, "uid": p.stat().st_uid, "gid": p.stat().st_gid}
        return {"schema": 4, "installed_source": head, "exe_sha256": binary_hash, "profile": self.profile(),
                "template_sha256": sha(TEMPLATE), "template_permissions": permissions(TEMPLATE),
                "gdm_sha256": sha(GDM), "gdm_permissions": permissions(GDM)}

    def workers(self):
        result = []
        for p in Path("/proc").iterdir():
            if p.name.isdigit():
                try:
                    w = witness(p.name)
                    if w and w["worker"]:
                        result.append(w)
                except (PermissionError, OSError):
                    continue
        return result

    def listener_signal(self, saved, signum):
        # pidfd closes the lookup/signal PID-reuse window. Never signal a
        # Worker or infer identity from a broad command-line match.
        current = witness(saved["pid"])
        if current is None:
            return
        require(current["starttime"] == saved["starttime"] and not current["worker"], "runner Listener PID reused")
        require(Path(f"/proc/{saved['pid']}/exe").resolve(strict=True) == Path("/home/neil/actions-runner-ditto-ref/bin/Runner.Listener"), "runner Listener executable changed")
        fd = os.pidfd_open(saved["pid"])
        try:
            current = witness(saved["pid"])
            require(current and current["starttime"] == saved["starttime"], "Listener changed before signal")
            signal.pidfd_send_signal(fd, signum)
        finally:
            os.close(fd)

    def resume_listener(self, state):
        if state.get("listener"):
            self.listener_signal(state["listener"], signal.SIGCONT)

    def freeze_listener(self, saved):
        self.listener_signal(saved, signal.SIGSTOP)
        end = time.monotonic() + 3
        while time.monotonic() < end:
            status = Path(f"/proc/{saved['pid']}/status").read_text()
            if re.search(r"^State:\s+T\b", status, re.MULTILINE):
                return
            time.sleep(.05)
        raise Refused("Listener did not reach stopped state")

    def pause_runner(self, state):
        group = self.system("show", RUNNER, "-p", "ControlGroup", "--value")
        require(group.startswith("/user.slice/user-1000.slice/user@1000.service/"), "unexpected runner cgroup")
        pids = (Path("/sys/fs/cgroup") / group.lstrip("/") / "cgroup.procs").read_text().split()
        listeners = []
        for pid in pids:
            try:
                if Path(f"/proc/{pid}/exe").resolve(strict=True) == Path("/home/neil/actions-runner-ditto-ref/bin/Runner.Listener"):
                    listeners.append(witness(pid))
            except FileNotFoundError:
                continue
        require(len(listeners) == 1 and listeners[0], "one known runner Listener required")
        state["listener"] = listeners[0]
        write(self.root / "state.json", state)  # crash recovery can resume it
        try:
            self.freeze_listener(state["listener"])
            require(worker_gate(state["origin"], self.workers()), "Worker arrived before guarded pause")
            # Listener cannot accept another job between this guard and stop.
            # systemd's termination delivers its own SIGCONT. Do not manually
            # resume until stop completes, or bounded failure recovery begins.
            self.system("--no-block", "stop", RUNNER)
            end = time.monotonic() + 30
            while self.system("is-active", RUNNER, check=False) != "inactive":
                require(time.monotonic() < end and not self.workers(), "runner stop deadline/Worker race")
                time.sleep(.2)
        finally:
            self.resume_listener(state)

    def relogin(self):
        old = self.system("show-environment")
        old = next((x[15:] for x in old.splitlines() if x.startswith("XDG_SESSION_ID=")), "")
        self.command(["sudo", "-n", "/usr/local/libexec/ditto-relogin"], timeout=45)
        # No login/relay readiness event is offered by this interface. This
        # is a bounded host-local poll, never an Actions API query.
        end = time.monotonic() + 125
        while time.monotonic() < end:
            now = self.system("show-environment")
            session = next((x[15:] for x in now.splitlines() if x.startswith("XDG_SESSION_ID=")), "")
            if session and session != old:
                state = self.command(["loginctl", "show-session", session, "-p", "Active", "-p", "Type", "-p", "Seat"]).stdout
                if all(x in state.splitlines() for x in ("Active=yes", "Type=wayland", "Seat=seat0")):
                    try:
                        self.profile()
                        return
                    except Refused:
                        pass
            time.sleep(.5)
        raise Refused("normal relogin deadline")

    def restore_private(self, state):
        self.private_recovery_deadline = time.monotonic() + 30
        try:
            self._restore_private(state)
        finally:
            del self.private_recovery_deadline

    def _restore_private(self, state):
        directory = self.root / "evidence" / state["mode"]
        receipt = directory / "private-recovery.json"
        if receipt.exists() and read(receipt).get("status") == "verified":
            return
        snap = self.root / "evidence" / state["mode"] / "private-before.json"
        if not snap.exists():
            # No settings/model test could start before enter wrote this.
            return
        before = read(snap)
        # Never apply private snapshots to the normal desktop after the
        # canonical finally has already removed the temporary drop-in.
        self.private_live(state)
        self.private_relay("agent.runtime.stop")
        current = self.private_relay("desktop.profiles.get")
        target = before["profile"]
        self.private_relay("desktop.changes.propose", {"base_revision": current["profile"]["head_revision"],
                   "ops": [{"op": "switch_profile", "to_profile": target["profile"]["profile_id"], "to_revision": target["profile"]["head_revision"]}],
                   "idempotency_key": "ops-private-restore-" + self.root.name + "-" + state["mode"]})
        settings = core_result(before["preferences"])
        settings["revision"] = self.private_relay("agent.settings.describe")["revision"]
        self.private_relay("agent.settings.patch", {"expected_revision": settings["revision"], "settings": settings})
        grants = self.private_relay("desktop.permissions.list", {"subject": "agent", "include_revoked": True})["grants"]
        original = set(before["grant_ids"])
        for grant in grants:
            if grant["grant_id"] not in original and not grant.get("revoked_at"):
                self.private_relay("desktop.permissions.revoke", {"grant_id": grant["grant_id"]})
        after = self.private_relay("desktop.profiles.get")
        require(after["profile"]["profile_id"] == target["profile"]["profile_id"] and after["revision"]["document_sha256"] == target["revision"]["document_sha256"], "private profile restore mismatch")
        normalize = lambda p: {k: v for k, v in core_result(p).items() if k != "revision"}
        require(normalize(self.private_relay("agent.settings.describe")) == normalize(before["preferences"]), "private settings restore mismatch")
        after_grants = self.private_relay("desktop.permissions.list", {"subject": "agent", "include_revoked": True})["grants"]
        require(all(g["grant_id"] in original or g.get("revoked_at") for g in after_grants), "private test grants remain")
        write(receipt, {"status": "verified", "source": SOURCE})

    def private_live(self, state):
        binaries = self.root / "candidate/target/release" if state["mode"] == "full" else self.root / "contexts" / state["mode"]
        pid = int(self.system("show", "ditto-core.service", "-p", "MainPID", "--value"))
        require(Path(f"/proc/{pid}/exe").resolve() == binaries / "ditto-core", "private executable mismatch")
        fields = Path(f"/proc/{pid}/environ").read_bytes().split(b"\0")
        require(b"DITTO_DATA_DIR=" + state["store"].encode() in fields, "private runtime store mismatch")

    def normal_state(self):
        if DROPIN.exists():
            return "NEED"
        try:
            self.normal()  # executable, store, seat, source, relay and Profile
            return "NORMAL"
        except Refused:
            return "NEED"
        except (OSError, ValueError):
            return "UNKNOWN"

    def needs_relogin(self):
        return self.normal_state() != "NORMAL"

    def remove_override(self):
        DROPIN.unlink(missing_ok=True)
        require(not DROPIN.exists() and not DROPIN.is_symlink(), "runtime override remains")
        self.system("daemon-reload")
        require(not DROPIN.exists() and not DROPIN.is_symlink(), "runtime override reappeared")
        return True

    def restore_gdm(self):
        self.command(["sudo", "-n", "cp", "-p", str(self.root / "gdm-original.conf"), str(GDM)])


def recover(root, host):
    """Shared finally/ExecStopPost handler. Re-entry reads verified result.

    Always attempt normal rescue even if private API recovery fails. Failure
    remains sticky, records needs_human, and prohibits dispatch/publication.
    """
    with (root / "recovery.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = read(root / "state.json")
        if state.get("recovery_complete"):
            return state
        if state.get("mode") and state["modes"].get(state["mode"]) == "running":
            state["modes"][state["mode"]] = "failed"
            state.setdefault("failure", "interrupted_or_deadline")
        errors = list(state.get("recovery_errors", []))
        diagnostics = list(state.get("recovery_diagnostics", []))
        service_result = os.environ.get("SERVICE_RESULT")
        if service_result in ("success", "timeout", "signal", "exit-code", "oom-kill", "resources"):
            state["service_result"] = service_result

        def attempt(name, fn):
            try:
                return fn()
            except Exception as error:
                errors.append(name)  # no private exception values exported
                diagnostics.append({"step": name, "type": type(error).__name__,
                                    "reason": str(error) if isinstance(error, Refused) else type(error).__name__})
                return False

        if state.get("disruption_armed"):
            relogin = True
            try:
                relogin = host.needs_relogin()
            except Exception:
                errors.append("determine_relogin")
            if state.get("mode"):
                attempt("private_api_restore", lambda: host.restore_private(state))
            # This ordering also holds after SIGKILL / service deadline.
            override_safe = attempt("remove_runtime_override", host.remove_override) is True
            if relogin and override_safe:
                attempt("normal_relogin", host.relogin)
            # Keep test autologin until normal runtime is back, then remove
            # autologin even if login/readback failed (canonical order).
            attempt("restore_gdm", host.restore_gdm)
            attempt("normal_provenance_readback", lambda: require(host.normal() == state["normal_before"], "normal provenance mismatch"))
        if state.get("pause_armed"):
            attempt("runner_listener_resume", lambda: host.resume_listener(state))
            if state["runner_before"] == "active":
                attempt("runner_restore", lambda: host.system("start", RUNNER))
            attempt("runner_readback", lambda: require(host.system("is-active", RUNNER, check=False) == state["runner_before"], "runner state mismatch"))
        state.update(recovery_complete=True, recovery_errors=errors, recovery_diagnostics=diagnostics, recovery_status="needs_human" if errors else "verified")
        write(root / "state.json", state)
        return state


def preflight(root, host):
    require(not DROPIN.exists(), "existing runtime override")
    normal = host.normal()
    require(normal["template_sha256"] == TEMPLATE_SHA and normal["gdm_sha256"] == GDM_SHA, "host template/GDM changed")
    require(host.command(["sudo", "-n", "true"], check=False).returncode == 0, "sudo relogin unavailable")
    require(host.command(["busctl", "--user", "get-property", "org.freedesktop.secrets", "/org/freedesktop/secrets/collection/login", "org.freedesktop.Secret.Collection", "Locked"]).stdout.strip() == "b false", "keyring unavailable/locked")
    sessions = host.command(["loginctl", "list-sessions", "--no-legend"]).stdout
    seat = False
    for line in sessions.splitlines():
        sid = line.split()[0]
        props = host.command(["loginctl", "show-session", sid, "-p", "User", "-p", "Active", "-p", "Type", "-p", "Seat"]).stdout.splitlines()
        seat |= all(x in props for x in ("User=1000", "Active=yes", "Type=wayland", "Seat=seat0"))
    require(seat, "active physical Wayland seat0 required")
    require(host.command([str(Path("/home/neil/.nvm/versions/node/v22.23.2/bin/node")), "--version"]).stdout.strip() == "v22.23.2", "Node pin mismatch")
    require(host.command(["pnpm", "--version"]).stdout.strip() == "10.11.0", "pnpm pin mismatch")
    require(sha(CODEX) == CODEX_SHA, "existing pinned Codex executable mismatch")
    # Never inspect gh credential files or return auth status output/identity.
    gh = host.command(["gh", "auth", "status"], check=False).returncode == 0
    selected = "fresh_realm_auth_pending"
    if (root / "auth-state.json").exists():
        from g3_auth import public_status
        selected = public_status(root)["status"]
    report = {"source": SOURCE, "normal": normal, "normal_helper": {"source": SOURCE, "abi_installed_source": "d49387f94cea3f37207224463895be1b4e95d8ec", "path": str(normal_helper()), "sha256": sha(normal_helper())}, "seat0": True, "private_store_status": selected,
              "github_cli_authenticated": gh, "codex_sha256": CODEX_SHA, "provider_called": False, "disruption_started": False}
    write(root / "preflight.json", report)
    return report


def stage(root, host):
    require(not (root / "candidate").exists(), "stage is single-use; use a fresh ID")
    preflight(root, host)
    require(shutil.disk_usage(root).free >= 12 * 1024 * 1024 * 1024, "insufficient stage space (12 GiB required)")
    repo = HERE.parents[1]
    candidate = root / "candidate"
    host.command(["git", "clone", "--no-hardlinks", "--no-checkout", str(repo), str(candidate)], timeout=240)
    host.command(["git", "-C", str(candidate), "checkout", "--detach", SOURCE], timeout=60)
    assert_source(candidate)
    # Freeze the operation implementation outside Actions _work as well.
    shutil.copytree(HERE, root / "ops", ignore=shutil.ignore_patterns("__pycache__"))
    env = dict(host.env, CARGO_NET_OFFLINE="true", COREPACK_ENABLE_NETWORK="0")
    with (root / "build.log").open("w") as log:
        result = subprocess.run(["systemd-run", "--user", "--wait", "--pipe", "--collect", "--unit=ditto-g3-build-" + root.name,
                                 "--property=Type=exec", "--property=RuntimeMaxSec=2700", "--property=MemoryMax=8G", "--property=MemorySwapMax=0",
                                 "--property=TasksMax=256", "--property=CPUQuota=200%", "--property=LimitFSIZE=536870912", "--property=UMask=0077",
                                 "--working-directory=" + str(candidate),
                                 *["--setenv=" + key + "=" + value for key, value in sorted(env.items())],
                                 "bash", str(root / "ops/build-g3.sh")], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=2760)
    require(result.returncode == 0, "BLOCKED_BUILD_CACHE_OR_BUILD_FAILURE; private build.log retained")
    host.command(["python3", str(candidate / "tests/g3/reference/prepare-contexts.py"), str(root / "contexts")])
    assert_source(candidate)
    original = (candidate / "tests/g3/reference/seat.sh").read_text()
    adapted = adapt_seat(original, candidate, root / "ops/g3_ops.py", root.name[1:])
    (root / "seat.sh").write_text(adapted)
    (root / "seat.diff").write_text("".join(difflib.unified_diff(original.splitlines(True), adapted.splitlines(True), fromfile="source17f/seat.sh", tofile="operational-copy/seat.sh")))
    names = []
    for base in (candidate / "target/release", candidate / "target/ditto-packages-verification", root / "contexts"):
        names.extend(p for p in base.rglob("*") if p.is_file() and (p.name.startswith("ditto-") or p.suffix == ".dittopkg"))
    for base in (candidate / "packages/host-runtime/dist", candidate / "packages/agent-runtime/dist", candidate / "crates/ditto-generation/templates"):
        require(base.is_dir(), "missing bundle/template directory")
        names.extend(p for p in base.rglob("*") if p.is_file())
    for name in ("ditto-core", "ditto-worker", "ditto-confine", "ditto-test-host", "ditto-test-probe", "ditto-generation-host", "ditto-generation-runner", "ditto-dbus-proxy"):
        require((candidate / "target/release" / name).is_file(), "missing built binary " + name)
    version = {name: host.command(args).stdout.strip() for name, args in {"rustc": ["rustc", "--version"], "cargo": ["cargo", "--version"], "g++": ["g++", "--version"], "node": ["node", "--version"], "pnpm": ["pnpm", "--version"]}.items()}
    source_facts = json.loads(host.command(["python3", str(candidate / "tests/g3/source.py")]).stdout)
    write(root / "stage.json", {"source": SOURCE, "ops_sha": subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip(),
          "source_facts": source_facts, "compiler_versions": version, "template_sha256": sha(TEMPLATE), "original_seat_sha256": sha(candidate / "tests/g3/reference/seat.sh"),
          "seat_sha256": sha(root / "seat.sh"), "diff_sha256": sha(root / "seat.diff"),
          "files": {str(p.relative_to(root)): sha(p) for p in sorted(names)},
          "ops_files": {str(p.relative_to(root)): sha(p) for p in sorted((root / "ops").rglob("*")) if p.is_file()}, "build_status": "built"})


def verify_stage(root, *, read_only=False):
    receipt = read(root / "stage.json")
    assert_source(root / "candidate", receipt, read_only=read_only)
    require(sha(root / "seat.sh") == receipt["seat_sha256"] and sha(root / "seat.diff") == receipt["diff_sha256"], "seat copy changed")
    require(receipt["original_seat_sha256"] == SEAT_SHA and receipt["template_sha256"] == TEMPLATE_SHA, "stage pin mismatch")
    for key in ("files", "ops_files"):
        for name, expected in receipt[key].items():
            if read_only:
                prefixes = ("ops/",) if key == "ops_files" else ("candidate/target/", "candidate/packages/", "candidate/crates/ditto-generation/templates/", "contexts/")
                require(type(name) is str and name.startswith(prefixes), "BLOCKED_AUTH_BINDING")
            path = root / name
            require(path.resolve().is_relative_to(root.resolve()) and sha(path) == expected, "stage file mismatch")
    return receipt


def check_mode(root, mode):
    """Native readbacks bind actual test receipts to the staged byte tree."""
    directory = root / "evidence" / mode
    source = read(root / "stage.json")["source_facts"]
    context = read(directory / "physical-context.json")
    actual = context["source"]
    for key in ("commit", "dirty", "source_tree_sha256"):
        require(actual.get(key) == source.get(key), "native source/receipt mismatch")
    require(actual["commit"] == SOURCE and actual["dirty"] is False, "native candidate changed")
    require(context["evidence_class"] == "reference-physical-seat", "missing physical evidence class")
    require(read(directory / "summary.json").get("ok") is True, "mode summary failed/missing")
    require(read(directory / "private-recovery.json").get("status") == "verified", "private API restore unverified")
    if mode == "full":
        require(read(directory / "real-model.json").get("ok") is True, "real model failed/not_run")
        for pattern in ("host-*/summary.json", "native-failures-*/summary.json"):
            files = list(directory.glob(pattern))
            require(len(files) == 1, "missing/ambiguous native fault receipts")
            data = read(files[0])
            require(not data.get("error") and data.get("checks"), "native fault checks incomplete")
            require(all(not isinstance(c, dict) or c.get("status") == "pass" for c in data["checks"]), "native check failed/not_run")


def origin_worker(host):
    pid = os.getppid()
    for _ in range(16):
        w = witness(pid)
        if w and w["worker"]:
            require(len(host.workers()) == 1, "other active worker")
            return w
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        pid = int(fields[1])
        if pid <= 1:
            break
    raise Refused("launch must originate from the one runner Worker")


def launch(root, host):
    verify_stage(root)
    require(not (root / "state.json").exists(), "launch is single-use")
    from g3_auth import verified_realm
    store = verified_realm(root, host)
    report = preflight(root, host)
    origin = origin_worker(host)
    state = {"source": SOURCE, "origin": origin, "store": str(store), "deadline": time.time() + 2400,
             "normal_before": report["normal"], "runner_before": host.system("is-active", RUNNER, check=False),
             "modes": {mode: "not_run" for mode in MODES}, "delivery": "not_run", "recovery_complete": False}
    require(state["runner_before"] == "active", "origin runner not active")
    write(root / "state.json", state)
    helper = root / "ops/g3_ops.py"
    unit = "ditto-g3-qualification-" + root.name
    # A transient user service belongs to the user manager, not graphical
    # session or Worker. ExecStopPost runs also on crash and RuntimeMaxSec.
    host.command(["systemd-run", "--user", "--unit=" + unit, "--property=Type=exec", "--property=Restart=no",
                  "--property=RuntimeMaxSec=2400", "--property=TimeoutStopSec=360", "--property=KillMode=control-group",
                  "--property=MemoryMax=1G", "--property=MemorySwapMax=0", "--property=TasksMax=128", "--property=CPUQuota=200%", "--property=LimitFSIZE=268435456",
                  "--property=UMask=0077", "--property=StandardOutput=append:" + str(root / "controller.log"),
                  "--property=StandardError=append:" + str(root / "controller.log"),
                  "--property=ExecStopPost=/usr/bin/python3 " + str(helper) + " recover --id " + root.name[1:],
                  "/usr/bin/python3", str(helper), "control", "--id", root.name[1:]])
    write(root / "launch.json", {"source": SOURCE, "status": "launch_receipt_only", "unit": unit, "origin": origin})


def enter(root, host):
    state = read(root / "state.json")
    mode = state["mode"]
    host.private_live(state)
    if mode == "full":
        wait_ready(host.private_relay)
    directory = root / "evidence" / mode
    write(directory / "private-before.json", {"profile": core_result(host.private_relay("desktop.profiles.get")), "preferences": core_result(host.private_relay("agent.settings.describe")),
          "grant_ids": [g["grant_id"] for g in host.private_relay("desktop.permissions.list", {"subject": "agent", "include_revoked": True})["grants"]]})
    if mode == "full":
        require(host.private_relay("agent.providers.status", {"provider": "codex-app-server"}).get("authenticated") is True, "BLOCKED_EXISTING_SUBSCRIPTION_AUTH: no model call")
        host.private_relay("agent.runtime.stop")


def override(root):
    state = read(root / "state.json")
    require(state.get("disruption_armed") and not state.get("recovery_complete"), "override outside armed operation")
    binaries = root / "candidate/target/release" if state["mode"] == "full" else root / "contexts" / state["mode"]
    text = rewrite_template(TEMPLATE.read_text(), root / "candidate", binaries, Path(state["store"]))
    # Canonical printf no longer writes a partial/second drop-in.
    require(not DROPIN.exists(), "runtime override already exists")
    DROPIN.parent.mkdir(parents=True, exist_ok=True)
    with DROPIN.open("x") as stream:
        stream.write(text)


def run_seat(script, env, log_path, timeout):
    with log_path.open("w") as log:
        child = subprocess.Popen(["bash", str(script)], env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            # wait() on success reaps the leader only after its guarded
            # finally. On exceptions keep the PID reserved until killpg.
            return child.wait(timeout=timeout)
        except BaseException:
            try:
                os.killpg(child.pid, signal.SIGTERM)
                time.sleep(2)
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()
            raise


def control(root, host):
    state = read(root / "state.json")
    failure = None
    try:
        verify_stage(root)
        end = time.monotonic() + 300
        while not worker_gate(state["origin"], host.workers()):
            require(time.monotonic() < end, "origin Worker exit deadline")
            time.sleep(.5)  # /proc has no Worker-exit event exposed here.
        # Guard again immediately before stop. Never kill a Worker or match
        # broader patterns. Pause intent persists before the systemctl call.
        require(worker_gate(state["origin"], host.workers()), "Worker raced pause")
        state["pause_armed"] = True
        write(root / "state.json", state)
        host.pause_runner(state)
        require(not host.workers() and host.system("is-active", RUNNER, check=False) == "inactive", "runner pause failed")
        require(host.normal() == state["normal_before"], "normal baseline changed since launch")
        require(not DROPIN.exists(), "existing override before disruption")
        from g3_auth import verified_realm
        require(str(verified_realm(root, host)) == state["store"], "private auth binding changed after launch")
        host.command(["sudo", "-n", "cp", "-p", str(GDM), str(root / "gdm-original.conf")])
        # Bounded host-local SQLite snapshot; no auth files/keyring are copied.
        # Post-test v5 remains at exactly the original root; no downgrade.
        db = Path(state["store"]) / "data/core.db"
        require(db.stat().st_size <= 256 * 1024 * 1024, "private DB backup exceeds bound")
        require(shutil.disk_usage(root).free >= 512 * 1024 * 1024, "insufficient private backup/evidence space")
        with (db.parent / "core.lock").open("a") as writer_lock:
            fcntl.flock(writer_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            end = time.monotonic() + 30
            def progress(status, remaining, total):
                require(time.monotonic() < end and total * 4096 <= 512 * 1024 * 1024, "private backup deadline/size exceeded")
            with closing(sqlite3.connect(db.as_uri() + "?mode=ro", uri=True)) as original, closing(sqlite3.connect(root / "private-before.db")) as backup:
                original.backup(backup, pages=64, progress=progress)
        state["private_schema_before"] = schema(db)
        write(root / "state.json", state)
        for mode in MODES:
            require(time.time() < state["deadline"] - 240, "qualification hard deadline")
            directory = root / "evidence" / mode
            directory.mkdir(mode=0o700, parents=True)
            state.update(mode=mode, disruption_armed=True)
            state["modes"][mode] = "running"
            write(root / "state.json", state)
            env = dict(host.env, DITTO_ARTIFACTS=str(directory), DITTO_BINARIES=str(root / "candidate/target/release" if mode == "full" else root / "contexts" / mode),
                       DITTO_G3_SUBSCRIPTION_STORE=state["store"], DITTO_G3_ALLOW_REAL_MODEL="1", DITTO_G3_ALLOW_PHYSICAL_LOGIN="1",
                       DITTO_G3_REFERENCE_MODE=mode, DITTO_ENVIRONMENT_LABEL="reference-physical-seat")
            result = run_seat(root / "seat.sh", env, directory / "seat.log", 1500 if mode == "full" else 480)
            recovery = read(directory / "recovery.json")
            require(recovery["restore_exit"] == 0 and host.normal() == state["normal_before"], "per-mode normal recovery failed")
            require(host.system("is-active", RUNNER, check=False) == "inactive", "CI restarted before all modes")
            if result == 0:
                check_mode(root, mode)
            state["modes"][mode] = "passed" if result == 0 else "failed"
            state["private_schema_after"] = schema(db)
            write(root / "state.json", state)
            require(result == 0, "physical mode failed; no model retry")
            state["mode"] = None
            write(root / "state.json", state)
        state["disruption_armed"] = False  # canonical modes verified restoration
        write(root / "state.json", state)
    except Exception as error:
        failure = type(error).__name__
        state = read(root / "state.json")
        if state.get("mode") and state["modes"][state["mode"]] == "running":
            state["modes"][state["mode"]] = "failed"
        state["failure"] = failure
        state["failure_detail"] = str(error) if isinstance(error, Refused) else failure
        write(root / "state.json", state)
    finally:
        recovered = recover(root, host)
    if failure or recovered["recovery_status"] != "verified":
        raise Refused("qualification failed or recovery needs human; private evidence retained")
    dispatch(root, host)


def dispatch(root, host):
    state = read(root / "state.json")
    require(state.get("recovery_complete") and state.get("recovery_status") == "verified" and not state.get("failure"), "collector forbidden before verified recovery")
    require(all(state["modes"].get(m) == "passed" for m in MODES), "collector forbidden for incomplete modes")
    require(worker_gate(state["origin"], host.workers()), "collector races Worker")
    if state.get("delivery") in ("dispatched", "dispatch_intent", "BLOCKED_AUTO_DELIVERY"):
        return
    # Host's existing auth only. No GH_TOKEN/GITHUB_TOKEN env, polling or
    # callback secrets. The branch head must still equal the staged ops SHA.
    if host.command(["gh", "auth", "status"], check=False).returncode:
        state["delivery"] = "BLOCKED_AUTO_DELIVERY"
    else:
        ops_sha = read(root / "stage.json")["ops_sha"]
        reply = host.command(["gh", "api", "repos/relvo-labs/Ditto/git/ref/heads/" + BRANCH], check=False)
        if reply.returncode or json.loads(reply.stdout).get("object", {}).get("sha") != ops_sha:
            state["delivery"] = "BLOCKED_AUTO_DELIVERY"
        else:
            # Persist intent before dispatch. Never retry an ambiguous result.
            state["delivery"] = "dispatch_intent"
            write(root / "state.json", state)
            result = host.command(["gh", "workflow", "run", "nightly-refmachine.yml", "--repo", "relvo-labs/Ditto", "--ref", BRANCH,
                                   "-f", "phase=collect", "-f", "qualification_id=" + root.name[1:]], check=False)
            state["delivery"] = "dispatched" if result.returncode == 0 else "BLOCKED_AUTO_DELIVERY"
    write(root / "state.json", state)


def publish(root, destination):
    """Allowlist publication by construction. Raw JSON/logs/PNG remain private.

    Canonical grim captures the entire desktop. It cannot establish that a
    PNG is task-only, so this minimal collector deliberately publishes no PNG.
    Parent can inspect/crop screenshots host-locally under existing authority.
    """
    receipt = verify_stage(root)
    state = read(root / "state.json")
    require(state.get("source") == SOURCE, "source/receipt mismatch")
    require(state.get("recovery_complete") and state.get("recovery_status") == "verified", "collection before verified recovery")
    require(set(state["modes"]) == set(MODES), "mode receipt mismatch")
    statuses = {m: state["modes"][m] for m in MODES}
    require(all(v in ("passed", "failed", "not_run") for v in statuses.values()), "incomplete mode state")
    hashes = []
    for path in sorted((root / "evidence").rglob("*.json")):
        if path.name not in {"summary.json", "recovery.json", "normal-before.json", "normal-after.json", "desktop.json", "real-model.json", "physical-context.json"}:
            continue
        require(not path.is_symlink() and path.stat().st_size <= 16 * 1024 * 1024, "aliased/oversized evidence")
        raw = path.read_text()
        require(not SECRET.search(raw), "secret sentinel in evidence; collection refused")
        json.loads(raw)
        # Hashes retain provenance without publishing account/model traces.
        hashes.append(sha(path))
    output = {"format_version": 1, "source": SOURCE, "ops_sha": receipt["ops_sha"], "qualification_id": root.name[1:],
              "evidence_class": "reference-physical-seat", "modes": statuses, "recovery": "verified",
              "private_schema_before": state.get("private_schema_before"), "private_schema_after": state.get("private_schema_after"),
              "normal_schema": 4, "raw_evidence_sha256": hashes, "screenshots": "host_local_only", "logs": "host_local_only"}
    require(all(output[k] is None or type(output[k]) is int and output[k] in (4, 5) for k in ("private_schema_before", "private_schema_after")), "invalid private schema receipt")
    require(re.fullmatch(r"[a-f0-9]{40}", output["ops_sha"]), "invalid ops SHA")
    require(not SECRET.search(json.dumps(output)), "secret sentinel in publication")
    destination.mkdir(parents=True, exist_ok=True)
    write(destination / "receipt.json", output)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("phase", choices=("preflight", "stage", "launch", "collect", "control", "recover", "override", "enter", "leave", "auth_prepare", "auth_login", "auth_status", "auth_supervise", "auth_cleanup", "auth_reason", "bridge_probe_prepare", "bridge_probe", "bridge_probe_cleanup"))
    parser.add_argument("--id", required=True)
    args = parser.parse_args()
    require(os.getuid() == 1000 and Path.home() == Path("/home/neil") and socket.gethostname() == "neil-MotherBoard-Series", "fixed reference host required")
    os.umask(0o077)
    if args.phase.startswith("bridge_probe"):
        import g3_bridge_probe as probe
        probe.phase(args.phase, args.id)
        return
    if args.phase == "auth_reason":
        from g3_auth import auth_reason
        from g3_diagnostics import exception_reason
        try:
            root = run_root(args.id)
            require(root.is_dir() and root.stat().st_mode & 0o777 == 0o700, "BLOCKED_AUTH_BINDING")
            result = auth_reason(root)
        except Exception as error:
            print(json.dumps({"status": "BLOCKED_OR_FAILED", "reason": exception_reason(error, "BLOCKED_UNLISTED_REASON")}))
            sys.exit(2)
        print(json.dumps(result))
        return
    root = run_root(args.id)
    if args.phase in ("preflight", "stage"):
        BASE.mkdir(mode=0o700, parents=True, exist_ok=True)
        root.mkdir(mode=0o700, exist_ok=True)
    require(root.is_dir() and root.stat().st_mode & 0o777 == 0o700, "private task root required")
    host = Host(root)
    if args.phase in ("launch", "auth_prepare", "auth_login", "auth_status", "collect"):
        built = verify_stage(root)
        require(os.environ.get("GITHUB_SHA") == built["ops_sha"], "workflow SHA differs from staged operation")
    if args.phase in ("control", "recover", "override", "enter", "leave", "auth_supervise", "auth_cleanup"):
        require(HERE == root / "ops", "controller must use frozen task copy")
    if args.phase.startswith("auth_"):
        import g3_auth as auth
        if args.phase == "auth_supervise":
            def cancel(signum, frame):
                raise Refused("BLOCKED_AUTH_SIGNAL")
            signal.signal(signal.SIGTERM, cancel)
            signal.signal(signal.SIGINT, cancel)
            auth.supervisor(root, host)
            require(auth.public_status(root)["status"] == "verified", "BLOCKED_AUTH_OR_MODEL_VERIFICATION")
        elif args.phase == "auth_cleanup":
            require(auth.cleanup(root, host)["status"] != "needs_human", "BLOCKED_AUTH_CLEANUP")
        elif args.phase == "auth_status":
            print(json.dumps(auth.public_status(root)))
            return
        else:
            with (BASE / "qualification.lock").open("a") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                if args.phase == "auth_prepare":
                    result = auth.prepare(root, host)
                    print(json.dumps(result))  # public certificate, never code
                    return
                config_raw = os.environ.get("DITTO_G3_AUTH_TRANSPORT", "")
                require(len(config_raw) <= 16384, "BLOCKED_AUTH_TRANSPORT_SIZE")
                auth.start_login(root, host, json.loads(config_raw))
    elif args.phase == "control":
        def terminate(signum, frame):
            raise Refused("controller signal")
        signal.signal(signal.SIGTERM, terminate)
        signal.signal(signal.SIGINT, terminate)
        control(root, host)
    elif args.phase == "recover":
        require(recover(root, host)["recovery_status"] == "verified", "recovery needs human")
    elif args.phase == "override":
        override(root)
    elif args.phase == "enter":
        enter(root, host)
    elif args.phase == "leave":
        host.restore_private(read(root / "state.json"))
    elif args.phase == "collect":
        require(os.environ.get("GITHUB_SHA") == read(root / "stage.json")["ops_sha"], "collector workflow SHA differs from staged operation")
        publish(root, Path.cwd() / "artifacts/g3-qualification/publish")
    else:
        with (BASE / "qualification.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            {"preflight": preflight, "stage": stage, "launch": launch}[args.phase](root, host)
    output = {"phase": args.phase, "source": SOURCE, "qualification_id": args.id, "status": "phase_completed", "physical_success": False}
    if args.phase == "preflight":
        output["preflight"] = read(root / "preflight.json")
    elif args.phase == "stage":
        built = read(root / "stage.json")
        output.update(ops_sha=built["ops_sha"], source_facts=built["source_facts"], hashed_file_count=len(built["files"]))
    elif args.phase == "launch":
        output["launch"] = read(root / "launch.json")
    print(json.dumps(output))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # No arbitrary command output, paths, account identity or environment.
        if len(sys.argv) > 1 and sys.argv[1] in ("auth_prepare", "auth_login", "auth_status", "auth_supervise", "auth_cleanup", "auth_reason", "bridge_probe_prepare", "bridge_probe", "bridge_probe_cleanup"):
            from g3_diagnostics import exception_reason
            reason = exception_reason(error, "BLOCKED_UNLISTED_REASON")
        else:
            reason = str(error) if isinstance(error, Refused) else type(error).__name__
        print(json.dumps({"status": "BLOCKED_OR_FAILED", "reason": reason, "physical_success": False}))
        sys.exit(2)

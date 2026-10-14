"""Physical-seat observations. Never launches another compositor or Core."""
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[3]
OUT = pathlib.Path(os.environ["DITTO_ARTIFACTS"])


def command(*args):
    return subprocess.check_output(args, text=True, timeout=20).strip()


def ipc(method, params=None):
    return json.loads(command("python3", str(ROOT / "tools/compositor-probe/functional/wayfire-ipc.py"), method, json.dumps(params or {})))


def relay(method, params=None):
    response = json.loads(command("python3", str(ROOT / "tests/g1/lib/gui.py"), "relay", method, json.dumps(params or {})))
    assert "error" not in response, response
    return response["result"]


def process(pid):
    path = pathlib.Path(f"/proc/{pid}")
    # comm may contain spaces or parentheses; starttime is field 22.
    start = path.joinpath("stat").read_text().rsplit(")", 1)[1].split()[19]
    return {"pid": pid, "starttime": start, "exe": str(path.joinpath("exe").resolve()), "cgroup": path.joinpath("cgroup").read_text().strip()}


def snapshot():
    result = {}
    for name, unit in [("core", "ditto-core.service"), ("shell", "ditto-quickshell.scope"), ("hostd", "ditto-hostd.scope"), ("wayfire", "ditto-wayfire.scope")]:
        group = command("systemctl", "--user", "show", unit, "-p", "ControlGroup", "--value")
        assert group, unit
        pids = (pathlib.Path("/sys/fs/cgroup") / group.lstrip("/") / "cgroup.procs").read_text().split()
        assert pids, unit
        result[name] = [process(int(pid)) for pid in pids]
    if os.environ.get("DITTO_G3_APP_PID"):
        result["native_application"] = [process(int(os.environ["DITTO_G3_APP_PID"]))]
    result["revision"] = relay("desktop.profiles.get")["profile"]["head_revision"]
    result["windows"] = relay("desktop.windows.list")
    return result


def unchanged(before, after):
    for key in ["core", "shell", "hostd", "wayfire", "native_application", "revision"]:
        if key in before:
            assert before[key] == after[key], (key, before[key], after[key])
    assert any(w["app_id"] == "ditto-g3-survival" for w in after["windows"]["windows"]), after


def guard():
    session = os.environ["XDG_SESSION_ID"]
    details = dict(line.split("=", 1) for line in command("loginctl", "show-session", session, "-p", "Seat", "-p", "Active", "-p", "Type", "-p", "Name").splitlines())
    assert details == {"Name": "neil", "Seat": "seat0", "Type": "wayland", "Active": "yes"}, details
    outputs = ipc("window-rules/list-outputs")
    assert outputs and all("HEADLESS" not in o["name"].upper() for o in outputs), outputs
    assert any(o["geometry"]["width"] == 1920 and o["geometry"]["height"] == 1080 for o in outputs), outputs
    connected = [str(p.parent) for p in pathlib.Path("/sys/class/drm").glob("card*-*/status") if p.read_text().strip() == "connected"]
    assert connected, "no connected DRM output"
    core_pid = int(command("systemctl", "--user", "show", "ditto-core.service", "-p", "MainPID", "--value"))
    assert pathlib.Path(f"/proc/{core_pid}/exe").resolve() == pathlib.Path(os.environ["DITTO_BINARIES"]) / "ditto-core", "unexpected Core installation"
    entries = pathlib.Path(f"/proc/{core_pid}/environ").read_bytes().split(b"\0")
    data = next(e.split(b"=", 1)[1].decode() for e in entries if e.startswith(b"DITTO_DATA_DIR="))
    assert data == os.environ["DITTO_G3_SUBSCRIPTION_STORE"], data
    native = pathlib.Path(os.environ["DITTO_BINARIES"]) / "ditto-generation-runner"
    result = {"evidence_class": "reference-physical-seat", "session": session, "logind": details, "outputs": outputs, "connected_drm": connected, "private_store": data, "source": json.loads(command("python3", str(ROOT / "tests/g3/source.py"))), "native_sha256": hashlib.sha256(native.read_bytes()).hexdigest() if native.is_file() else None, "before": snapshot(), "keyboard_source": "Wayfire stipc synthetic input; no human-keyboard claim"}
    pathlib.Path(os.environ["DITTO_G3_PHYSICAL_CONTEXT"]).write_text(json.dumps(result, indent=2) + "\n")


def preview():
    views = ipc("window-rules/list-views")
    view = next(v for v in views if "Ditto 插件預覽" in v.get("title", "") and v.get("mapped"))
    ipc("window-rules/focus-view", {"id": view["id"]})
    for key in ["KEY_TAB", "KEY_SPACE"]:
        command("python3", str(ROOT / "tests/g1/lib/gui.py"), "key", key)
    time.sleep(.3)
    subprocess.run(["grim", str(OUT / "visible-preview.png")], check=True, timeout=10)
    after = ipc("window-rules/list-views")
    assert any(v["id"] == view["id"] and v.get("mapped") for v in after), after
    (OUT / "visible-preview.json").write_text(json.dumps({"before": view, "after": after, "keyboard": ["Tab", "Space"], "screenshot": "visible-preview.png"}, indent=2) + "\n")


def cancel_previews():
    # Opening a center is a Shell-owned command; only real keyboard input
    # presses its buttons. Readback is exclusively the authoritative Core.
    import socket
    with socket.socket(socket.AF_UNIX) as connection:
        connection.connect(str(pathlib.Path(os.environ["DITTO_RUNTIME_DIR"]) / "shell.sock"))
        connection.sendall(b"command plugins.open\n")
    time.sleep(.7)
    observations = []
    for index, job_id in enumerate(sys.argv[2:]):
        focus = json.loads(command("python3", str(ROOT / "tests/g1/lib/gui.py"), "tab-to", "關閉測試資料預覽"))
        subprocess.run(["grim", str(OUT / f"preview-cancel-{index}.png")], check=True, timeout=10)
        command("python3", str(ROOT / "tests/g1/lib/gui.py"), "press", "enter")
        for _ in range(100):
            job = relay("desktop.jobs.get", {"job_id": job_id})
            if job["state"] == "cancelled":
                break
            time.sleep(.05)
        assert job["state"] == "cancelled", job
        observations.append({"job_id": job_id, "keyboard_focus": focus, "readback": job})
    command("python3", str(ROOT / "tests/g1/lib/gui.py"), "key", "KEY_ESC")
    (OUT / "preview-keyboard-cancellation.json").write_text(json.dumps(observations, indent=2) + "\n")


if __name__ == "__main__":
    {"guard": guard, "preview": preview, "cancel-previews": cancel_previews}[sys.argv[1]]()

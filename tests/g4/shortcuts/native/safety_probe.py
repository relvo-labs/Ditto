import os, subprocess, json, time, pathlib, sys, signal
from wfipc import Client, press
out=pathlib.Path("/evidence");run=pathlib.Path("/tmp/d190");run.mkdir(mode=0o700,exist_ok=True)
os.environ.update(XDG_RUNTIME_DIR=str(run),WLR_BACKENDS="headless",WLR_RENDERER="pixman",WLR_HEADLESS_OUTPUTS="1",WLR_LIBINPUT_NO_DEVICES="1",_WAYFIRE_SOCKET=str(run/"wf.sock"),WAYFIRE_SOCKET=str(run/"wf.sock"),HOME="/tmp",LIBGL_ALWAYS_SOFTWARE="1",WLR_RENDERER_ALLOW_SOFTWARE="1",LD_LIBRARY_PATH="/opt/qs-lib:/opt/qt/lib",QT_PLUGIN_PATH="/opt/qt/plugins",QML_IMPORT_PATH="/opt/qt/qml",QT_QPA_PLATFORM="wayland",QT_QUICK_BACKEND="software",QT_WAYLAND_DISABLE_WINDOWDECORATION="1")
os.environ.pop("DISPLAY",None)
children=[]; steps=[]
def mark(name, **values):
 steps.append(dict(step=name,**values));print(json.dumps(steps[-1]),flush=True)
try:
 wf=subprocess.Popen(["wayfire","-c","/work/wayfire.ini"],stdout=(out/"logs/wayfire-native.log").open("w"),stderr=subprocess.STDOUT);children.append(wf)
 time.sleep(1)
 if wf.poll() is not None: raise RuntimeError("Wayfire exited")
 os.environ["WAYLAND_DISPLAY"]=next(p.name for p in run.glob("wayland-*") if p.is_socket())
 c=Client();listener=Client();register=listener.call("command/register-binding",{"binding":"<super> KEY_SPACE"});mark("binding",reply=register)
 version=subprocess.check_output(["/opt/qt/bin/quickshell","--version"],text=True,stderr=subprocess.STDOUT).strip();mark("runtime",quickshell=version,wayfire=subprocess.check_output(["wayfire","--version"],text=True).strip(),break_grab=c.call("wayfire/get-config-option",{"option":"shortcuts-inhibit/break_grab"}))
 qs=subprocess.Popen(["/opt/qt/bin/quickshell","-p","/work/Probe.qml"],stdout=(out/"logs/quickshell-native.log").open("w"),stderr=subprocess.STDOUT);children.append(qs)
 time.sleep(1)
 if qs.poll() is not None: raise RuntimeError("Quickshell exited")
 def ipc(method):
  reply=subprocess.run(["/opt/qt/bin/quickshell","ipc","--pid",str(qs.pid),"call","probe",method],text=True,capture_output=True,timeout=5)
  if reply.returncode: raise RuntimeError(reply.stdout+reply.stderr)
  return json.loads(reply.stdout) if method=="status" else reply.stdout
 def views(): return c.call("window-rules/list-views")
 def focus(title):
  view=next(v for v in views() if v.get("title")==title)
  c.call("window-rules/focus-view",{"id":view["id"]});time.sleep(0.15)
  return c.call("window-rules/get-focused-view")
 mark("windows",views=views());focus("ditto-shortcut-probe-190-recorder")
 press(c,"KEY_LEFTMETA","KEY_SPACE");outside=listener.events(0.2);mark("outside",binding_events=outside,status=ipc("status"));assert len(outside)==1
 ipc("start");time.sleep(0.2);state=ipc("status");mark("active",status=state,focus=c.call("window-rules/get-focused-view"));assert state["active"] and state["focus"]
 press(c,"KEY_LEFTMETA","KEY_SPACE");during=listener.events(0.2);state=ipc("status");mark("during",binding_events=during,status=state);assert not during and any(e["kind"]=="down" and e["details"]["scan"]==65 and e["details"]["active"] for e in state["events"])
 ipc("cancel");press(c,"KEY_LEFTMETA","KEY_SPACE");after=listener.events(0.2);mark("cancel_restores",binding_events=after,status=ipc("status"));assert len(after)==1
 ipc("start");time.sleep(0.15);ipc("other");time.sleep(0.15);mark("focus_loss",focus=focus("ditto-shortcut-probe-190-other"),status=ipc("status"));assert not ipc("status")["active"]
 press(c,"KEY_LEFTMETA","KEY_SPACE");after=listener.events(0.2);assert len(after)==1
 focus("ditto-shortcut-probe-190-recorder");assert not ipc("status")["active"]
 ipc("start");time.sleep(0.15);ipc("destroy");time.sleep(0.15);press(c,"KEY_LEFTMETA","KEY_SPACE");after=listener.events(0.2);mark("destroy_restores",binding_events=after,status=ipc("status"));assert len(after)==1
 ipc("recreate");time.sleep(0.2);focus("ditto-shortcut-probe-190-recorder")
 reserved={}
 for name,binding in [("lock","<super> KEY_L"),("rescue","<super> KEY_ESC"),("escape","<super> <shift> KEY_ESC")]:
  reserved[name]=listener.call("command/register-binding",{"binding":binding})
 mark("reserved_counter_bindings",bindings=reserved)
 ipc("start");time.sleep(0.2);press(c,"KEY_LEFTMETA","KEY_L");blocked=listener.events(0.2)
 mark("default_inhibition_also_blocks_lock",binding_events=blocked);assert not blocked
 c.call("wayfire/set-config-options",{"input/xkb_layout":"de"});time.sleep(0.2)
 press(c,"KEY_LEFTCTRL","KEY_Y");state=ipc("status")
 last=[e for e in state["events"] if e["kind"]=="down"][-1]
 mark("physical_key_under_german_layout",keydown=last,layout=c.call("wayfire/get-config-option",{"option":"input/xkb_layout"}));assert last["details"]["scan"]==29 and last["details"]["key"]==90
 c.call("wayfire/set-config-options",{"input/xkb_layout":"us","shortcuts-inhibit/break_grab":"<super> <shift> KEY_ESC"});time.sleep(0.2)
 mark("probe_only_escape_configuration",readback=c.call("wayfire/get-config-option",{"option":"shortcuts-inhibit/break_grab"}))
 os.kill(qs.pid,signal.SIGSTOP)
 press(c,"KEY_LEFTMETA","KEY_SPACE");frozen=listener.events(0.2);assert not frozen
 press(c,"KEY_LEFTMETA","KEY_LEFTSHIFT","KEY_ESC");escape=listener.events(0.2)
 press(c,"KEY_LEFTMETA","KEY_L");lock=listener.events(0.2)
 os.kill(qs.pid,signal.SIGCONT);time.sleep(0.2)
 mark("compositor_escape_with_qml_frozen",before_escape=frozen,escape_events=escape,lock_events=lock,status=ipc("status"));assert len(lock)==1 and not ipc("status")["active"]
 c.call("wayfire/set-config-options",{"shortcuts-inhibit/ignore_views":"all"});time.sleep(0.2)
 ipc("start");time.sleep(0.3);refused=ipc("status");mark("refused_by_compositor_policy",status=refused);assert not refused["active"]
 ipc("cancel");c.call("wayfire/set-config-options",{"shortcuts-inhibit/ignore_views":"none","shortcuts-inhibit/break_grab":"none"})
 (out/"native-probe.json").write_text(json.dumps({"passed":True,"input":"Wayfire stipc virtual keyboard; not physical/RustDesk","scope":"generic binding counter, not Ditto launcher/Core save","steps":steps},indent=2))
except Exception as error:
 mark("exception",error=repr(error));(out/"native-probe.json").write_text(json.dumps({"passed":False,"steps":steps},indent=2));raise
finally:
 for child in reversed(children):
  child.terminate()
  try: child.wait(timeout=4)
  except subprocess.TimeoutExpired: child.kill();child.wait(timeout=4)

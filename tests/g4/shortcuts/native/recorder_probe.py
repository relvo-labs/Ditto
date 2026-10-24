import os, subprocess, json, time, pathlib, sys
from wfipc import Client, press
out=pathlib.Path("/evidence");run=pathlib.Path("/tmp/d190");run.mkdir(mode=0o700,exist_ok=True)
os.environ.update(XDG_RUNTIME_DIR=str(run),WLR_BACKENDS="headless",WLR_RENDERER="pixman",WLR_HEADLESS_OUTPUTS="1",WLR_LIBINPUT_NO_DEVICES="1",_WAYFIRE_SOCKET=str(run/"wf.sock"),WAYFIRE_SOCKET=str(run/"wf.sock"),HOME="/tmp",LIBGL_ALWAYS_SOFTWARE="1",WLR_RENDERER_ALLOW_SOFTWARE="1",LD_LIBRARY_PATH="/opt/qs-lib:/opt/qt/lib",QT_PLUGIN_PATH="/opt/qt/plugins",QML_IMPORT_PATH="/opt/qt/qml",QT_QPA_PLATFORM="wayland",QT_QUICK_BACKEND="software",QT_WAYLAND_DISABLE_WINDOWDECORATION="1")
os.environ.pop("DISPLAY",None)
children=[]; steps=[]
def mark(name, **values):
 steps.append(dict(step=name,**values));print(json.dumps(steps[-1]),flush=True)
try:
 wf=subprocess.Popen(["wayfire","-c","/work/wayfire.ini"],stdout=(out/"logs/wayfire-recorder.log").open("w"),stderr=subprocess.STDOUT);children.append(wf)
 time.sleep(1)
 if wf.poll() is not None: raise RuntimeError("Wayfire exited")
 os.environ["WAYLAND_DISPLAY"]=next(p.name for p in run.glob("wayland-*") if p.is_socket())
 c=Client();listener=Client();register=listener.call("command/register-binding",{"binding":"<super> KEY_SPACE"});mark("binding",reply=register)
 version=subprocess.check_output(["/opt/qt/bin/quickshell","--version"],text=True,stderr=subprocess.STDOUT).strip();mark("runtime",quickshell=version,wayfire=subprocess.check_output(["wayfire","--version"],text=True).strip(),break_grab=c.call("wayfire/get-config-option",{"option":"shortcuts-inhibit/break_grab"}))
 qs=subprocess.Popen(["/opt/qt/bin/quickshell","-p","/work/RecorderProbe.qml"],stdout=(out/"logs/quickshell-recorder.log").open("w"),stderr=subprocess.STDOUT);children.append(qs)
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
 mark("resource_limits", **{name:pathlib.Path("/sys/fs/cgroup/"+name).read_text().strip() for name in ["cpu.max","memory.max","pids.max"]})
 mark("windows",views=views());focus("ditto-shortcut-probe-190-recorder")
 initial=ipc("status");mark("fail_closed_before_safety_witness",status=initial);assert initial["phase"]=="unavailable" and not initial["active"]
 press(c,"KEY_LEFTMETA","KEY_SPACE");outside=listener.events(0.2);mark("outside",binding_events=outside);assert len(outside)==1
 c.call("wayfire/set-config-options",{"shortcuts-inhibit/break_grab":"<super> <shift> KEY_ESC"});time.sleep(0.2)
 mark("escape_verified_before_start",readback=c.call("wayfire/get-config-option",{"option":"shortcuts-inhibit/break_grab"}))
 ipc("start");time.sleep(0.2);state=ipc("status");mark("active",status=state,focus=c.call("window-rules/get-focused-view"));assert state["active"] and state["focus"]
 subprocess.run(["grim","/evidence/recorder-active.png"],check=True,timeout=5)
 press(c,"KEY_LEFTMETA","KEY_SPACE");during=listener.events(0.3);state=ipc("status");mark("captured_draft_without_action",binding_events=during,status=state);assert not during and state["lastChord"]=="Super+Space" and state["capturedCount"]==1 and not state["active"]
 subprocess.run(["grim","/evidence/recorder-captured.png"],check=True,timeout=5)
 press(c,"KEY_LEFTMETA","KEY_SPACE");after=listener.events(0.2);mark("release_restores",binding_events=after);assert len(after)==1
 ipc("narrow");time.sleep(0.3);focus("ditto-shortcut-probe-190-recorder");ipc("start");time.sleep(0.2)
 c.call("stipc/feed_key", {"key":"KEY_LEFTCTRL","state":True});c.call("stipc/feed_key", {"key":"KEY_LEFTALT","state":True});time.sleep(0.2)
 state=ipc("status");mark("modifiers_provisional",status=state);assert state["active"] and state["capturedCount"]==1 and state["width"]==360
 subprocess.run(["grim","/evidence/recorder-narrow-modifiers.png"],check=True,timeout=5)
 c.call("stipc/feed_key", {"key":"KEY_K","state":True});time.sleep(0.2)
 state=ipc("status");mark("requires_key_release",status=state);assert state["phase"]=="releasing" and state["capturedCount"]==1
 subprocess.run(["grim","/evidence/recorder-narrow-release.png"],check=True,timeout=5)
 for key in ["KEY_K","KEY_LEFTALT","KEY_LEFTCTRL"]: c.call("stipc/feed_key", {"key":key,"state":False})
 time.sleep(0.2);state=ipc("status");mark("ctrl_alt_k",status=state);assert state["lastChord"]=="Ctrl+Alt+K" and state["capturedCount"]==2
 ipc("english");ipc("start");time.sleep(0.2);subprocess.run(["grim","/evidence/recorder-narrow-en.png"],check=True,timeout=5)
 ipc("disconnect");time.sleep(0.2);state=ipc("status");mark("disconnect_releases",status=state);assert not state["active"] and state["lastChord"]=="Ctrl+Alt+K"
 c.call("wayfire/set-config-options",{"shortcuts-inhibit/ignore_views":"all"});time.sleep(0.2)
 ipc("start");time.sleep(1.8);state=ipc("status");mark("refused_is_unavailable",status=state);assert not state["active"] and state["phase"]=="unavailable" and state["capturedCount"]==2
 subprocess.run(["grim","/evidence/recorder-refused.png"],check=True,timeout=5)
 c.call("wayfire/set-config-options",{"shortcuts-inhibit/ignore_views":"none"});time.sleep(0.2);assert not ipc("status")["active"]
 ipc("start");time.sleep(0.2);press(c,"KEY_ESC");time.sleep(0.2);mark("escape_keeps_draft",status=ipc("status"));assert ipc("status")["lastChord"]=="Ctrl+Alt+K" and not ipc("status")["active"]
 press(c,"KEY_LEFTMETA","KEY_SPACE");assert len(listener.events(0.2))==1
 ipc("start");time.sleep(0.2);watcher=Client();watcher.call("window-rules/events/watch",{"events":["view-mapped"]});ipc("other");mapped=watcher.events(2);mark("other_mapped",events=mapped,views=views());focus("ditto-shortcut-probe-190-other");state=ipc("status");mark("focus_loss",status=state);assert not state["active"]
 focus("ditto-shortcut-probe-190-recorder");assert not ipc("status")["active"]
 ipc("start");time.sleep(0.2);ipc("destroy");time.sleep(0.2);press(c,"KEY_LEFTMETA","KEY_SPACE");after=listener.events(0.2);mark("destroy_restores",status=ipc("status"),binding_events=after);assert len(after)==1
 (out/"recorder-native.json").write_text(json.dumps({"passed":True,"input":"Wayfire stipc virtual keyboard; not physical/RustDesk","scope":"Real production recorder module with generic binding counter, not Ditto launcher/Core save","steps":steps},indent=2))

except Exception as error:
 mark("exception",error=repr(error));(out/"recorder-native.json").write_text(json.dumps({"passed":False,"steps":steps},indent=2));raise
finally:
 for child in reversed(children):
  child.terminate()
  try: child.wait(timeout=4)
  except subprocess.TimeoutExpired: child.kill();child.wait(timeout=4)

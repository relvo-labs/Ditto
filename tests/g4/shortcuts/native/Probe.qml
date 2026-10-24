import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
ShellRoot {
 id: root
 property var events: []
 function report(kind, details) { const value={kind:kind,details:details}; events=events.concat([value]); console.log("PROBE " + JSON.stringify(value)); }
 IpcHandler {
  target: "probe"
  function start(): void { recLoader.item.start(); }
  function cancel(): void { recLoader.item.stop(); }
  function other(): void { second.visible=true; }
  function destroy(): void { recLoader.active=false; }
  function recreate(): void { recLoader.active=true; }
  function status(): string { return JSON.stringify({window:!!recLoader.item, active:recLoader.item ? recLoader.item.inhibited : false, focus:recLoader.item ? recLoader.item.inputFocus : false, events:root.events}); }
 }
 LazyLoader {
  id: recLoader
  active: true
  FloatingWindow {
   id: rec
   readonly property bool inhibited: inhibit.active
   readonly property bool inputFocus: capture.activeFocus
   function start() { root.report("request",{}); inhibit.enabled=true; }
   function stop() { inhibit.enabled=false;root.report("cancel",{}); }
   title: "ditto-shortcut-probe-190-recorder"
   implicitWidth:700; implicitHeight:480; visible:true; color:"#eee9fb"
   Component.onDestruction: root.report("destroy",{})
   Item {
    id: capture
    anchors.fill:parent; focus:true
    Text { anchors.centerIn:parent; text:"#190 native capability probe\nActive: " + inhibit.active; font.pixelSize:28; color:"#302746" }
    Keys.onPressed: event => { root.report("down",{key:event.key,scan:event.nativeScanCode,modifiers:event.modifiers,repeat:event.isAutoRepeat,active:inhibit.active});event.accepted=true; }
    Keys.onReleased: event => { root.report("up",{key:event.key,scan:event.nativeScanCode,modifiers:event.modifiers,active:inhibit.active});event.accepted=true; }
    Component.onCompleted: forceActiveFocus()
   }
   ShortcutInhibitor {
    id: inhibit
    window:rec; enabled:false
    onActiveChanged: root.report("active",{active:active,enabled:enabled})
    onCancelled: {root.report("cancelled",{});enabled=false;}
   }
  }
 }
 FloatingWindow { id:second;title:"ditto-shortcut-probe-190-other";implicitWidth:300;implicitHeight:200;visible:false;Text{text:"Focus-loss control"} }
}

import QtQuick
import Quickshell
import Quickshell.Io
import "shell/ui" as Ui
import "shell/jelly" as Jelly
ShellRoot {
 id: root
 property string lastChord: ""
 property var completions: []
 property var reserved: []
 property int capturedCount: 0
 property bool english: false
 property bool narrowMode: false
 FileView { id: catalogue; path: Qt.resolvedUrl("shell/i18n/ditto_en.json").toString().replace("file://", "") }
 Jelly.Tokens { id: sceneTokens; readsSystemPreference:false; appearance:({theme:"soft-jelly-light",tokens:{},locale:"zh-TW"}) }
 QtObject { id: nativeClient;signal disconnected();function t(source) {return root.english ? (JSON.parse(catalogue.text()).strings[source] || source) : source;} }
 IpcHandler {
  target:"probe"
  function start():void { rec.item.safetyReady=true;rec.item.start(); }
  function narrow():void { rec.active=false;root.narrowMode=true;rec.active=true; }
  function english():void { root.english=true; rec.item.actionTitle="Launcher · native fixture (not applied)"; }
  function disconnect():void { nativeClient.disconnected(); }
  function cancel():void { rec.item.cancel(); }
  function other():void { second.visible=true; }
  function destroy():void { rec.active=false; }
  function recreate():void { rec.active=true; }
  function status():string { return JSON.stringify({window:!!rec.item,width:rec.item ? rec.item.width : 0,height:rec.item ? rec.item.height : 0,phase:rec.item ? rec.item.phase : "destroyed",active:rec.item ? rec.item.inhibited : false,focus:rec.item ? rec.item.inputFocus : false,lastChord:root.lastChord,capturedCount:root.capturedCount,completions:root.completions,reserved:root.reserved}); }
 }
 LazyLoader {
  id:rec;active:true
  Ui.ShortcutRecorder {
   implicitWidth:root.narrowMode ? 360 : 520
   client:nativeClient;tokens:sceneTokens;actionTitle:"啟動器 · native fixture（尚未套用）"
   title:"ditto-shortcut-probe-190-recorder"
   safetyReady:false
   reservedBindings:[{chord:"Super+L",command:"session.lock"},{chord:"Super+Escape",command:"rescue.open"},{chord:"Super+Shift+Escape",command:"rescue.open"}]
   onCaptured: chord => {root.lastChord=chord;root.capturedCount++;console.log("CAPTURED "+chord);}
   onReservedPressed: chord => {root.reserved=root.reserved.concat([chord]);console.log("RESERVED "+chord);}
   onFinished: reason => {root.completions=root.completions.concat([reason]);console.log("FINISHED "+reason);}
  }
 }
 FloatingWindow {id:second;title:"ditto-shortcut-probe-190-other";implicitWidth:300;implicitHeight:200;visible:false;Text{text:"Focus-loss control"}}
}

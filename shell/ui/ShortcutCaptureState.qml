import QtQuick

/// Transient key state only. Native codes are Qt Wayland XKB codes (evdev + 8),
/// verified by the #190 real Wayfire probe, including a German Y/Z layout.
/// Values below name the existing wayfire_bindings.rs KEY_* subset, not text.
QtObject {
    id: state
    property string phase: "idle"
    property bool requested: false
    property var held: ({})
    property string candidate: ""
    property string issue: ""
    property bool invalid: false
    property int activation: 0
    property bool priming: false
    property var reserved: []
    readonly property bool listening: phase === "arming" || phase === "recording" || phase === "releasing"
    readonly property var modifiers: modifierNames(held)
    signal captured(string chord)
    signal reservedPressed(string chord)
    signal stopped(string reason)

    readonly property var modifierCodes: ({29:"Ctrl",97:"Ctrl",42:"Shift",54:"Shift",56:"Alt",125:"Super",126:"Super"})
    readonly property var keyNames: ({
        1:"Escape",2:"1",3:"2",4:"3",5:"4",6:"5",7:"6",8:"7",9:"8",10:"9",11:"0",14:"Backspace",15:"Tab",
        16:"Q",17:"W",18:"E",19:"R",20:"T",21:"Y",22:"U",23:"I",24:"O",25:"P",28:"Enter",
        30:"A",31:"S",32:"D",33:"F",34:"G",35:"H",36:"J",37:"K",38:"L",
        44:"Z",45:"X",46:"C",47:"V",48:"B",49:"N",50:"M",57:"Space",
        59:"F1",60:"F2",61:"F3",62:"F4",63:"F5",64:"F6",65:"F7",66:"F8",67:"F9",68:"F10",87:"F11",88:"F12",
        102:"Home",103:"Up",104:"PageUp",105:"Left",106:"Right",107:"End",108:"Down",109:"PageDown",111:"Delete"
    })
    function modifierNames(keys) {
        const names = Object.keys(keys).map(code => modifierCodes[code]);
        return ["Super","Ctrl","Alt","Shift"].filter(name => names.indexOf(name) >= 0);
    }
    function begin(activationKey) {
        held = ({}); candidate = ""; issue = ""; invalid = false;
        activation = activationKey === Qt.Key_Enter ? 96 : activationKey === Qt.Key_Return ? 28 : activationKey === Qt.Key_Space ? 57 : 0;
        priming = activation > 0;
        if (priming) { const initial = {}; initial[activation] = true; held = initial; }
        phase = "requesting"; requested = true;
    }
    function grant() { if (requested && phase === "requesting") phase = priming ? "arming" : "recording"; }
    function stop(reason) {
        if (!requested && phase !== "idle") return;
        requested = false; held = ({}); candidate = ""; activation = 0; priming = false;
        phase = reason === "unavailable" ? "unavailable" : "cancelled";
        stopped(reason);
    }
    function press(scan, repeat, qtModifiers) {
        if (!listening || repeat) return;
        const code = scan - 8;
        if (held[code]) return;
        if (priming) { const opening = Object.assign({}, held); opening[code] = true; held = opening; return; }
        if (Object.keys(held).length === 0) issue = "";
        if (code === 1 && modifiers.length === 0) { stop("escape"); return; }
        const next = Object.assign({}, held); next[code] = true; held = next;
        if (modifierCodes[code]) {
            if (candidate) { issue = "multiple"; invalid = true; }
            return;
        }
        if (!keyNames[code]) { issue = "unsupported"; invalid = true; return; }
        let known = 0;
        const masks = {Super:Qt.MetaModifier,Ctrl:Qt.ControlModifier,Alt:Qt.AltModifier,Shift:Qt.ShiftModifier};
        for (const name of modifiers) known |= masks[name];
        if ((qtModifiers || 0) & (Qt.MetaModifier | Qt.ControlModifier | Qt.AltModifier | Qt.ShiftModifier | Qt.GroupSwitchModifier) & ~known) {
            issue = "release-first"; invalid = true; return; // modifiers held before this recording are not guessed
        }
        if (candidate.length > 0) { issue = "multiple"; invalid = true; return; }
        candidate = modifiers.concat([keyNames[code]]).join("+");
        phase = "releasing";
    }
    function release(scan, repeat, qtModifiers) {
        if (repeat) return;
        const code = scan - 8;
        if (priming) {
            const opening = Object.assign({}, held); delete opening[code]; held = opening;
            if (code === activation) activation = 0;
            if (activation === 0 && Object.keys(held).length === 0 && !qtModifiers) {
                priming = false;
                if (phase === "arming") phase = "recording";
            }
            return;
        }
        if (!listening) return;
        const next = Object.assign({}, held); delete next[code]; held = next;
        if (Object.keys(held).length > 0) return;
        if (!invalid && candidate) {
            const chord = candidate;
            requested = false; phase = "captured";
            if (reserved.indexOf(chord) >= 0) reservedPressed(chord); else captured(chord);
            return;
        }
        candidate = ""; invalid = false; phase = "recording";
    }
}

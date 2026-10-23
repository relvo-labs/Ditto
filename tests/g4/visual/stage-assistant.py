#!/usr/bin/env python3
"""Stage actual Shell surfaces for offscreen tests; record every adaptation.

No runtime fixture is evidence of a real Core turn or a compositor focus grab.
Only layer-shell attached properties are removed; FloatingWindow is replaced
by an explicitly recorded Item double. Legacy sources are pinned to 25c0b72.
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
OUT = HERE / '.staged/assistant'
BASE = '25c0b726ef3c3bc7c8e00232514604cc0498007e'
# The merged R1/R3 base includes the statusForeground contrast correction.
# Keep the old rendering oracle above, but require untouched avatar source
# against the actual motion lease base, rather than rejecting that merged fix.
MOTION_BASE = 'f99b4ea0db5ceff1ef98956b7e32895784746157'
OUT.mkdir(parents=True, exist_ok=True)
(HERE / '.staged/out').mkdir(parents=True, exist_ok=True)
capture_out = Path(os.environ.get('DITTO_ASSISTANT_CAPTURE_OUT', HERE / '.staged/out')).resolve()
capture_out.mkdir(parents=True, exist_ok=True)
(OUT / 'capture-output.js').write_text('var outDir = ' + json.dumps(str(capture_out) + '/') + ';\n')
report = []


def source(path, base=False):
    return subprocess.check_output(['git', 'show', f'{BASE}:{path}'], cwd=ROOT).decode() if base else (ROOT / path).read_text()


def stage(path, destination, base=False):
    text = source(path, base)
    removed = []
    lines = []
    for n, line in enumerate(text.splitlines(), 1):
        if re.match(r'\s*(import Quickshell.Wayland\s*$|WlrLayershell\.\w+\s*:)', line):
            removed.append({'line': n, 'text': line})
        else:
            if 'ExclusionMode.Ignore' in line:
                removed.append({'line': n, 'text': line, 'replacement': 'ExclusionMode.Ignore -> 0 (stub enum)'})
                line = line.replace('ExclusionMode.Ignore', '0')
            lines.append(line)
    target = OUT / destination
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text('\n'.join(lines) + '\n')
    report.append({'source': (BASE + ':' if base else '') + path,
                   'sha256': hashlib.sha256(text.encode()).hexdigest(),
                   'destination': str(target.relative_to(HERE)), 'removed': removed})


for directory in ['chat', 'ui', 'change', 'assistant', 'jelly', 'avatar']:
    shutil.copytree(ROOT / 'shell' / directory, OUT / 'shell' / directory, dirs_exist_ok=True)
# Pin the actual pre-candidate default button, including its symbol. The
# unchanged jelly implementation is shared; do not derive an oracle from the
# candidate's entryStyle flag.
candidate_base = 'de8d6176690b472cc0cd101af9bf6d1a6a3b51e8'
shutil.copytree(ROOT / 'shell/jelly', OUT / 'baseline/shell/jelly', dirs_exist_ok=True)
for name in ['AssistantEntry.qml', 'AssistantSymbol.qml']:
    path = 'shell/assistant/' + name
    text = subprocess.check_output(['git', 'show', f'{candidate_base}:{path}'], cwd=ROOT).decode()
    target = OUT / 'baseline' / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text)
    report.append({'source': candidate_base + ':' + path, 'sha256': hashlib.sha256(text.encode()).hexdigest(),
                   'destination': str(target.relative_to(HERE)), 'removed': []})
for name in ['chat/ChatPanel.qml', 'assistant/AssistantSurface.qml']:
    stage('shell/' + name, 'shell/' + name)
for name in ['ChatPanel.qml', 'ChatBody.qml']:
    stage('shell/chat/' + name, 'legacy/chat/' + name, True)
shutil.copytree(ROOT / 'shell/ui', OUT / 'legacy/ui', dirs_exist_ok=True)
shutil.copytree(ROOT / 'shell/change', OUT / 'legacy/change', dirs_exist_ok=True)
stage('shell/avatar/Avatar.qml', 'legacy/avatar/Avatar.qml', True)
shutil.copytree(ROOT / 'shell/avatar/layers', OUT / 'legacy/avatar/layers', dirs_exist_ok=True)
shutil.copytree(HERE / 'stubs', OUT / 'stubs', dirs_exist_ok=True)
(OUT / 'stubs/Quickshell/FloatingWindow.qml').write_text('''import QtQuick
Item {
    property string title: ""
    property size minimumSize: Qt.size(0, 0)
    property color color: "transparent"
    signal closed()
    width: implicitWidth
    height: implicitHeight
    Rectangle { anchors.fill: parent; color: parent.color; z: -1 }
}
''')
shutil.copyfile(OUT / 'stubs/Quickshell/FloatingWindow.qml', OUT / 'shell/chat/FloatingWindow.qml')
with (OUT / 'stubs/Quickshell/qmldir').open('a') as f:
    f.write('\nFloatingWindow 1.0 FloatingWindow.qml\n')
report.append({'adaptation': 'FloatingWindow Item double; no real window decorations or focus ownership'})
# Structural oracle: the entire legacy avatar surface body is unchanged.
base_shell = source('shell/shell.qml', True)
current_shell = source('shell/shell.qml')
start = '        PanelWindow {\n            id: avatarSurface'
end = '\n    /// The shell\'s control path:'
assert base_shell[base_shell.index(start):base_shell.index(end)] == current_shell[current_shell.index(start):current_shell.index(end)]
assert subprocess.check_output(['git', 'show', f'{MOTION_BASE}:shell/avatar/Avatar.qml'], cwd=ROOT).decode() == source('shell/avatar/Avatar.qml')
# ApprovalWindow.qml: #116 adds candidate visuals (opt-in DITTO_UI_STYLE). The
# decision semantics stay pinned to 25c0b72: every line that decides or moves
# focus is still present verbatim, and an added decision may only refuse.
# Unset-style pixels are compared with 87a2462 by unit/tst_ui_style_off.qml.
approval_base = source('shell/chat/ApprovalWindow.qml', True).splitlines()
approval_now = source('shell/chat/ApprovalWindow.qml').splitlines()
decisive = lambda line: 'decided(' in line or 'forceActiveFocus' in line or 'onEscapePressed' in line
for line in filter(decisive, approval_base):
    assert line in approval_now, 'approval decision line changed: ' + line.strip()
added = [line for line in filter(decisive, approval_now) if line not in approval_base]
assert all('decided("rejected")' in line for line in added), added
report.append({'oracle': 'ApprovalWindow decision/focus/Escape lines match 25c0b72 verbatim; added decisions only refuse',
               'added': [line.strip() for line in added]})
# UI-P02 moves only the background block out of shell.qml. Reconstruct the
# exact d063f03 text before applying the original 366f174 oracle below.
P02_BASE = 'd063f0357bfd3dc96e707072fe9e74c8722e3c98'
p02_shell = subprocess.check_output(['git', 'show', f'{P02_BASE}:shell/shell.qml'], cwd=ROOT).decode()
background_pattern = r'    Variants \{\n        model: Quickshell\.screens\n\n        PanelWindow \{.*?\n        \}\n    \}'
old_backgrounds = re.findall(background_pattern, p02_shell, re.S)
assert len(old_backgrounds) == 1, 'expected exactly one base background block'
old_background = old_backgrounds[0]
fallback_instance = '''    BackgroundFallback {
        providers: root.shellProviders
        tokens: root.shellTokens
    }'''
assert current_shell.count(fallback_instance) == 1, 'background fallback instance changed'
reconstructed_shell = current_shell.replace(fallback_instance, old_background, 1)
# UI-P03b changes only the Centers input from the controller to its facade.
# Reverse that exact line before the pinned whole-file comparison; all other
# Shell wiring and the extracted background oracle remain byte-for-byte checks.
settings_input = '            aiSettings: root.shellConversation.aiSettings'
legacy_settings_input = '            conversation: root.shellConversation'
assert reconstructed_shell.count(settings_input) == 1, 'AI settings facade input changed'
reconstructed_shell = reconstructed_shell.replace(settings_input, legacy_settings_input, 1)
assert reconstructed_shell == p02_shell, 'shell.qml changed outside the pinned background extraction'
report.append({'oracle': 'UI-P03b changes only the Centers input to ConversationState.aiSettings',
               'from': legacy_settings_input, 'to': settings_input})

# Check the extracted implementation independently: no arbitrary new behavior
# can be hidden by replacing its instance with the old text above.
fallback_source = source('shell/core/BackgroundFallback.qml')
substitutions = [
    ('color: tokens.background', 'color: fallback.tokens.background'),
    ('root.shellTokens', 'fallback.tokens'),
]
additions = [
    '            visible: fallback.shown',
    '            mask: Region {}',
    '            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None',
]
expected_background = old_background
for before, after in substitutions:
    assert before in expected_background, 'base background substitution target missing'
    expected_background = expected_background.replace(before, after)
namespace_line = '            WlrLayershell.namespace: "ditto-background"'
expected_background = expected_background.replace(namespace_line, namespace_line + '\n' + '\n'.join(additions), 1)
fallback_backgrounds = re.findall(background_pattern, fallback_source, re.S)
assert fallback_backgrounds == [expected_background], 'extracted background body changed beyond the allowed adaptations'
expected_header = '''import QtQuick
import Quickshell
import Quickshell.Wayland
import "../jelly"

/// Trusted compatibility background; never reported as a loaded package.
Scope {
    id: fallback
    required property var providers
    required property var tokens
    readonly property bool shown: !providers.backgroundShown
'''
assert fallback_source == expected_header + expected_background + '\n}\n', 'background fallback wrapper changed'
report.append({
    'oracle': 'UI-P02 reconstruction equals d063f03 shell.qml byte for byte; extracted background matches the base with only these adaptations',
    'base': P02_BASE,
    'reconstructed_sha256': hashlib.sha256(reconstructed_shell.encode()).hexdigest(),
    'component': 'shell/core/BackgroundFallback.qml',
    'component_sha256': hashlib.sha256(fallback_source.encode()).hexdigest(),
    'substitutions': [{'from': before, 'to': after} for before, after in substitutions],
    'additions': additions,
    'wrapper': 'Scope with providers/tokens and shown: !providers.backgroundShown, pinned verbatim',
})
current_shell = reconstructed_shell

# Owner adoption may change only the AssistantSurface instance in shell.qml.
pre_choice = subprocess.check_output(['git', 'show', '366f1743e3b165df0c210f89e7b9e671176e25a8:shell/shell.qml'], cwd=ROOT).decode()
pattern = r'        AssistantSurface \{.*?\n        \}'
selected = re.search(pattern, current_shell, re.S).group(0)
previous = re.search(pattern, pre_choice, re.S).group(0)
assert 'entryStyle: "fab"' in selected and 'symbolVariant: "ditto"' in selected
# PR #115 (87a2462, owner-chosen wallpaper) changed exactly one other hunk: the
# background Backdrop's comment and `wallpaperSource`. Swap that block back,
# after checking it differs only there, so the oracle still rejects any other
# shell.qml change.
backdrop = r'            /// The canvas.*?\n            Backdrop \{.*?\n            \}'
backdrop_now = re.search(backdrop, current_shell, re.S).group(0)
backdrop_before = re.search(backdrop, pre_choice, re.S).group(0)
assert backdrop_now.splitlines()[3:] == [line.replace('wallpaperSource: ""', 'wallpaperSource: root.shellTokens.wallpaper')
                                         for line in backdrop_before.splitlines()[3:]]
assert current_shell.replace(selected, previous, 1).replace(backdrop_now, backdrop_before, 1) == pre_choice
report.append({'oracle': 'shell.qml changes only AssistantSurface properties; fixed 56/E1 lives in the component, legacy mounting unchanged'})

report.append({'oracle': 'legacy avatar surface matches 25c0b72; Avatar.qml matches f99b4ea byte for byte (merged statusForeground correction)'})
(OUT / 'staging.json').write_text(json.dumps(report, indent=2) + '\n')
print('assistant staged; legacy structure matches 25c0b72; approval decisions unchanged')

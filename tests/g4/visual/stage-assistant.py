#!/usr/bin/env python3
"""Stage actual Shell surfaces for offscreen tests; record every adaptation.

No runtime fixture is evidence of a real Core turn or a compositor focus grab.
Only layer-shell attached properties are removed; FloatingWindow is replaced
by an explicitly recorded Item double. Legacy sources are pinned to 25c0b72.
"""
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
OUT = HERE / '.staged/assistant'
BASE = '25c0b726ef3c3bc7c8e00232514604cc0498007e'
OUT.mkdir(parents=True, exist_ok=True)
(HERE / '.staged/out').mkdir(parents=True, exist_ok=True)
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
assert source('shell/avatar/Avatar.qml', True) == source('shell/avatar/Avatar.qml')
assert source('shell/chat/ApprovalWindow.qml', True) == source('shell/chat/ApprovalWindow.qml')
report.append({'oracle': 'legacy avatar surface, Avatar.qml, ApprovalWindow.qml match 25c0b72 byte for byte'})
(OUT / 'staging.json').write_text(json.dumps(report, indent=2) + '\n')
print('assistant staged; legacy structure and approval match 25c0b72')

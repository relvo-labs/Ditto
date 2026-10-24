#!/usr/bin/env python3
"""Stage the two launcher providers for real Quickshell offscreen (#188).

    stage-launcher.py <out-dir>

Real Quickshell has no PanelWindow backend without a Wayland compositor, so
the launchers' layer-shell window becomes a FloatingWindow. Everything else
stays as written: the real Quickshell module resolves `Quickshell.iconPath`
and serves `image://icon/...`, and the providers' own iconSource,
iconFallback and sourceSize bindings run unchanged. Each substitution below
must match exactly the expected number of lines or staging fails; the removed
and replaced lines are written to <out-dir>/staging.json with source hashes.

The one added line exposes the window (`stagedSurface`) so the test can find
the icons; Quickshell's Scope children list cannot be walked from JavaScript.
"""
import hashlib
import json
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[2]
out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)

# (pattern, replacement or None to drop the line, expected count)
RULES = [
    (r'^import Quickshell\.Wayland$', None, 1),
    (r'^\s*WlrLayershell\.\w+\s*:.*$', None, 3),
    (r'^(\s*)PanelWindow \{$', r'\1FloatingWindow {', 1),
    (r'^(\s*)anchors \{ top: true; bottom: true; left: true; right: true \}$', r'\1implicitWidth: 1280; implicitHeight: 800', 1),
    (r'^\s*exclusionMode: ExclusionMode\.Ignore$', None, 1),
    (r'^\s*focusable: true$', None, 1),
    (r'^(\s*)id: provider$', r'\1id: provider\n\1readonly property alias stagedSurface: surface', 1),
]
PROVIDERS = [
    'shell/providers/launcher_grid/qml/LauncherGrid.qml',
    'shell/providers/launcher_search/qml/LauncherSearch.qml',
]

report = []
for relative in PROVIDERS:
    source = (root / relative).read_text()
    counts = [0] * len(RULES)
    changes, lines = [], []
    for number, line in enumerate(source.split('\n'), 1):
        for index, (pattern, replacement, _) in enumerate(RULES):
            if re.match(pattern, line):
                counts[index] += 1
                staged = None if replacement is None else re.sub(pattern, replacement, line)
                changes.append({'line': number, 'text': line, 'staged': staged})
                line = staged
                break
        if line is not None:
            lines.append(line)
    for (pattern, _, expected), count in zip(RULES, counts):
        if count != expected:
            sys.exit(f'{relative}: {pattern!r} matched {count} line(s), expected {expected}')
    staged = '\n'.join(lines)
    if re.search(r'WlrLayershell|WlrKeyboardFocus|WlrLayer\b|PanelWindow|ExclusionMode', staged):
        sys.exit(f'{relative}: a layer-shell reference is left after staging')
    target = out / Path(relative).name
    target.write_text(staged)
    report.append({'source': relative, 'source_sha256': hashlib.sha256(source.encode()).hexdigest(),
                   'staged': target.name, 'staged_sha256': hashlib.sha256(staged.encode()).hexdigest(),
                   'changes': changes})
    print(f'staged {relative}: {len(changes)} line(s) changed')
(out / 'staging.json').write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')

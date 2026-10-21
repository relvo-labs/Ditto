#!/usr/bin/env python3
"""Stage production sources, recording the offscreen-only transformations."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys

root = Path(__file__).resolve().parents[2]
out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
for directory, source in [('shell', root / 'shell'), ('stubs', root / 'tests/g4/visual/stubs'), ('unit', root / 'tests/shell-extensions/unit'), ('fixtures', root / 'tests/shell-extensions/fixtures')]:
    if (out / directory).exists():
        shutil.rmtree(out / directory)
    shutil.copytree(source, out / directory, symlinks=True)
report = []
for path in (out / 'shell').rglob('*.qml'):
    if path.is_symlink() or 'lock' in path.parts or 'rescue' in path.parts:
        continue
    source = path.read_text()
    removed = []
    lines = []
    for number, line in enumerate(source.splitlines(), 1):
        if re.match(r'^\s*(import Quickshell\.Wayland\s*$|WlrLayershell\.\w+\s*:)', line):
            removed.append({'line': number, 'text': line})
        else:
            lines.append(line)
    staged = '\n'.join(lines) + '\n'
    # Only this SDK import changes: real Quickshell is tested separately.
    sdk_import = 'import "root:/sdk/Ditto/Ui"'
    replacement = f'import "file://{out}/shell/sdk/Ditto/Ui"'
    staged = staged.replace(sdk_import, replacement)
    if staged != source:
        report.append({'path': str(path.relative_to(out)), 'source_sha256': hashlib.sha256(source.encode()).hexdigest(), 'removed': removed, 'sdk_import_rewritten': sdk_import in source})
        path.write_text(staged)
# Variants' delegate lifecycle is model-driven. Window/input/layer semantics
# remain stub observations; no compositor guarantees are inferred here.
(out / 'stubs/Quickshell/Variants.qml').write_text('import QtQml.Models\nInstantiator {}\n')
with (out / 'stubs/Quickshell/qmldir').open('a') as f:
    f.write('Variants 1.0 Variants.qml\n')
(out / 'staging.json').write_text(json.dumps(report, indent=2) + '\n')

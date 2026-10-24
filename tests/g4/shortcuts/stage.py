import hashlib, json, re, shutil, sys
from pathlib import Path
root = Path(__file__).resolve().parents[3]
source = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
out.mkdir(parents=True, exist_ok=True)
for name, directory in [("shell", source / "shell"), ("stubs", root / "tests/g4/visual/stubs")]:
    shutil.copytree(directory, out / name, dirs_exist_ok=True)
report = []
for path in (out / "shell").rglob("*.qml"):
    if path.is_symlink(): continue
    original = path.read_text()
    changed = original if path.name == 'ShortcutRecorder.qml' else re.sub(r'^\s*(import Quickshell\.Wayland\s*$|WlrLayershell\.\w+\s*:.*$)', '', original, flags=re.M)
    changed = changed.replace('import "root:/sdk/Ditto/Ui"', 'import "' + (out / 'shell/sdk/Ditto/Ui').as_uri() + '"')
    if changed != original: path.write_text(changed)
    report.append({"path": str(path.relative_to(out)), "sha256": hashlib.sha256(original.encode()).hexdigest(), "transformed": changed != original})
for p in (root / "tests/g4/shortcuts").glob("*.qml"): shutil.copy2(p, out / p.name)
catalogues = []
for var, name in [("zh", "ditto_zh_TW"), ("en", "ditto_en")]:
    catalogues.append("var " + var + " = " + (source / 'shell/i18n' / (name + '.json')).read_text() + ";")
(out / 'catalogues.js').write_text('.pragma library\n' + '\n'.join(catalogues))
(out / 'staging.json').write_text(json.dumps(report, indent=2))

(out / 'captures').mkdir(exist_ok=True)
(out / 'capture-config.js').write_text('.pragma library\nvar label = ' + json.dumps(sys.argv[3] if len(sys.argv) > 3 else 'recorder') + ';\n')

shutil.copytree(root / 'tests/g4/shortcuts/recorder-stubs', out / 'stubs', dirs_exist_ok=True)

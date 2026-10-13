#!/usr/bin/env bash
set +e
cd ~/.local/share/ditto/packages 2>/dev/null && find . -maxdepth 3 -type d | grep -i launcher | head
for f in $(find ~/.local/share/ditto/packages -name 'Launcher*.qml' 2>/dev/null); do echo "$f $(grep -c 'launcher.frame' $f) $(sha256sum $f | cut -c1-12)"; done
for f in ~/funlab/Ditto/target/ditto-packages*/ditto.launcher.search*/qml/*.qml ~/funlab/Ditto/target/ditto-packages*/*/*/qml/LauncherSearch.qml; do [ -f "$f" ] && echo "$f $(grep -c 'launcher.frame' $f)"; done
ls ~/funlab/Ditto/target/ditto-packages-verification | head -30
python3 - <<'PY'
import sqlite3, json, os
c=sqlite3.connect(f"file:{os.path.expanduser('~/.local/share/ditto/core.db')}?mode=ro", uri=True)
for r in c.execute("select package_id,version,substr(sha256,1,12),substr(tree_sha256,1,12),source,installed_at from plugin_packages where package_id like '%launcher%'"): print(r)
doc=json.loads(c.execute("select document_json from revisions r join profiles p on p.head_revision=r.revision_id").fetchone()[0])
for e in doc['entries']:
    if 'launcher' in json.dumps(e): print(json.dumps(e)[:300])
PY
journalctl --user -b -o cat --no-pager | grep -i -E 'launcher' | grep -v ditto-rpc | tail -5

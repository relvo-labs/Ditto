#!/usr/bin/env bash
set +e
cd ~/funlab/Ditto
r() { timeout 30 python3 tests/g1/lib/gui.py relay "$1" "${2:-{\}}" 2>&1; }
for c in chg-01M4T0B9ERWCHNAYDHF6CAWGQQ chg-01M4RA3R1P83CXH0CMCP6C7KHP; do echo "== $c"; r desktop.changes.get "{\"change_id\":\"$c\"}" | jq -c '.result | {state,origin_kind,ops:(.ops|length),reasons,card,failure_key,items}' | head -c 4000; echo; done
python3 - <<'PY'
import sqlite3, os, json
c=sqlite3.connect(f"file:{os.path.expanduser('~/.local/share/ditto/core.db')}?mode=ro", uri=True)
for r in c.execute("select change_id,state,reasons_json,failure_key,substr(ops_json,1,300),origin_kind from changesets where change_id in ('chg-01M4T0B9ERWCHNAYDHF6CAWGQQ','chg-01M4RA3R1P83CXH0CMCP6C7KHP','chg-01M4RA0WAP8SSWGGQJ0AYFR88S')"): print(r)
PY

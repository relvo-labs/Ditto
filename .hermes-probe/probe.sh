#!/usr/bin/env bash
set +e
echo "== sessions"; loginctl list-sessions --no-legend
systemctl --user list-units --plain --no-legend 'ditto-*' | cut -c1-60
python3 - <<'PY'
import sqlite3, os
c=sqlite3.connect(f"file:{os.path.expanduser('~/.local/share/ditto/core.db')}?mode=ro", uri=True)
print(c.execute("select state,failure_key,result_kind,substr(reasons_json,1,300) from changesets where change_id='chg-01M4T31F6DPHT6NZSNFGEX10FV'").fetchone())
for r in c.execute("select seq,participant,step,state,substr(readback_json,1,300) from operations where change_id='chg-01M4T31F6DPHT6NZSNFGEX10FV' order by seq"): print(r)
PY
journalctl --user --since '2026-10-13 15:36:00' --until '2026-10-13 15:37:30' -o cat --no-pager | grep -v ditto-rpc | grep -i -E 'chg-01M4T31|abort|participant|shell|unreachable|compositor' | cut -c1-250 | head -15

#!/usr/bin/env bash
# Temporary read-only probe (not for merge).
set +e
echo "== sessions"; loginctl list-sessions --no-legend
echo "== user env"; systemctl --user show-environment | grep -E '^(WAYLAND_DISPLAY|XDG_SESSION_DESKTOP|XDG_CURRENT_DESKTOP)='
echo "== drm"; for c in /sys/class/drm/card*-*; do printf '%s %s %s\n' "$(basename $c)" "$(cat $c/status 2>/dev/null)" "$(cat $c/dpms 2>/dev/null)"; done
echo "== store"; ls -la ~/.local/share/ditto/ 2>&1 | head
python3 - <<'PY'
import sqlite3, json, os
db=os.path.expanduser('~/.local/share/ditto/core.db')
c=sqlite3.connect(f'file:{db}?mode=ro', uri=True)
tabs=[r[0] for r in c.execute("select name from sqlite_master where type='table'")]
print('tables', tabs)
for t in tabs:
    cols=[r[1] for r in c.execute(f'pragma table_info("{t}")')]
    print(' ', t, cols, c.execute(f'select count(*) from "{t}"').fetchone()[0])
seen=0
for t in tabs:
    for row in c.execute(f'select * from "{t}"'):
        for v in row:
            if isinstance(v, bytes):
                try: v=v.decode()
                except Exception: continue
            if isinstance(v,str) and '"shortcuts"' in v:
                try:
                    d=json.loads(v)
                except Exception:
                    continue
                def find(o):
                    if isinstance(o,dict):
                        if 'shortcuts' in o: return o['shortcuts']
                        for x in o.values():
                            r=find(x)
                            if r is not None: return r
                    if isinstance(o,list):
                        for x in o:
                            r=find(x)
                            if r is not None: return r
                print('  ', t, row[0] if not isinstance(row[0],(bytes,)) else '', json.dumps(find(d),ensure_ascii=False)[:300])
                seen+=1
print('docs with shortcuts', seen)
PY
echo "== wayfire output config"; grep -n -A4 'output:' ~/funlab/Ditto/packaging/reference-image/session/wayfire.ini

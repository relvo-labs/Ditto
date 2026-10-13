#!/usr/bin/env bash
set +e
python3 - <<'PY'
import sqlite3, json, os
db=os.path.expanduser('~/.local/share/ditto/core.db')
c=sqlite3.connect(f'file:{db}?mode=ro', uri=True)
for pid,name,head in c.execute('select profile_id,name,head_revision from profiles'):
    doc=json.loads(c.execute('select document_json from revisions where revision_id=?',(head,)).fetchone()[0])
    print('profile',pid,name,head,'created', c.execute('select created_at from revisions where revision_id=?',(head,)).fetchone())
    print(' shortcuts',json.dumps(doc.get('shortcuts'),ensure_ascii=False))
    print(' avatar',json.dumps(doc.get('avatar'),ensure_ascii=False)[:300])
    print(' slots',json.dumps(doc.get('slots'),ensure_ascii=False)[:400])
print('agent prefs', c.execute('select settings_json from agent_preferences').fetchone())
PY
echo "== firefox crash counters"; grep -h -E 'recent_crashes|max_resumed|last_success|safe' ~/snap/firefox/common/ditto-g0-reference-profile/prefs.js 2>&1 | head
echo "== journal 13:52 core"; journalctl --user --since '2026-10-13 13:52:30' --until '2026-10-13 13:53:00' -o short-iso --no-pager | grep -v -E 'ditto-rpc|keysym|xkbcomp|keycode' | cut -c1-250 | head -30
echo "== journal earlier first-frame (phase A start of ff)"; journalctl --user --since '2026-10-13 13:52:00' --until '2026-10-13 13:52:45' -o short-iso --no-pager | grep -i -E 'mark|chat|toggle|command' | head

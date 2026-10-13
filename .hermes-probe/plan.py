#!/usr/bin/env python3
"""Plan one ChangeSet that brings the active Profile to protocol 0.3:
upgrade each entry to its newest installed built-in accepting 0.3, remove
entries with none. stdin: desktop.profiles.get response; argv[1]: core.db."""
import json, re, sqlite3, sys

doc = json.load(sys.stdin)["result"]["document"]
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
PROTO = (0, 3, 0)

def ver(v):
    return tuple(int(x) for x in re.match(r"(\d+)\.(\d+)\.(\d+)", v).groups())

def accepts(rng):
    m = re.fullmatch(r"\^(\d+)\.(\d+)(?:\.(\d+))?", (rng or "").strip())
    if not m:
        return False
    lo = (int(m[1]), int(m[2]), int(m[3] or 0))
    hi = (lo[0] + 1, 0, 0) if lo[0] else (0, lo[1] + 1, 0)
    return lo <= PROTO < hi

ops, notes = [], []
for e in doc["entries"]:
    rows = db.execute("select version, manifest_json, source from plugin_packages where package_id=?", (e["package"],)).fetchall()
    current = [json.loads(m) for v, m, s in rows if v == e["version"]]
    if current and accepts(current[0].get("required_protocol_version")):
        continue
    cands = sorted((ver(v), v) for v, m, s in rows if s == "builtin" and accepts(json.loads(m).get("required_protocol_version")))
    if cands:
        ops.append({"op": "upgrade_entry", "entry_id": e["entry_id"], "from_version": e["version"], "to_version": cands[-1][1]})
        notes.append(f"upgrade {e['package']} {e['version']}->{cands[-1][1]}")
    else:
        ops.append({"op": "remove_entry", "entry_id": e["entry_id"]})
        notes.append(f"remove {e['package']} {e['version']} (no 0.3 build)")
print(json.dumps({"ops": ops, "notes": notes}, ensure_ascii=False))

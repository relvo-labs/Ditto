#!/usr/bin/env bash
# G2 exit runs on the reference machine (temporary, not for merge):
#  0. checkout to the PR head; bring the live Profile to the G2 built-ins
#     (its G1 entries need protocol ^0.2, so preflight rejects every change)
#     and give it the G2 default Super+A chat binding; change ids recorded
#  1. temporary GDM autologin; EX2-14: 4 states x 3 cold logins (series.sh)
#  2. a fresh normal login: EX2-13 (200 chat, 200 launcher), EX2-12 (30+5),
#     semantic sets fixed + holdout with Firefox
#  3. GDM configuration restored byte-identical, machine at the login screen
set -uo pipefail
st=$HOME/.local/state/ditto-g2-exit; mkdir -p "$st"; ts=$(date -u +%Y%m%dT%H%M%SZ)
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$st/phase-b.log"; }
cd ~/funlab/Ditto
r() { timeout 60 python3 tests/g1/lib/gui.py relay "$1" "${2:-{\}}"; }
git fetch -q origin && git merge -q --ff-only origin/codex/g2-agent-foundation || { log "checkout not fast-forwardable"; exit 1; }
log "phase-b start at $(git rev-parse HEAD) dirty=$(git status --porcelain | wc -l)"
cargo build --locked --release -p ditto-measure 2>&1 | tail -1

# 0. the live Profile. Its G1 built-ins require protocol ^0.2, so preflight
# rejects every change (protocol_incompatible), and desktop.profiles.upgrade
# answers not_found because some entries (G1 test fixtures) have no build for
# 0.3. One ChangeSet: upgrade each entry to its newest installed built-in that
# accepts 0.3; remove the entries that have none (recorded; undoable).
head=$(r desktop.profiles.get | jq -r .result.profile.head_revision)
log "profile head before: $head"
plan=$(r desktop.profiles.get | python3 -c '
import sys, json, sqlite3, os, re
doc = json.load(sys.stdin)["result"]["document"]
db = sqlite3.connect("file:" + os.path.expanduser("~/.local/share/ditto/core.db") + "?mode=ro", uri=True)
proto = (0, 3, 0)
def ver(v): return tuple(int(x) for x in re.match(r"(\d+)\.(\d+)\.(\d+)", v).groups())
def ok(rng):
    rng = rng.strip()
    m = re.fullmatch(r"\^(\d+)\.(\d+)(?:\.(\d+))?", rng)
    if m:
        lo = (int(m[1]), int(m[2]), int(m[3] or 0))
        hi = (lo[0] + 1, 0, 0) if lo[0] else (0, lo[1] + 1, 0)
        return lo <= proto < hi
    return None
ops, notes = [], []
for e in doc["entries"]:
    rows = db.execute("select version, manifest_json, source from plugin_packages where package_id=?", (e["package"],)).fetchall()
    cur = [json.loads(m) for v, m, s in rows if v == e["version"]]
    if cur and ok(cur[0].get("required_protocol_version", "")):
        continue
    cands = sorted((ver(v), v) for v, m, s in rows if s == "builtin" and ok(json.loads(m).get("required_protocol_version", "")))
    if cands:
        ops.append({"op": "upgrade_entry", "entry_id": e["entry_id"], "from_version": e["version"], "to_version": cands[-1][1]})
        notes.append(f"upgrade {e['package']} {e['version']}->{cands[-1][1]}")
    else:
        ops.append({"op": "remove_entry", "entry_id": e["entry_id"]})
        notes.append(f"remove {e['package']} {e['version']} (no 0.3 build)")
print(json.dumps({"ops": ops, "notes": notes}, ensure_ascii=False))
')
log "profile plan: $(jq -c .notes <<<"$plan")"
if [[ "$(jq '.ops|length' <<<"$plan")" != 0 ]]; then
  res=$(r desktop.changes.propose "$(jq -cn --arg b "$head" --argjson ops "$(jq -c .ops <<<"$plan")" '{base_revision:$b, ops:$ops, idempotency_key:"g2-exit-profile-0.3-2026-10-13"}')")
  log "profile change: $(jq -c '(.result|{change_id,state,reasons}) // .error' <<<"$res" | head -c 2500)"
  [[ "$(jq -r .result.state <<<"$res")" == committed ]] || exit 1
fi
doc=$(r desktop.profiles.get); head=$(jq -r .result.profile.head_revision <<<"$doc")
if ! jq -e '.result.document.shortcuts[]? | select(.chord=="Super+A")' <<<"$doc" >/dev/null; then
  after=$(jq -c '.result.document.shortcuts + [{chord:"Super+A",command:"chat.toggle"}]' <<<"$doc")
  res=$(r desktop.changes.propose "$(jq -cn --arg b "$head" --argjson a "$after" '{base_revision:$b, idempotency_key:"g2-exit-super-a-2026-10-13", ops:[{op:"set_value",path:"/shortcuts",after:$a}]}')")
  log "Super+A change: $(jq -c '.result|{change_id,state,reasons}' <<<"$res" | head -c 800)"
  [[ "$(jq -r .result.state <<<"$res")" == committed ]] || exit 1
fi
log "profile head after: $(r desktop.profiles.get | jq -r .result.profile.head_revision)"

# 1. autologin + series
sudo -n cp -p /etc/gdm3/custom.conf "$st/custom.conf.orig-$ts"
sha=$(sha256sum /etc/gdm3/custom.conf | cut -d' ' -f1); log "custom.conf sha256 $sha"
restore() {
  sudo -n cp -p "$st/custom.conf.orig-$ts" /etc/gdm3/custom.conf
  if [[ "$(sha256sum /etc/gdm3/custom.conf | cut -d' ' -f1)" == "$sha" ]]; then log "gdm custom.conf restored byte-identical ($sha)"; else log "RESTORE MISMATCH"; fi
  bash tests/g1/measure/cold-login.sh reset >/dev/null 2>&1
  log "relogin to the login screen"; sudo -n /usr/local/libexec/ditto-relogin >>"$st/phase-b.log" 2>&1
  log "phase-b done"
}
trap restore EXIT
sudo -n python3 -c "
p='/etc/gdm3/custom.conf'; s=open(p).read()
assert 'AutomaticLoginEnable=True' not in s
s=s.replace('[daemon]\n','[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=neil\n',1)
open(p,'w').write(s)"
log "autologin enabled"
clean=(env -u WAYLAND_DISPLAY -u XDG_SESSION_DESKTOP -u DISPLAY)
"${clean[@]}" DITTO_ARTIFACTS="$PWD/artifacts/g2-ref-exit" DITTO_SERIES_FINAL_RELOGIN=0 DITTO_LOGIN_TIMEOUT_SECONDS=600 \
  bash tests/g1/measure/series.sh rescue_no_node desktop_full_no_agent desktop_full_agent_warm desktop_full_agent_active
log "series exit $?"

# 2. a fresh normal login
DITTO_ARTIFACTS="$PWD/artifacts/g2-ref-exit" bash tests/g1/measure/cold-login.sh reset
old=$(bash tests/g1/measure/cold-login.sh login-id 2>/dev/null)
sudo -n /usr/local/libexec/ditto-relogin
for i in $(seq 1 120); do
  cur=$(bash tests/g1/measure/cold-login.sh login-id 2>/dev/null)
  [[ -n "$cur" && "$cur" != "$old" ]] && bash tests/g1/measure/cold-login.sh ready desktop_full_no_agent >/dev/null 2>&1 && break
  sleep 5
done
log "fresh login $cur ready"; sleep 60
python3 tests/g2/measure/first-frame-session.py 200 chat 2>&1 | tee -a "$st/phase-b.log"
python3 tests/g2/measure/first-frame-session.py 200 launcher 2>&1 | tee -a "$st/phase-b.log"
node tests/g2/measure/cold-start-session.mjs 30 5 2>&1 | tail -3 | tee -a "$st/phase-b.log"
bash tests/g2/semantic/run.sh --tasks fixed 2>&1 | grep -E 'semantic|not_run' | tee -a "$st/phase-b.log"
bash tests/g2/semantic/run.sh --tasks holdout 2>&1 | grep -E 'semantic|not_run' | tee -a "$st/phase-b.log"
log "phase-b runs done"

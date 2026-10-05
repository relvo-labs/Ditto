#!/usr/bin/env bash
# Self-test of series.sh with stubs: no login manager, no session, no sudo.
# A stub cold-login.sh keeps its "logins" in a state directory; the stub
# relogin starts the next one. Checked:
#   ① every state ends with three runs from three different logins, then one report;
#   ② a failed sample is retried in a new login, never in the same one;
#   ③ interrupted after a few relogins, a second invocation resumes and does
#     not redo recorded runs;
#   ④ a login that never becomes ready counts as a failure, and too many
#     failures stop the series with a non-zero status;
#   ⑤ at the end the conditions are reset and one final relogin is made.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ditto-series-test.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT

cat >"$work/cold-login.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
dir="$STUB_DIR"
login="$(cat "$dir/login" 2>/dev/null || echo 0)"
echo "$* login=$login" >>"$dir/calls"
case "$1" in
  prepare) echo "$2" >"$dir/prepared" ;;
  reset) rm -f "$dir/prepared"; echo reset >>"$dir/resets" ;;
  login-id) [[ "$login" != 0 ]] && echo "boot:$login" ;;
  ready)
    # Login numbers listed in never-ready do not come up.
    ! grep -qx "$login" "$dir/never-ready" 2>/dev/null
    ;;
  count)
    if [[ -f "$dir/series-$2" ]]; then sort -u "$dir/series-$2" | wc -l; else echo 0; fi
    ;;
  sample)
    [[ "$(cat "$dir/prepared")" == "$2" ]] || { echo "sampled $2 in a login prepared for $(cat "$dir/prepared")" >&2; exit 1; }
    if grep -qx "$login" "$dir/used" 2>/dev/null; then echo "login $login used twice" >&2; exit 1; fi
    echo "$login" >>"$dir/used"
    # Login numbers listed in fail-sample fail after spending the login.
    grep -qx "$login" "$dir/fail-sample" 2>/dev/null && { echo "stub failure in login $login" >&2; exit 1; }
    echo "boot:$login" >>"$dir/series-$2"
    ;;
  report) echo "$2" >>"$dir/reports" ;;
  *) exit 2 ;;
esac
STUB
cat >"$work/relogin" <<'STUB'
#!/usr/bin/env bash
dir="$STUB_DIR"
next=$(( $(cat "$dir/login" 2>/dev/null || echo 0) + 1 ))
echo "$next" >"$dir/login"
echo "$next" >>"$dir/relogins"
# Simulate an interruption: kill the series after the given relogin.
if [[ -f "$dir/kill-after" && "$next" == "$(cat "$dir/kill-after")" ]]; then
  rm -f "$dir/kill-after"
  kill -TERM "$PPID"
fi
STUB
chmod +x "$work/cold-login.sh" "$work/relogin"

export STUB_DIR="$work" DITTO_ARTIFACTS="$work/artifacts" DITTO_COLD_LOGIN="$work/cold-login.sh"
export DITTO_RELOGIN_CMD="$work/relogin" DITTO_LOGIN_TIMEOUT_SECONDS=3
unset XDG_SESSION_DESKTOP WAYLAND_DISPLAY

failures=0
expect() {
  if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; failures=$(( failures + 1 )); fi
}

# Login 2 fails its sample; then the series is killed right after relogin 4.
echo 2 >"$work/fail-sample"
echo 4 >"$work/kill-after"
status=0
bash "$here/series.sh" rescue_no_node desktop_full_plus10 >/dev/null 2>&1 || status=$?
expect "③ the interrupted invocation stops non-zero" '(( status != 0 ))'
expect "③ two runs recorded before the interruption" '[[ "$(sort -u "$work/series-rescue_no_node" | wc -l)" == 2 ]]'
status=0
bash "$here/series.sh" rescue_no_node desktop_full_plus10 >/dev/null 2>&1 || status=$?
expect "① the resumed series completes" '(( status == 0 ))'
expect "① three runs per state, each from its own login" \
  '[[ "$(sort -u "$work/series-rescue_no_node" | wc -l)" == 3 && "$(sort -u "$work/series-desktop_full_plus10" | wc -l)" == 3 ]]'
expect "① no login is in two series" \
  '[[ -z "$(cat "$work/series-rescue_no_node" "$work/series-desktop_full_plus10" | sort | uniq -d)" ]]'
expect "② the failed login 2 was not sampled again" '[[ "$(grep -cx 2 "$work/used")" == 1 ]]'
expect "③ nothing was sampled twice" '[[ -z "$(sort "$work/used" | uniq -d)" ]]'
expect "① one report per state, in order" '[[ "$(cat "$work/reports" | xargs)" == "rescue_no_node desktop_full_plus10" ]]'
expect "⑤ conditions reset at the end of each invocation" '[[ "$(wc -l <"$work/resets")" == 2 && ! -f "$work/prepared" ]]'
expect "⑤ the last relogin follows the last sample" \
  '[[ "$(tail -1 "$work/relogins")" -gt "$(sort -n "$work/used" | tail -1)" ]]'
expect "progress log written" '[[ -s "$work/artifacts/cold-login-progress.log" ]] && grep -q "all states done" "$work/artifacts/cold-login-progress.log"'

# ④: logins that never become ready, three times in a row.
rm -f "$work/series-desktop_full_no_agent"
login="$(cat "$work/login")"
printf '%s\n' $(( login + 1 )) $(( login + 2 )) $(( login + 3 )) >"$work/never-ready"
status=0
DITTO_SERIES_FINAL_RELOGIN=0 bash "$here/series.sh" desktop_full_no_agent >/dev/null 2>&1 || status=$?
expect "④ three logins that never come up stop the series" '(( status == 1 ))'
expect "④ nothing was recorded for them" '[[ ! -f "$work/series-desktop_full_no_agent" ]]'
expect "④ the stop is in the progress log" 'grep -q "3 failed attempts; stopping" "$work/artifacts/cold-login-progress.log"'

(( failures == 0 )) && echo "series.sh self-test: all checks passed (stubs only; development)" || { echo "series.sh self-test: $failures failed"; exit 1; }

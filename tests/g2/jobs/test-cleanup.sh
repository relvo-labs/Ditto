#!/usr/bin/env bash
# Self-test of run.mjs's cleanup with stubs (#124): no systemd, no Core. A
# stub Core writes the job scopes the driver would have recorded and a passing
# result; a stub systemctl records its calls. Checked: the cleanup stops
# exactly the recorded scopes and never a ditto-job-* glob, which would also
# stop the jobs of a logged-in session's Core on the same user manager.
# Development evidence about what run.mjs asks systemd to do; the recording
# in driver.mjs is exercised only by the real suite.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ditto-g2-jobs-cleanup.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT

# run.mjs finds Core relative to itself: give it a workspace of its own.
mkdir -p "$work/ws/tests/g2/jobs" "$work/ws/target/debug" "$work/bin"
cp "$here/run.mjs" "$work/ws/tests/g2/jobs/run.mjs"
cat >"$work/ws/target/debug/ditto-core" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' ditto-job-mine-1.scope ditto-job-mine-2.scope ditto-job-mine-1.scope >"$DITTO_G2_ROOT/job-scopes"
printf '{"ok":true,"checks":[],"facts":{}}' >"$DITTO_G2_TEST_OUT"
exec sleep 30
STUB
cat >"$work/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_CALLS"
STUB
chmod +x "$work/ws/target/debug/ditto-core" "$work/bin/systemctl"

export STUB_CALLS="$work/calls"
: >"$STUB_CALLS"
PATH="$work/bin:$PATH" TMPDIR="$work" node "$work/ws/tests/g2/jobs/run.mjs" >"$work/out" 2>&1 ||
  { cat "$work/out" >&2; echo 'FAIL: run.mjs failed with a passing stub result' >&2; exit 1; }

failures=0
stops="$(grep -E '(^| )stop ' "$STUB_CALLS" || true)"
if grep -q '\*' <<<"$stops"; then
  echo "FAIL: the cleanup stops a glob: $stops" >&2; failures=$((failures + 1))
fi
stopped="$(tr ' ' '\n' <<<"$stops" | grep '\.scope$' | sort -u | tr '\n' ' ' || true)"
if [[ "$stopped" == "ditto-job-mine-1.scope ditto-job-mine-2.scope " ]]; then
  echo 'ok: the cleanup stops exactly the recorded job scopes'
else
  echo "FAIL: the cleanup stopped: ${stopped:-nothing}" >&2; failures=$((failures + 1))
fi
(( failures == 0 )) || exit 1
echo 'test-cleanup: all checks passed'

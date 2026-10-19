#!/usr/bin/env bash
# Development regression only: no compositor, Core, Quickshell or seat.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/checks.sh"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/ditto-shell-session.XXXXXX")"
trap 'rm -rf -- "$test_dir"' EXIT

failures=0 checks=0
expect() {
  local name="$1" expected="$2" diagnostic="$3" status=0 output
  shift 3
  output="$("$@" 2>&1)" || status=$?
  checks=$((checks + 1))
  if [[ "$status" == "$expected" && "$output" == *"$diagnostic"* ]]; then
    echo "PASS: $name (exit $status)"
  else
    echo "FAIL: $name (expected $expected, got $status)" >&2
    echo "$output" >&2
    failures=$((failures + 1))
  fi
}

# The first three lines were already logged when pinning began.
expect 'only a pre-pin mask must fail' 1 'check 1 failed:' wait_session_mask "$HERE/fixtures/before-pin.txt" 3 1
expect 'a new post-pin mask passes' 0 '' wait_session_mask "$HERE/fixtures/after-pin.txt" 3 1
expect 'a mask exactly at the floor is stale' 1 'check 1 failed:' wait_session_mask "$HERE/fixtures/after-pin.txt" 4 1
sed '4s/24/240/' "$HERE/fixtures/after-pin.txt" >"$test_dir/wrong-mask.txt"
expect 'a different mask must not count' 1 'check 1 failed:' wait_session_mask "$test_dir/wrong-mask.txt" 3 1
: >"$test_dir/empty.txt"
expect 'no mask fails clearly' 1 'check 1 failed:' wait_session_mask "$test_dir/empty.txt" 0 1

# Core exits at 2500 ms, after line 5; the immediate offline redraw at 3000
# is not enough. Only continuing frames after the 2 s settling period count.
expect 'live shell with only pre-exit frames fails' 1 'check 5 failed: no continuing' \
  require_session_survival "$HERE/fixtures/after-pin.txt" 5 2500 "$$"
expect 'continuing legacy frames after Core exit pass' 0 '' \
  require_session_survival "$HERE/fixtures/after-core-exit.txt" 5 2500 "$$"
expect 'fresh frames cannot rescue a dead shell PID' 1 'check 5 failed: the shell died' \
  require_session_survival "$HERE/fixtures/after-core-exit.txt" 5 2500 999999999
expect 'frames at or before the floor are stale' 1 'check 5 failed: no continuing' \
  require_session_survival "$HERE/fixtures/after-core-exit.txt" 8 2500 "$$"
head -6 "$HERE/fixtures/after-core-exit.txt" >"$test_dir/offline-redraw.txt"
expect 'one disconnect redraw does not prove continuing animation' 1 'check 5 failed: no continuing' \
  require_session_survival "$test_dir/offline-redraw.txt" 5 2500 "$$"
printf 'ditto-frame 2000 16\nditto-frame 2016 16\n' >"$test_dir/buffered.txt"
expect 'buffered pre-exit timestamps fail even after the floor' 1 'check 5 failed: no continuing' \
  require_session_survival "$test_dir/buffered.txt" 0 2500 "$$"
sed 's/ 16$/ 0/' "$HERE/fixtures/after-core-exit.txt" >"$test_dir/zero-intervals.txt"
expect 'zero frame intervals are not animation evidence' 1 'check 5 failed: no continuing' \
  require_session_survival "$test_dir/zero-intervals.txt" 5 2500 "$$"

echo "$((checks - failures))/$checks checks passed (development)"
(( failures == 0 ))

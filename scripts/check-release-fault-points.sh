#!/usr/bin/env bash
# Fail when a binary carries test-only fault injection: the variable it reads
# and the names of its points. Release builds are compiled without the
# `fault-injection` feature, so none of these strings may appear.
set -euo pipefail
if [[ $# -eq 0 ]]; then
  echo "usage: $0 BINARY..." >&2
  exit 2
fi
patterns=(
  'DITTO_FAULT'
  'coordinator.after_state='
  'coordinator.readback=mismatch'
  'store.commit_revision'
  'store.unpack'
  'injected SQLITE_IOERR'
  'fault.abort_process'
  'fault.hold'
  'generation-fault.txt'
)
status=0
for binary in "$@"; do
  if [[ ! -f "$binary" ]]; then
    echo "missing binary: $binary" >&2
    status=1
    continue
  fi
  # Capture once: `strings | grep -q` under pipefail reports SIGPIPE from
  # strings as a failure exactly when grep finds a match.
  text="$(strings "$binary")"
  for pattern in "${patterns[@]}"; do
    if grep -qF -- "$pattern" <<<"$text"; then
      echo "FAIL $binary contains fault-injection string: $pattern"
      status=1
    fi
  done
done
if [[ $status -eq 0 ]]; then
  echo "ok: no fault-injection strings in $*"
fi
exit $status

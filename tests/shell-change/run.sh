#!/usr/bin/env bash
# Change wording (shell/change) unit tests: what history lists and change
# cards say for each kind of ChangeSet record. Records are fixtures.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="${1:?outside evidence directory required}"
qt="${QT_PREFIX:?QT_PREFIX required}"
mkdir -p "$out"
cd "$root"
export QT_QPA_PLATFORM=offscreen
"$qt/bin/qmltestrunner" -import "$root/tests/g4/visual/stubs" -import "$here/stubs" -input "$here/unit" > "$out/change-text.log" 2>&1

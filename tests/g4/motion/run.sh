#!/usr/bin/env bash
# Rendered-value/lifetime regressions. Layer-shell and Core states are fixtures.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
out="${1:?outside evidence directory required}"
qt="${QT_PREFIX:?QT_PREFIX required}"
mkdir -p "$out"
cd "$root"
export QT_QPA_PLATFORM=offscreen
node tests/g4/visual/stage-providers.mjs > "$out/provider-staging.log" 2>&1
python3 tests/g4/visual/stage-assistant.py > "$out/assistant-staging.log" 2>&1
"$qt/bin/qmltestrunner" -import "$root/tests/g4/visual/stubs" -input "$here" > "$out/motion.log" 2>&1

#!/usr/bin/env bash
# G3 development checks; desktop and OS stress suites run separately.
set -euo pipefail
cd "$(dirname "$0")/../.."
cargo test --locked -p ditto-generation -p ditto-test-host -p ditto-protocol -p ditto-store
python3 scripts/sync-generated-templates.py --check
cargo build --locked -p ditto-generation -p ditto-test-host -p ditto-confine
target/debug/ditto-generation inspect <crates/ditto-generation/examples/tasks-summary.json >/dev/null
target/debug/ditto-generation inspect <crates/ditto-generation/examples/workspace-actions.json >/dev/null
qml_lint="${DITTO_QMLLINT:-$HOME/Qt/6.10.2/gcc_64/bin/qmllint}"
qml_test="${DITTO_QMLTESTRUNNER:-$HOME/Qt/6.10.2/gcc_64/bin/qmltestrunner}"
if [[ ! -x "$qml_lint" || ! -x "$qml_test" ]]; then
  echo 'QML template checks: not_run (pinned Qt tools unavailable)' >&2
  exit 2
fi
"$qml_lint" crates/ditto-generation/templates/*.qml
QT_QPA_PLATFORM=offscreen "$qml_test" -input tests/g3/templates

bash tools/generation-host/build.sh

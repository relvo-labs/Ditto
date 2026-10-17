#!/usr/bin/env bash
# Fixed trusted Qt runner; no candidate source is compiled by this script.
set -euo pipefail
cd "$(dirname "$0")/../.."
qt_prefix="${DITTO_QT_PREFIX:-$HOME/Qt/6.10.2/gcc_64}"
build_profile="${1:-debug}"
[[ "$build_profile" == debug || "$build_profile" == release ]] || exit 64
mkdir -p "target/$build_profile"
g++ -std=c++20 -O2 -fPIC -Wall -Wextra -Werror -DQT_GUI_LIB tools/generation-host/runner.cpp \
  -I"$qt_prefix/include" -I"$qt_prefix/include/QtCore" -I"$qt_prefix/include/QtGui" \
  -I"$qt_prefix/include/QtQml" -I"$qt_prefix/include/QtQuick" -I"$qt_prefix/include/QtTest" \
  -L"$qt_prefix/lib" -Wl,-rpath,"$qt_prefix/lib" \
  -lQt6Quick -lQt6Qml -lQt6Gui -lQt6Core -lQt6Test \
  -o "target/$build_profile/ditto-generation-runner"
python3 - "$qt_prefix" "target/$build_profile/ditto-generation-runner" <<'PY'
import hashlib,json,pathlib,sys
binary=pathlib.Path(sys.argv[2])
binary.with_suffix('.json').write_text(json.dumps({'qt_prefix':str(pathlib.Path(sys.argv[1]).resolve()),'qt_version':'6.10.2','sha256':hashlib.sha256(binary.read_bytes()).hexdigest()})+'\n')
PY

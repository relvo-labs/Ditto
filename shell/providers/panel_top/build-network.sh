#!/usr/bin/env bash
# Same Qt prefix as Quickshell. This trusted, read-only module runs in Shell;
# it does not start another resident service or poll a subprocess.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
qt="${QT_PREFIX:-$HOME/Qt/6.10.2/gcc_64}"
build="${DITTO_PANEL_NETWORK_BUILD:-$here/../../../target/panel-network}"
mkdir -p "$build"
build="$(cd "$build" && pwd)"
"$qt/bin/qmake" -o "$build/Makefile" "$here/qml/network/network.pro"
make -C "$build" -j2
cp "$build/libdittonetwork.so" "$here/qml/network/libdittonetwork.so"

#!/usr/bin/env bash
# Same Qt prefix as Quickshell. This trusted, read-only module runs in Shell;
# it does not start another resident service or poll a subprocess.
# Reproducible across prefix aliases with the same Qt/compiler toolchain;
# compiler, Qt and libstdc++ changes can change the package hash.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
qt="${QT_PREFIX:-$HOME/Qt/6.10.2/gcc_64}"
cxx="${CXX:-g++}"
fail() {
  echo "Panel network build: $*. Install Qt 6.10.2, make and a C++17 compiler; set QT_PREFIX to the Quickshell Qt prefix (and CXX if needed)." >&2
  exit 1
}
[[ -x "$qt/bin/qmake" ]] || fail "missing qmake at $qt/bin/qmake"
command -v make >/dev/null || fail "missing make"
command -v "$cxx" >/dev/null || fail "missing C++ compiler $cxx"
[[ "$("$qt/bin/qmake" -query QT_VERSION)" == 6.10.2 ]] || fail "qmake must use Qt 6.10.2"
if [[ "${1:-}" == --check ]]; then exit 0; fi
build_root="${DITTO_PANEL_NETWORK_BUILD:-${TMPDIR:-$here/../../../target}/panel-network}"
mkdir -p "$build_root"
build="$(mktemp -d "$build_root/run.XXXXXX")"
build="$(cd "$build" && pwd)"
library_tmp= entry_tmp=
trap 'rm -rf "$build"; rm -f "$library_tmp" "$entry_tmp"' EXIT
"$qt/bin/qmake" -o "$build/Makefile" "$here/native/network.pro" "QMAKE_CXX=$cxx" "QMAKE_LINK=$cxx"
make -C "$build" -j2
# Rename on the destination filesystem: a running Shell can keep its mmap of
# the previous inode, and parallel builds never share intermediate objects.
library_tmp="$(mktemp "$here/qml/network/.libdittonetwork.so.XXXXXX")"
cp "$build/libdittonetwork.so" "$library_tmp"
chmod 755 "$library_tmp"
mv -f "$library_tmp" "$here/qml/network/libdittonetwork.so"
# The SDK checks qml_entry existence before packing. A clean checkout must
# fail with package_missing/build first instead of silently omitting the .so.
entry_tmp="$(mktemp "$here/qml/.BuiltPanelTop.qml.XXXXXX")"
printf 'import QtQuick\n\nPanelTop {}\n' > "$entry_tmp"
chmod 644 "$entry_tmp"
mv -f "$entry_tmp" "$here/qml/BuiltPanelTop.qml"

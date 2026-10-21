#!/usr/bin/env bash
# Panel-owned SDK entry point: always build the complete runtime before pack.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -s "$here/qml/network/libdittonetwork.so" ]]; then
  echo "WARNING: missing panel network module; building it before packing. Release packages require qml/network/libdittonetwork.so." >&2
fi
bash "$here/build-network.sh"
[[ -s "$here/qml/network/libdittonetwork.so" ]] || {
  echo "Panel pack refused: missing qml/network/libdittonetwork.so after build. Check QT_PREFIX and rerun pack.sh." >&2
  exit 1
}
exec sh "$here/../../../packages/host-sdk/bin/ditto-plugin" pack "$here" "$@"

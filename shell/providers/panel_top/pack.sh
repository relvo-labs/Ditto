#!/usr/bin/env bash
# Panel-owned SDK entry point: always build the complete runtime before pack.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$here/build-network.sh"
exec sh "$here/../../../packages/host-sdk/bin/ditto-plugin" pack "$here" "$@"

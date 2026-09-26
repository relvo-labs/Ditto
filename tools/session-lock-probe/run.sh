#!/usr/bin/env bash
# Build a throw-away ext-session-lock-v1 client, secure the fixture session,
# observe `locked`, then immediately send unlock_and_destroy.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
xml="${WAYLAND_PROTOCOLS_DIR:-$(pkg-config --variable=pkgdatadir wayland-protocols)}/staging/ext-session-lock/ext-session-lock-v1.xml"
build="$(mktemp -d)"
trap 'rm -rf -- "$build"' EXIT

wayland-scanner client-header "$xml" "$build/ext-session-lock-v1-client-protocol.h"
wayland-scanner private-code "$xml" "$build/ext-session-lock-v1-protocol.c"
cc -std=c11 -Wall -Wextra -Werror -I"$build" \
  "$here/session-lock-probe.c" "$build/ext-session-lock-v1-protocol.c" \
  $(pkg-config --cflags --libs wayland-client) -o "$build/session-lock-probe"
timeout 8 "$build/session-lock-probe"

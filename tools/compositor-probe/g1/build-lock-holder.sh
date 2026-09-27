#!/usr/bin/env bash
# Build lock-holder.c into $1 (a directory). Same toolchain as the G0 probe.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$1"
xml="${WAYLAND_PROTOCOLS_DIR:-$(pkg-config --variable=pkgdatadir wayland-protocols)}/staging/ext-session-lock/ext-session-lock-v1.xml"
wayland-scanner client-header "$xml" "$out/ext-session-lock-v1-client-protocol.h"
wayland-scanner private-code "$xml" "$out/ext-session-lock-v1-protocol.c"
# shellcheck disable=SC2046
cc -std=c11 -Wall -Wextra -Werror -I"$out" \
  "$here/lock-holder.c" "$out/ext-session-lock-v1-protocol.c" \
  $(pkg-config --cflags --libs wayland-client) -o "$out/lock-holder"

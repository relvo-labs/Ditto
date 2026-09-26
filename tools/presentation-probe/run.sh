#!/usr/bin/env bash
# Build the tiny client from the frozen protocol XML and record compositor
# presentation timestamps. No generated protocol file is committed.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
frames="${1:-180}"
output="${2:--}"
build="$(mktemp -d /tmp/ditto-presentation-probe.XXXXXX)"
trap 'rm -rf -- "$build"' EXIT
protocols="$(pkg-config --variable=pkgdatadir wayland-protocols)"

wayland-scanner client-header "$protocols/stable/xdg-shell/xdg-shell.xml" "$build/xdg-shell-client-protocol.h"
wayland-scanner private-code "$protocols/stable/xdg-shell/xdg-shell.xml" "$build/xdg-shell-protocol.c"
wayland-scanner client-header "$protocols/stable/presentation-time/presentation-time.xml" "$build/presentation-time-client-protocol.h"
wayland-scanner private-code "$protocols/stable/presentation-time/presentation-time.xml" "$build/presentation-time-protocol.c"

cc -std=c11 -O2 -Wall -Wextra -Werror -I"$build" \
  "$here/presentation-probe.c" "$build/xdg-shell-protocol.c" "$build/presentation-time-protocol.c" \
  $(pkg-config --cflags --libs wayland-client) -o "$build/presentation-probe"

if [[ "$output" == - ]]; then
  "$build/presentation-probe" "$frames"
else
  "$build/presentation-probe" "$frames" >"$output"
  echo "presentation timestamps -> $output"
fi

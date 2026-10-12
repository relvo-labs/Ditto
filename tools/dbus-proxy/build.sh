#!/usr/bin/env bash
# Build the pinned xdg-dbus-proxy and install it next to ditto-core as
# `ditto-dbus-proxy`, where Core looks for it. Needs meson, ninja, a C
# compiler and GLib/GIO development files.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
workspace="$(cd "$here/../.." && pwd)"
profile="${1:-debug}"
commit="$(jq -r .upstream_commit "$here/pin.json")"
tag="$(jq -r .version "$here/pin.json")"
work="$workspace/target/dbus-proxy-src"
if [[ ! -d "$work/.git" ]] || [[ "$(git -C "$work" rev-parse HEAD)" != "$commit" ]]; then
  rm -rf "$work"
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" https://github.com/flatpak/xdg-dbus-proxy "$work"
fi
[[ "$(git -C "$work" rev-parse HEAD)" == "$commit" ]] || { echo "tag $tag is not the pinned commit" >&2; exit 1; }
# Build output goes to stderr: meson reports a missing dependency on stdout.
[[ -d "$work/build" ]] || meson setup "$work/build" "$work" -Dman=disabled >&2
ninja -C "$work/build" >&2
mkdir -p "$workspace/target/$profile"
install -m 0755 "$work/build/xdg-dbus-proxy" "$workspace/target/$profile/ditto-dbus-proxy"
"$workspace/target/$profile/ditto-dbus-proxy" --version

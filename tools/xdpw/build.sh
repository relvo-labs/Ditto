#!/usr/bin/env bash
# Build the pinned xdg-desktop-portal-wlr with Ditto's patches and install it
# as /usr/local/libexec/xdg-desktop-portal-wlr (sudo). The distribution's
# package stays; the Ditto session's user unit drop-in runs this one
# (packaging/reference-image/session/xdpw-service.conf). Needs meson, ninja, a C
# compiler, and the development files of PipeWire, wayland, gbm, libdrm,
# inih and libsystemd.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
workspace="$(cd "$here/../.." && pwd)"
commit="$(jq -r .upstream_commit "$here/pin.json")"
tag="$(jq -r .version "$here/pin.json")"
work="$workspace/target/xdpw-src"
if [[ ! -d "$work/.git" ]] || [[ "$(git -C "$work" rev-parse HEAD)" != "$commit" ]]; then
  rm -rf "$work"
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" "$(jq -r .upstream_repo "$here/pin.json")" "$work"
fi
[[ "$(git -C "$work" rev-parse HEAD)" == "$commit" ]] || { echo "tag $tag is not the pinned commit" >&2; exit 1; }
git -C "$work" checkout -q -- .
for patch in $(jq -r '.modifications[].patch' "$here/pin.json"); do
  git -C "$work" apply "$here/$patch"
done
rm -rf "$work/build"
meson setup "$work/build" "$work" --prefix=/usr/local --sysconfdir=/etc --buildtype=release \
  -Dman-pages=disabled -Dsystemd=disabled >/dev/null
ninja -C "$work/build" >/dev/null
sudo install -m 0755 "$work/build/xdg-desktop-portal-wlr" /usr/local/libexec/xdg-desktop-portal-wlr
echo "installed xdg-desktop-portal-wlr $tag (+$(jq '.modifications | length' "$here/pin.json") patches)" >&2

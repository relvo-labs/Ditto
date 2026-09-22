#!/usr/bin/env bash
# Abandoned path, kept for reproducing the comparison D-02 was decided from.
#
# The container has Sway and no Wayfire (Debian testing has no wayfire package),
# so everything started here runs against the abandoned backend and is pinned to
# it explicitly rather than picking up the default. The current path is the
# workstation: see docs/platform/dev-wayland-environment.md.
#
# Results from here are development evidence; EX-01, EX-03, EX-04, EX-05 and
# EX-09 need the frozen reference machine.
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
script="${1:-window-matrix}"
image_name=ditto-wayland-dev:qt610

export PATH="$HOME/.cargo/bin:$PATH"
cargo build --locked --workspace --bins
docker build --quiet -t "$image_name" -f "$repo_dir/tools/dev-wayland/Dockerfile" "$repo_dir/tools/dev-wayland" >/dev/null
mkdir -p "$repo_dir/artifacts/g0"

exec docker run --rm --network none \
  --env DITTO_COMPOSITOR=sway \
  --mount "type=bind,source=$repo_dir,target=/workspace,readonly" \
  --mount "type=bind,source=$repo_dir/artifacts,target=/workspace/artifacts" \
  "$image_name" bash "/workspace/tests/g0/$script/run.sh"

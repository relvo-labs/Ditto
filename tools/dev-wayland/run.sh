#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
image_name=ditto-wayland-dev:qt610
mode="${1:-smoke}"

docker build --quiet -t "$image_name" -f "$repo_dir/tools/dev-wayland/Dockerfile" "$repo_dir/tools/dev-wayland" >/dev/null

case "$mode" in
  smoke)
    docker run --rm --network none \
      --mount "type=bind,source=$repo_dir,target=/workspace,readonly" \
      "$image_name" bash /workspace/tools/dev-wayland/smoke.sh
    ;;
  vnc)
    container_name=ditto-wayland-vnc
    docker run --detach --rm --init --name "$container_name" -p 127.0.0.1:5900:5900 \
      --mount "type=bind,source=$repo_dir,target=/workspace,readonly" \
      "$image_name" bash /workspace/tools/dev-wayland/serve.sh >/dev/null
    trap 'docker stop -t 2 "$container_name" >/dev/null 2>&1 || true' EXIT INT TERM
    docker logs --follow "$container_name"
    ;;
  *)
    echo "Usage: $0 [smoke|vnc]" >&2
    exit 2
    ;;
esac

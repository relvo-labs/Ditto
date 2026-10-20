#!/usr/bin/env bash
# Build every built-in package into one directory of .dittopkg files, the
# directory Core installs from at first start (--builtin-packages, or
# DITTO_BUILTIN_PACKAGES). A package is tar+zstd with manifest.json at its root.
#
#   QML providers:        shell/providers/<dir>/        (manifest.json + QML)
#   declarative bundles:  packaging/builtin/<id>/       (manifest.json only)
#   Cordis services:      packages/plugins/<dir>/       (ditto-plugin pack)
#   test fixtures:        packages/plugin-fixtures/     (only with DITTO_PACK_FIXTURES=1:
#                         the D-34 simple plugins and the fault fixtures, never shipped)
#
# The archives are reproducible: fixed mtime, owner and sort order, so the
# same sources give the same sha256 and the Profile's locks stay valid.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-$root/target/ditto-packages}"
mkdir -p "$out"
# Plugin pack scripts run from their own directory; retain one output root.
out="$(cd "$out" && pwd)"
rm -f "$out"/*.dittopkg

pack_dir() {
  local directory="$1"
  if [[ "$directory" == "$root/shell/providers/panel_top" ]]; then
    bash "$directory/build-network.sh"
  fi
  local id version
  id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$directory/manifest.json")"
  version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$directory/manifest.json")"
  # Name the top-level entries instead of `.`: archive paths must be `manifest.json`, not
  # `./manifest.json` (Core looks the manifest up by that exact name). Dotfiles stay out.
  local entries
  mapfile -t entries < <(cd "$directory" && find . -mindepth 1 -maxdepth 1 ! -name '.*' -printf '%P\n' | sort)
  tar --zstd --sort=name --mtime='2026-01-01 00:00Z' --owner=0 --group=0 --numeric-owner \
    --exclude='*.qmlc' --exclude='.*' -cf "$out/$id-$version.dittopkg" -C "$directory" "${entries[@]}"
  echo "$id $version $(sha256sum "$out/$id-$version.dittopkg" | cut -d' ' -f1)"
}

shopt -s nullglob
for manifest in "$root"/shell/providers/*/manifest.json "$root"/packaging/builtin/*/manifest.json; do
  pack_dir "$(dirname "$manifest")"
done
for plugin in "$root"/packages/plugins/*/; do
  if [[ -f "$plugin/manifest.json" ]]; then
    if [[ -f "$plugin/package.json" ]] && grep -q '"pack"' "$plugin/package.json"; then
      (cd "$plugin" && pnpm run -s pack --out "$out") || { echo "pack failed: $plugin" >&2; exit 1; }
    else
      echo "skip $plugin: no pack script" >&2
    fi
  fi
done
if [[ "${DITTO_PACK_FIXTURES:-0}" == 1 ]]; then
  (cd "$root/packages/plugin-fixtures" && pnpm run -s pack --out "$out") || { echo "pack failed: plugin-fixtures" >&2; exit 1; }
fi
